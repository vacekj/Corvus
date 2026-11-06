import AppKit
import AVFoundation
import CoreAudio
import CorvusCore
import SwiftUI

/// One voice call (signal-cli 0.14.2+ "experimental voice calling").
///
/// signal-cli does the signaling and spawns `signal-call-tunnel` (RingRTC) per call. The tunnel exchanges
/// audio through two virtual audio devices; on macOS these are BlackHole devices named `signal_input`
/// (what the tunnel sends: we play the microphone into it) and `signal_output` (what the tunnel receives:
/// we play it on the speakers). `CallAudioBridge` connects them while the call is up.
struct CallSession: Equatable {
    enum State: String {
        case idle = "IDLE", ringingIncoming = "RINGING_INCOMING", ringingOutgoing = "RINGING_OUTGOING"
        case connecting = "CONNECTING", connected = "CONNECTED", reconnecting = "RECONNECTING", ended = "ENDED"
    }

    var callId: Int64 = 0
    var peerKey = ""
    var outgoing = false
    var state: State = .idle
    var inputDevice = "signal_input"
    var outputDevice = "signal_output"
    var connectedAt: Date?
    var muted = false
    var endReason = ""

    var isActive: Bool { state != .ended && state != .idle }
}

enum CallSetup {
    /// signal-cli finds the tunnel through $SIGNAL_CALL_TUNNEL_BIN, next to its own installation or on $PATH.
    static func tunnelPath(signalCli: String) -> String? {
        let fm = FileManager.default
        if let env = ProcessInfo.processInfo.environment["SIGNAL_CALL_TUNNEL_BIN"], fm.isExecutableFile(atPath: env) { return env }
        var dirs: [String] = []
        if !signalCli.isEmpty {
            let real = (try? fm.destinationOfSymbolicLink(atPath: signalCli)).map {
                URL(fileURLWithPath: $0, relativeTo: URL(fileURLWithPath: signalCli).deletingLastPathComponent()).path
            } ?? signalCli
            dirs.append(URL(fileURLWithPath: real).deletingLastPathComponent().path)
        }
        let env = SignalCli.childEnvironment()
        dirs += (env["PATH"] ?? "").split(separator: ":").map(String.init)
        for d in dirs {
            let p = (d as NSString).appendingPathComponent("signal-call-tunnel")
            if fm.isExecutableFile(atPath: p) { return p }
        }
        return nil
    }

    static func missingRequirements(signalCli: String) -> [String] {
        var missing: [String] = []
        if tunnelPath(signalCli: signalCli) == nil { missing.append("signal-call-tunnel") }
        if AudioDevices.find(named: "signal_input") == nil || AudioDevices.find(named: "signal_output") == nil {
            missing.append("the BlackHole devices “signal_input” and “signal_output”")
        }
        return missing
    }

    static let instructions = """
        Voice calls use signal-cli's experimental calling support. It needs two things that Corvus cannot install for you:

        1. signal-call-tunnel (RingRTC):
           git clone --recurse-submodules https://github.com/visigoth/signal-call-tunnel.git
           cargo install --path signal-call-tunnel/signal-call-tunnel

        2. The virtual audio devices (one-time, needs administrator rights):
           cd signal-call-tunnel/third-party/ringrtc
           sudo bin/virtual_audio.sh --setup --input-source signal_input --output-sink signal_output

        Then choose File → Reconnect. Video calls are not supported by signal-cli.
        """
}

// MARK: - Core Audio devices

enum AudioDevices {
    static func all() -> [AudioDeviceID] {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices, mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &ids) == noErr else { return [] }
        return ids
    }

    static func name(_ id: AudioDeviceID) -> String {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioObjectPropertyName, mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        var name: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &name) == noErr, let n = name else { return "" }
        return n.takeRetainedValue() as String
    }

    static func find(named wanted: String) -> AudioDeviceID? {
        all().first { name($0).caseInsensitiveCompare(wanted) == .orderedSame }
    }
}

// MARK: - Audio bridge

/// Microphone → `signal_input`, `signal_output` → speakers. Each direction is an AVAudioEngine whose
/// input or output unit is pointed at the BlackHole device; samples travel through a small ring buffer.
final class CallAudioBridge: @unchecked Sendable {
    private var engines: [AVAudioEngine] = []      // players
    private var captures: [AVAudioEngine] = []
    private let lock = NSLock()
    private var muted = false

    var isRunning: Bool { !captures.isEmpty }

    func setMuted(_ m: Bool) {
        lock.lock()
        muted = m
        lock.unlock()
    }

    private var isMuted: Bool {
        lock.lock()
        defer { lock.unlock() }
        return muted
    }

    func start(inputDevice: String, outputDevice: String) throws {
        stop()
        guard let tunnelIn = AudioDevices.find(named: inputDevice), let tunnelOut = AudioDevices.find(named: outputDevice) else {
            throw RpcError("The audio devices “\(inputDevice)” / “\(outputDevice)” were not found.")
        }
        do {
            // Microphone (default input) -> tunnel input device
            try makeLeg(from: nil, to: tunnelIn, applyMute: true)
            // Tunnel output device -> speakers (default output)
            try makeLeg(from: tunnelOut, to: nil, applyMute: false)
        } catch {
            stop()
            throw error
        }
    }

    func stop() {
        for e in captures {
            e.inputNode.removeTap(onBus: 0)
            e.stop()
        }
        for e in engines { e.stop() }
        captures = []
        engines = []
    }

    private static func setDevice(_ unit: AudioUnit?, _ device: AudioDeviceID) throws {
        guard let unit else { throw RpcError("No audio unit.") }
        var d = device
        let err = AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &d,
                                       UInt32(MemoryLayout<AudioDeviceID>.size))
        if err != noErr { throw RpcError("Could not select the audio device (error \(err)).") }
    }

    /// One direction: capture `from` (nil = default input) and play to `to` (nil = default output).
    private func makeLeg(from: AudioDeviceID?, to: AudioDeviceID?, applyMute: Bool) throws {
        let capture = AVAudioEngine()
        if let from { try Self.setDevice(capture.inputNode.audioUnit, from) }
        let inFormat = capture.inputNode.outputFormat(forBus: 0)
        guard inFormat.sampleRate > 0, inFormat.channelCount > 0 else { throw RpcError("The audio input is not available.") }

        let common = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48000, channels: 1, interleaved: false)!
        let ring = RingBuffer(capacity: 48000) // 1 s
        let converter = AVAudioConverter(from: inFormat, to: common)

        let player = AVAudioEngine()
        if let to { try Self.setDevice(player.outputNode.audioUnit, to) }
        let source = AVAudioSourceNode(format: common) { _, _, frameCount, abl -> OSStatus in
            let buffers = UnsafeMutableAudioBufferListPointer(abl)
            guard let out = buffers.first?.mData?.assumingMemoryBound(to: Float.self) else { return noErr }
            ring.read(into: out, count: Int(frameCount))
            for b in buffers.dropFirst() { b.mData?.copyMemory(from: out, byteCount: Int(b.mDataByteSize)) }
            return noErr
        }
        player.attach(source)
        player.connect(source, to: player.mainMixerNode, format: common)

        capture.inputNode.installTap(onBus: 0, bufferSize: 960, format: inFormat) { [weak self] buffer, _ in
            guard let converter else { return }
            let ratio = common.sampleRate / inFormat.sampleRate
            let cap = AVAudioFrameCount(Double(buffer.frameLength) * ratio + 32)
            guard let out = AVAudioPCMBuffer(pcmFormat: common, frameCapacity: cap) else { return }
            var fed = false
            var err: NSError?
            converter.convert(to: out, error: &err) { _, status in
                if fed { status.pointee = .noDataNow; return nil }
                fed = true
                status.pointee = .haveData
                return buffer
            }
            guard err == nil, let data = out.floatChannelData?[0] else { return }
            if applyMute, self?.isMuted == true {
                ring.writeSilence(count: Int(out.frameLength))
            } else {
                ring.write(data, count: Int(out.frameLength))
            }
        }
        capture.prepare()
        try capture.start()
        do { try player.start() } catch {
            capture.stop()
            throw error
        }
        captures.append(capture)
        engines.append(player)
    }
}

/// Single-producer / single-consumer float ring buffer (drops the oldest samples when full).
final class RingBuffer: @unchecked Sendable {
    private var buf: [Float]
    private var readPos = 0
    private var count = 0
    private let lock = NSLock()

    init(capacity: Int) { buf = [Float](repeating: 0, count: capacity) }

    func write(_ src: UnsafePointer<Float>, count n: Int) {
        lock.lock()
        defer { lock.unlock() }
        for i in 0..<n {
            buf[(readPos + count) % buf.count] = src[i]
            if count < buf.count { count += 1 } else { readPos = (readPos + 1) % buf.count }
        }
    }

    func writeSilence(count n: Int) {
        let zeros = [Float](repeating: 0, count: n)
        zeros.withUnsafeBufferPointer { write($0.baseAddress!, count: n) }
    }

    func read(into dst: UnsafeMutablePointer<Float>, count n: Int) {
        lock.lock()
        defer { lock.unlock() }
        for i in 0..<n {
            if count > 0 {
                dst[i] = buf[readPos]
                readPos = (readPos + 1) % buf.count
                count -= 1
            } else {
                dst[i] = 0
            }
        }
    }
}

// MARK: - Call logic

extension AppModel {
    /// Call events are only delivered (and incoming calls only accepted) after subscribing.
    func subscribeCallEvents() {
        callSubscribed = false
        Task {
            do {
                try await cli.call("subscribeCallEvents")
                callSubscribed = true
                callSetupMissing = CallSetup.missingRequirements(signalCli: cli.executable)
            } catch {
                // signal-cli before 0.14.2: no calls.
                callSubscribed = false
            }
        }
    }

    var callsAvailable: Bool { callSubscribed && connected }

    /// Why a voice call cannot be started with this contact now (shown as the call button's tooltip), or nil.
    func callUnavailableReason(_ key: String) -> String? {
        if !connected { return "Voice calls need a connection to signal-cli." }
        if call?.isActive == true { return "A call is already in progress." }
        if !callSubscribed { return "Voice calls need signal-cli 0.14.2 or newer." }
        if !callSetupMissing.isEmpty {
            return "Voice calls are not set up: \(callSetupMissing.joined(separator: " and ")) missing. See Help → Voice call setup."
        }
        if isSendLocked(key) { return "Accept the message request first." }
        return nil
    }

    func showCallSetup() async {
        await Dialogs.info("Voice call setup", CallSetup.instructions)
    }

    func startCall(_ key: String) async {
        guard let c = chats.convs[key], !c.isGroup else { return }
        guard call?.isActive != true else {
            showFlash("A call is already in progress.", seconds: 5)
            return
        }
        guard callsAvailable else {
            await Dialogs.warn("Voice calls", "Voice calls need signal-cli 0.14.2 or newer.")
            return
        }
        let missing = CallSetup.missingRequirements(signalCli: cli.executable)
        if !missing.isEmpty {
            await Dialogs.warn("Voice calls are not set up", "Missing: \(missing.joined(separator: " and ")).\n\n" + CallSetup.instructions)
            return
        }
        guard await ensureMicrophone() else { return }
        do {
            let res = jsonObject(try await cli.call("startCall", ["recipient": chats.resolveKey(key)]))
            var s = CallSession()
            s.callId = jsonInt64(res["callId"])
            s.peerKey = key
            s.outgoing = true
            s.state = CallSession.State(rawValue: jsonString(res["state"])) ?? .ringingOutgoing
            let i = jsonString(res["inputDeviceName"]), o = jsonString(res["outputDeviceName"])
            if !i.isEmpty { s.inputDevice = i }
            if !o.isEmpty { s.outputDevice = o }
            call = s
        } catch {
            showFlash("The call could not be started: \(error.localizedDescription)")
        }
    }

    func acceptCall() async {
        guard let s = call, s.state == .ringingIncoming else { return }
        let missing = CallSetup.missingRequirements(signalCli: cli.executable)
        if !missing.isEmpty {
            await Dialogs.warn("Voice calls are not set up", "Missing: \(missing.joined(separator: " and ")).\n\n" + CallSetup.instructions)
            return
        }
        guard await ensureMicrophone() else { return }
        stopRinging()
        do {
            let res = jsonObject(try await cli.call("acceptCall", ["callId": s.callId]))
            if let st = CallSession.State(rawValue: jsonString(res["state"])) { call?.state = st }
        } catch {
            showFlash("The call could not be accepted: \(error.localizedDescription)")
        }
    }

    func declineCall() {
        guard let s = call else { return }
        stopRinging()
        Task { try? await cli.call("rejectCall", ["callId": s.callId]) }
        endCallLocally(reason: "declined")
    }

    func hangUp() {
        guard let s = call else { return }
        Task { try? await cli.call("hangupCall", ["callId": s.callId]) }
        endCallLocally(reason: "hangup")
    }

    func toggleCallMute() {
        guard call != nil else { return }
        call!.muted.toggle()
        audioBridge.setMuted(call!.muted)
    }

    func onCallEvent(_ ev: JSON) {
        let id = jsonInt64(ev["callId"])
        guard let state = CallSession.State(rawValue: jsonString(ev["state"])) else { return }
        var peer = jsonString(ev["number"])
        if peer.isEmpty { peer = jsonString(ev["uuid"]) }
        let peerKey = chats.resolveKey(peer)

        if call == nil || call?.callId != id {
            // A new incoming call. A second call while one is active is declined by the tunnel/peer timeout.
            guard state == .ringingIncoming, call?.isActive != true else { return }
            var s = CallSession()
            s.callId = id
            s.peerKey = peerKey
            s.outgoing = jsonBool(ev["isOutgoing"])
            s.state = state
            call = s
            chats.ensure(peerKey)
            startRinging()
            alertIncomingCall(peerKey)
            openMainWindow?() // the incoming-call banner is in the main window
        }
        let i = jsonString(ev["inputDeviceName"]), o = jsonString(ev["outputDeviceName"])
        if !i.isEmpty { call?.inputDevice = i }
        if !o.isEmpty { call?.outputDevice = o }
        call?.state = state

        switch state {
        case .connected:
            stopRinging()
            if call?.connectedAt == nil { call?.connectedAt = Date() }
            if !audioBridge.isRunning, let s = call {
                do {
                    try audioBridge.start(inputDevice: s.inputDevice, outputDevice: s.outputDevice)
                    audioBridge.setMuted(s.muted)
                } catch {
                    showFlash("Call audio could not be connected: \(error.localizedDescription)")
                }
            }
        case .ended:
            endCallLocally(reason: jsonString(ev["reason"]))
        default:
            break
        }
    }

    func endCallLocally(reason: String) {
        stopRinging()
        audioBridge.stop()
        guard var s = call else { return }
        s.state = .ended
        s.endReason = reason
        call = s
        Task {
            try? await Task.sleep(for: .seconds(2))
            if call?.callId == s.callId && call?.state == .ended { call = nil }
        }
    }

    func callConnectionLost() {
        if call?.isActive == true { endCallLocally(reason: "signal-cli disconnected") }
    }

    private func ensureMicrophone() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .audio)
        default:
            if await Dialogs.confirm("Microphone access", "Allow Corvus to use the microphone in System Settings → Privacy & Security → Microphone.",
                                     ok: "Open System Settings") {
                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!)
            }
            return false
        }
    }

    private func startRinging() {
        ringTimer?.invalidate()
        NSSound(named: "Submarine")?.play()
        ringTimer = Timer.scheduledTimer(withTimeInterval: 2.5, repeats: true) { _ in
            NSSound(named: "Submarine")?.play()
        }
    }

    func stopRinging() {
        ringTimer?.invalidate()
        ringTimer = nil
    }

    private func alertIncomingCall(_ key: String) {
        guard let c = chats.convs[key] else { return }
        if !NSApp.isActive { NSApp.requestUserAttention(.criticalRequest) }
        if notify.notifications {
            let hidden = notify.content == .hidden
            notifier.notify(key: key, title: hidden ? "Corvus" : c.title, body: "Incoming voice call", icon: hidden ? nil : avatarImage(c))
        }
    }
}
