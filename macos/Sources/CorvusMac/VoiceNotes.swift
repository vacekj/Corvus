import AppKit
import AVFoundation
import CorvusCore
import SwiftUI

/// Playback of voice notes and other audio attachments: one at a time, with seeking, a persisted
/// playback speed and autoplay of the next consecutive voice note.
@MainActor @Observable
final class AudioPlayback {
    static let speedKey = "media.voiceNoteSpeed"

    private(set) var token: String?
    private(set) var loading = false
    private(set) var playing = false
    private(set) var position: Double = 0
    private(set) var duration: Double = 0
    private(set) var speed: Double
    /// A player exists for `token` (it can be paused, sought and sped up).
    private(set) var ready = false

    @ObservationIgnored private var player: AVPlayer?
    @ObservationIgnored private var timeObserver: Any?
    @ObservationIgnored private var endObserver: NSObjectProtocol?
    @ObservationIgnored private var file: URL?
    @ObservationIgnored private(set) var conversation = ""
    @ObservationIgnored private(set) var messageId = ""
    /// Called when a note played to its end (conversation, message id).
    @ObservationIgnored var onFinished: ((String, String) -> Void)?

    init() {
        let s = UserDefaults.standard.double(forKey: AudioPlayback.speedKey)
        speed = Waveform.speeds.contains(s) ? s : 1
    }

    func begin(token: String, conversation: String, messageId: String) {
        stop()
        self.token = token
        self.conversation = conversation
        self.messageId = messageId
        loading = true
    }

    func fail() {
        loading = false
        token = nil
    }

    /// Starts the loaded file, optionally at a fraction of its length.
    func start(_ url: URL, at fraction: Double?, knownDuration: Double?) {
        let item = AVPlayerItem(url: url)
        item.audioTimePitchAlgorithm = .timeDomain // keeps voices natural at 1.5× / 2×
        let p = AVPlayer(playerItem: item)
        p.defaultRate = Float(speed)
        player = p
        file = url
        if let knownDuration, knownDuration > 0 { duration = knownDuration }
        timeObserver = p.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 15), queue: .main) { [weak self, weak p] t in
            MainActor.assumeIsolated {
                guard let self, let p else { return }
                let s = t.seconds
                if s.isFinite, abs(s - self.position) > 0.001 { self.position = s }
                if let d = p.currentItem?.duration.seconds, d.isFinite, d > 0, d != self.duration { self.duration = d }
            }
        }
        endObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item,
                                                             queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.finished() }
        }
        loading = false
        ready = true
        if let fraction { seek(fraction) }
        p.play()
        playing = true
    }

    func togglePause() {
        guard let p = player else { return }
        if playing {
            p.pause()
            playing = false
        } else {
            if duration > 0 && position >= duration - 0.05 { p.seek(to: .zero) }
            p.play()
            playing = true
        }
    }

    func seek(_ fraction: Double) {
        guard let p = player else { return }
        let d = duration > 0 ? duration : (p.currentItem?.duration.seconds ?? 0)
        guard d.isFinite, d > 0 else { return }
        let s = min(max(fraction, 0), 1) * d
        position = s
        p.seek(to: CMTime(seconds: s, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
    }

    func cycleSpeed() {
        speed = Waveform.nextSpeed(after: speed)
        UserDefaults.standard.set(speed, forKey: AudioPlayback.speedKey)
        player?.defaultRate = Float(speed)
        if playing { player?.rate = Float(speed) }
    }

    private func finished() {
        let (c, m) = (conversation, messageId)
        playing = false
        position = 0
        player?.seek(to: .zero)
        onFinished?(c, m)
    }

    func stop() {
        player?.pause()
        if let o = timeObserver { player?.removeTimeObserver(o) }
        if let o = endObserver { NotificationCenter.default.removeObserver(o) }
        timeObserver = nil
        endObserver = nil
        player = nil
        if let f = file { try? FileManager.default.removeItem(at: f.deletingLastPathComponent()) }
        file = nil
        if ready { ready = false }
        if playing { playing = false }
        if loading { loading = false }
        if position != 0 { position = 0 }
        if duration != 0 { duration = 0 }
        if token != nil { token = nil }
    }
}

extension AppModel {
    /// Play / pause an audio attachment. With `fraction`, playback jumps there (and starts if it was another note).
    func toggleAudio(_ m: Message, _ i: Int, at fraction: Double? = nil) {
        guard let key = current, i < m.attachments.count else { return }
        let token = attachmentToken(m, i)
        if audio.token == token {
            if audio.loading { return }
            if audio.ready {
                if let fraction {
                    audio.seek(fraction)
                    if !audio.playing { audio.togglePause() }
                } else {
                    audio.togglePause()
                }
                return
            }
        }
        if audio.onFinished == nil {
            audio.onFinished = { [weak self] conversation, id in self?.playNextVoiceNote(conversation, after: id) }
        }
        audio.begin(token: token, conversation: key, messageId: m.id)
        let att = m.attachments[i]
        Task {
            do {
                let data = try await fetchAttachmentData(key, att)
                guard audio.token == token else { return }
                guard !data.isEmpty else { throw RpcError("The audio file is empty.") }
                let suffix = AttachmentPolicy.mediaSuffix(filename: att.filename, contentType: att.contentType, fallback: "m4a")
                let url = try Media.writeAttachmentTemp(data, name: "audio." + suffix)
                guard audio.token == token else {
                    try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
                    return
                }
                audio.start(url, at: fraction, knownDuration: WaveformStore.shared.cached(WaveformStore.key(att))?.duration)
            } catch {
                if audio.token == token { audio.fail() }
                showFlash("Audio playback failed: \(error.localizedDescription)")
            }
        }
    }

    /// Consecutive voice notes play one after the other while their chat stays open.
    private func playNextVoiceNote(_ conversation: String, after id: String) {
        guard current == conversation, let c = chats.convs[conversation],
              let (next, index) = VoiceNoteQueue.next(after: id, in: c.msgs) else { return }
        toggleAudio(next, index)
    }

    /// Waveform and duration of an audio attachment, computed once off the main thread.
    func waveform(_ key: String, _ att: Attachment) async -> WaveformStore.Info? {
        await WaveformStore.shared.info(WaveformStore.key(att)) { [weak self] in
            guard let data = try? await self?.fetchAttachmentData(key, att), !data.isEmpty else { return nil }
            let suffix = AttachmentPolicy.mediaSuffix(filename: att.filename, contentType: att.contentType, fallback: "m4a")
            return await Task.detached(priority: .utility) { await WaveformStore.analyze(data, suffix: suffix) }.value
        }
    }
}

/// Waveforms of audio attachments, kept in memory only (like the decoded pictures).
@MainActor
final class WaveformStore {
    static let shared = WaveformStore()

    final class Info: Sendable {
        let bars: [Float]
        let duration: Double
        init(bars: [Float], duration: Double) {
            self.bars = bars
            self.duration = duration
        }
    }

    private let cache: NSCache<NSString, Info> = { let c = NSCache<NSString, Info>(); c.countLimit = 2000; return c }()
    private var pending: [String: Task<Info?, Never>] = [:]
    private var failed: Set<String> = []

    static func key(_ att: Attachment) -> String { "\(att.id)|\(att.encPath)|\(att.path)|\(att.size)" }

    func cached(_ key: String) -> Info? { cache.object(forKey: key as NSString) }

    func info(_ key: String, load: @escaping @Sendable () async -> Info?) async -> Info? {
        if let i = cached(key) { return i }
        if failed.contains(key) { return nil }
        if let t = pending[key] { return await t.value }
        let t = Task { await load() }
        pending[key] = t
        let info = await t.value
        pending[key] = nil
        if let info { cache.setObject(info, forKey: key as NSString) } else { failed.insert(key) }
        return info
    }

    /// Loudness per 10 ms window, reduced to `Waveform.barCount` bars. Formats AVFoundation can't read
    /// (Ogg/Opus) give nil.
    nonisolated static func analyze(_ data: Data, suffix: String) async -> Info? {
        guard let url = try? Media.writeTemp(data, name: "waveform." + suffix) else { return nil }
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let asset = AVURLAsset(url: url)
        guard let track = try? await asset.loadTracks(withMediaType: .audio).first,
              let duration = try? await asset.load(.duration).seconds,
              let reader = try? AVAssetReader(asset: asset) else { return nil }
        let rate = 8000
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: false,
            AVNumberOfChannelsKey: 1, AVSampleRateKey: rate,
        ])
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { return nil }
        reader.add(output)
        guard reader.startReading() else { return nil }
        let window = rate / 100
        var values: [Float] = []
        var acc: Float = 0, n = 0
        var samples: [Int16] = []
        while let buffer = output.copyNextSampleBuffer(), let block = CMSampleBufferGetDataBuffer(buffer) {
            if Task.isCancelled { reader.cancelReading(); return nil }
            let len = CMBlockBufferGetDataLength(block)
            samples.removeAll(keepingCapacity: true)
            samples.append(contentsOf: repeatElement(0, count: len / 2))
            let ok = samples.withUnsafeMutableBytes { buf in
                buf.baseAddress.map { CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: len / 2 * 2, destination: $0) }
            }
            guard ok == kCMBlockBufferNoErr else { continue }
            for s in samples {
                let f = Float(s) / 32768
                acc += f * f
                n += 1
                if n == window {
                    values.append((acc / Float(n)).squareRoot())
                    acc = 0
                    n = 0
                }
            }
        }
        if n > 0 { values.append((acc / Float(n)).squareRoot()) }
        guard reader.status == .completed, !values.isEmpty else { return nil }
        return Info(bars: Waveform.bars(values), duration: duration.isFinite ? duration : 0)
    }
}

/// An audio attachment: play button, waveform (click or drag to seek), time and playback speed.
struct VoiceNoteView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.conversationKey) private var conversationKey
    let message: Message
    let index: Int
    let attachment: Attachment
    let foreground: Color
    @State private var info: WaveformStore.Info?
    @State private var scrub: Double?

    var body: some View {
        let token = model.attachmentToken(message, index)
        let audio = model.audio
        let active = audio.token == token
        let info = self.info ?? WaveformStore.shared.cached(WaveformStore.key(attachment))
        let played = message.outgoing ? foreground : Theme.signalBlue
        HStack(spacing: 10) {
            Button { model.openAttachment(message, index) } label: {
                ZStack {
                    Circle().fill(message.outgoing ? foreground : Theme.signalBlue)
                    if active && audio.loading {
                        ProgressView().controlSize(.small).tint(message.outgoing ? .black : .white)
                    } else {
                        Image(systemName: active && audio.playing ? "pause.fill" : "play.fill")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(message.outgoing ? Color.black.opacity(0.75) : .white)
                            .offset(x: active && audio.playing ? 0 : 1)
                    }
                }
                .frame(width: 36, height: 36)
            }
            .buttonStyle(.plain)
            .help(active && audio.playing ? "Pause" : "Play")
            VStack(alignment: .leading, spacing: 4) {
                if !attachment.filename.isEmpty {
                    Text(attachment.filename).font(.caption).lineLimit(1).truncationMode(.middle)
                }
                VoiceNoteWaveform(bars: info?.bars, active: active, scrub: scrub, played: played,
                                  rest: foreground.opacity(0.35))
                    .frame(width: 176, height: 26)
                    .contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 0)
                        .onChanged { g in
                            let f = min(max(g.location.x / 176, 0), 1)
                            scrub = f
                            if active && audio.ready { audio.seek(f) }
                        }
                        .onEnded { g in
                            let f = min(max(g.location.x / 176, 0), 1)
                            scrub = nil
                            if !(active && audio.ready) { model.toggleAudio(message, index, at: f) }
                        })
                HStack(spacing: 6) {
                    VoiceNoteTime(active: active, duration: info?.duration ?? 0)
                    Spacer(minLength: 0)
                    if active && audio.ready {
                        Button { audio.cycleSpeed() } label: {
                            Text(Waveform.speedLabel(audio.speed))
                                .font(.caption2.weight(.semibold).monospacedDigit())
                                .padding(.horizontal, 6)
                                .padding(.vertical, 1)
                                .background(Capsule().fill(foreground.opacity(0.18)))
                        }
                        .buttonStyle(.plain)
                        .help("Playback speed")
                    }
                }
                .frame(width: 176)
            }
        }
        .foregroundStyle(foreground)
        .task(id: WaveformStore.key(attachment)) {
            if self.info != nil || conversationKey.isEmpty { return }
            if let i = await model.waveform(conversationKey, attachment) { self.info = i }
        }
    }
}

/// The bars; only the playing note reads the position (10+ updates per second).
private struct VoiceNoteWaveform: View {
    @Environment(AppModel.self) private var model
    let bars: [Float]?
    let active: Bool
    let scrub: Double?
    let played: Color
    let rest: Color

    var body: some View {
        let progress: Double = {
            if let scrub { return scrub }
            guard active else { return 0 }
            let a = model.audio
            return a.duration > 0 ? min(1, a.position / a.duration) : 0
        }()
        let bars = self.bars ?? Array(repeating: 0.12, count: Waveform.barCount)
        Canvas { ctx, size in
            let n = bars.count
            guard n > 0 else { return }
            let step = size.width / CGFloat(n)
            let w = max(1.5, step * 0.55)
            let cut = CGFloat(progress) * size.width
            for (i, b) in bars.enumerated() {
                let h = max(3, CGFloat(b) * size.height)
                let x = CGFloat(i) * step + (step - w) / 2
                let r = CGRect(x: x, y: (size.height - h) / 2, width: w, height: h)
                ctx.fill(Path(roundedRect: r, cornerRadius: w / 2), with: .color(x + w / 2 <= cut ? played : rest))
            }
        }
    }
}

private struct VoiceNoteTime: View {
    @Environment(AppModel.self) private var model
    let active: Bool
    let duration: Double

    var body: some View {
        let a = model.audio
        let total = active && a.duration > 0 ? a.duration : duration
        // Like Signal: the remaining time while playing, the length otherwise.
        let shown = active && a.ready ? max(0, total - a.position) : total
        Text(Waveform.time(shown))
            .font(.caption2.monospacedDigit())
            .opacity(0.75)
    }
}
