import AppKit
import AVFoundation
import UserNotifications

/// Desktop notifications through the macOS notification centre. One notification per
/// conversation: a newer one replaces the old one, and clicking it opens the chat.
@MainActor
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    var onActivate: ((String) -> Void)?
    /// "Reply" typed into a message notification: conversation key and text.
    var onReply: ((String, String) -> Void)?
    /// "Mark as read" on a message notification.
    var onMarkRead: ((String) -> Void)?
    private var authorized: Bool?

    /// What a notification offers besides opening the chat (like Signal Desktop's notifications).
    enum Kind: String {
        case plain = ""
        case message = "corvus.message"               // Reply, Mark as read
        case privateMessage = "corvus.message.private" // Mark as read only: the notification does not say who wrote
    }

    static let replyAction = "corvus.reply"
    static let markReadAction = "corvus.markRead"

    /// UNUserNotificationCenter only works inside an app bundle (not for `swift run`).
    var available: Bool { !HiddenMode.on && Bundle.main.bundleIdentifier != nil && Bundle.main.bundleURL.pathExtension == "app" }

    private var center: UNUserNotificationCenter? { available ? .current() : nil }

    func setUp() {
        guard let center else { return }
        center.delegate = self
        let reply = UNTextInputNotificationAction(identifier: Self.replyAction, title: "Reply", options: [],
                                                  textInputButtonTitle: "Send", textInputPlaceholder: "Message")
        let markRead = UNNotificationAction(identifier: Self.markReadAction, title: "Mark as read", options: [])
        center.setNotificationCategories([
            UNNotificationCategory(identifier: Kind.message.rawValue, actions: [reply, markRead], intentIdentifiers: []),
            UNNotificationCategory(identifier: Kind.privateMessage.rawValue, actions: [markRead], intentIdentifiers: []),
        ])
    }

    func requestAuthorization() async -> Bool {
        guard let center else { return false }
        if let authorized { return authorized }
        let ok = (try? await center.requestAuthorization(options: [.alert, .sound, .badge])) ?? false
        authorized = ok
        return ok
    }

    /// `sound` plays with the notification, so macOS silences it like the banner (Do Not Disturb, Sleep and
    /// other Focus modes, the per-app sound switch). `soundFallback` runs instead when no notification can be
    /// shown (not allowed in System Settings).
    func notify(key: String, title: String, body: String, icon: NSImage?, kind: Kind = .plain,
                sound: UNNotificationSound? = nil, soundFallback: (() -> Void)? = nil) {
        guard let center else {
            soundFallback?()
            return
        }
        Task {
            guard await requestAuthorization() else {
                soundFallback?()
                return
            }
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            content.sound = sound
            content.threadIdentifier = key
            content.userInfo = ["key": key]
            content.categoryIdentifier = kind.rawValue
            if let icon, let png = Media.pngData(icon),
               let url = try? Media.writeTemp(png, name: "avatar.png"),
               let att = try? UNNotificationAttachment(identifier: "avatar", url: url) {
                content.attachments = [att]
            }
            // The identifier is the conversation key, so a newer notification replaces the old one.
            let req = UNNotificationRequest(identifier: Notifier.identifier(key), content: content, trigger: nil)
            try? await center.add(req)
        }
    }

    func close(_ key: String) {
        center?.removeDeliveredNotifications(withIdentifiers: [Notifier.identifier(key)])
    }

    private static func identifier(_ key: String) -> String { "conversation:" + key }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let key = response.notification.request.content.userInfo["key"] as? String ?? ""
        let action = response.actionIdentifier
        let text = (response as? UNTextInputNotificationResponse)?.userText ?? ""
        await MainActor.run {
            switch action {
            case Notifier.replyAction: self.onReply?(key, text)
            case Notifier.markReadAction: self.onMarkRead?(key)
            case UNNotificationDismissActionIdentifier: break
            default: self.onActivate?(key)
            }
        }
    }

    /// The app decides itself when to alert (not while the user looks at the chat), so show banners in the foreground too.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }
}

/// Built-in sounds (synthesised like the Qt app, plus the bundled pop) or a custom file.
@MainActor
final class SoundPlayer {
    static let builtins: [(id: String, title: String)] = [
        ("pop-ogg", "Pop (default)"), ("chime", "Chime"), ("pop", "Pop (synthesised)"), ("ding", "Ding"),
    ]

    private var current: NSSound?
    private var prepared: (source: String, sound: UNNotificationSound)?

    /// Plays the configured sound; returns an error text if that was not possible.
    @discardableResult
    func play(_ s: NotificationSettings) -> String? {
        if HiddenMode.on { return nil }
        guard let url = resolve(s) else {
            NSSound.beep()
            return "No audio file is available to play."
        }
        current?.stop()
        guard let sound = NSSound(contentsOf: url, byReference: true) else {
            NSSound.beep()
            return "The sound file could not be played: \(url.lastPathComponent)"
        }
        current = sound
        sound.play()
        return nil
    }

    /// The configured sound for a notification. macOS plays notification sounds only from ~/Library/Sounds
    /// (or the app bundle) and only as AIFF, WAV or CAF: the file is copied there as "Corvus …", converted
    /// when it is another format. Nil when that is not possible.
    func notificationSound(_ s: NotificationSettings) -> UNNotificationSound? {
        if HiddenMode.on { return nil }
        guard let src = resolve(s) else { return nil }
        let stamp = (try? FileManager.default.attributesOfItem(atPath: src.path)[.modificationDate] as? Date)?
            .timeIntervalSince1970 ?? 0
        let source = "\(src.path)|\(stamp)"
        if let prepared, prepared.source == source { return prepared.sound }
        guard let dir = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Sounds", isDirectory: true) else { return nil }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let label = s.soundId == "custom" ? "Custom" : (Self.builtins.first { $0.id == s.soundId }?.title ?? "Chime")
            .replacingOccurrences(of: " (default)", with: "").replacingOccurrences(of: " (synthesised)", with: " 2")
        let ext = src.pathExtension.lowercased()
        let playable = ["aif", "aiff", "wav", "caf"].contains(ext)
        let name = "Corvus \(label).\(playable ? ext : "caf")"
        let dest = dir.appendingPathComponent(name)
        // Only one Corvus sound at a time in the user's Sounds folder (System Settings lists them).
        for old in (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        where old.hasPrefix("Corvus ") && old != name {
            try? FileManager.default.removeItem(at: dir.appendingPathComponent(old))
        }
        try? FileManager.default.removeItem(at: dest)
        do {
            if playable {
                try FileManager.default.copyItem(at: src, to: dest)
            } else {
                try Self.convertToCaf(src, dest)
            }
        } catch {
            return nil
        }
        let sound = UNNotificationSound(named: UNNotificationSoundName(name))
        prepared = (source, sound)
        return sound
    }

    /// Another audio format (MP3, M4A …) as linear PCM in a CAF file; at most 30 s (the notification limit).
    private static func convertToCaf(_ src: URL, _ dest: URL) throws {
        let input = try AVAudioFile(forReading: src)
        let format = input.processingFormat
        let pcm16: [String: Any] = [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: format.sampleRate,
                                    AVNumberOfChannelsKey: format.channelCount, AVLinearPCMBitDepthKey: 16,
                                    AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false]
        let output = try AVAudioFile(forWriting: dest, settings: pcm16, commonFormat: format.commonFormat,
                                     interleaved: format.isInterleaved)
        let total = min(input.length, AVAudioFramePosition(format.sampleRate * 29))
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 32768) else { throw CocoaError(.fileWriteUnknown) }
        var done: AVAudioFramePosition = 0
        while done < total {
            buffer.frameLength = 0
            try input.read(into: buffer, frameCount: AVAudioFrameCount(min(32768, total - done)))
            if buffer.frameLength == 0 { break }
            try output.write(from: buffer)
            done += AVAudioFramePosition(buffer.frameLength)
        }
    }

    private func resolve(_ s: NotificationSettings) -> URL? {
        if s.soundId == "custom", !s.soundFile.isEmpty, FileManager.default.fileExists(atPath: s.soundFile) {
            return URL(fileURLWithPath: s.soundFile)
        }
        if s.soundId == "pop-ogg" || s.soundId == "custom" {
            return AppResources.url("pop", "wav")
        }
        let id = ["chime", "pop", "ding"].contains(s.soundId) ? s.soundId : "chime"
        let url = AppPaths.tempDir.appendingPathComponent("\(id).wav")
        if !FileManager.default.fileExists(atPath: url.path) {
            try? SoundPlayer.synthesize(id).write(to: url)
        }
        return url
    }

    // MARK: Synthesis (same sounds as src/SoundPlayer.cpp)

    private static let rate = 44100

    private static func addNote(_ buf: inout [Float], freq: Double, start: Double, dur: Double, amp: Double, decay: Double) {
        let from = Int(start * Double(rate)), n = Int(dur * Double(rate))
        if from + n > buf.count { buf += [Float](repeating: 0, count: from + n - buf.count) }
        for i in 0..<n {
            let t = Double(i) / Double(rate)
            let env = exp(-t * decay) * min(1, t / 0.004) * min(1, (dur - t) / 0.02)
            let ph = 2 * Double.pi * freq * t
            buf[from + i] += Float(amp * env * (sin(ph) + 0.28 * sin(2 * ph) + 0.08 * sin(3 * ph)))
        }
    }

    static func synthesize(_ id: String) -> Data {
        var buf: [Float] = []
        switch id {
        case "pop":
            let n = Int(0.14 * Double(rate))
            buf = [Float](repeating: 0, count: n)
            var phase = 0.0
            for i in 0..<n {
                let t = Double(i) / Double(rate)
                phase += 2 * Double.pi * (950 - 520 * min(1, t / 0.1)) / Double(rate)
                let env = exp(-t * 28) * min(1, t / 0.002) * min(1, (0.14 - t) / 0.01)
                buf[i] = Float(0.6 * env * sin(phase))
            }
        case "ding":
            addNote(&buf, freq: 1046.5, start: 0, dur: 0.9, amp: 0.5, decay: 4.5)
        default:
            addNote(&buf, freq: 1318.5, start: 0, dur: 0.45, amp: 0.45, decay: 7)
            addNote(&buf, freq: 1760, start: 0.16, dur: 0.65, amp: 0.45, decay: 5.5)
        }
        let peak = buf.map(abs).max() ?? 0
        if peak > 0 { buf = buf.map { $0 / peak * 0.8 } }

        var pcm = Data(capacity: buf.count * 2)
        for v in buf {
            var s = Int16(max(-1, min(1, v)) * 32767).littleEndian
            withUnsafeBytes(of: &s) { pcm.append(contentsOf: $0) }
        }
        func le32(_ v: UInt32) -> Data { withUnsafeBytes(of: v.littleEndian) { Data($0) } }
        func le16(_ v: UInt16) -> Data { withUnsafeBytes(of: v.littleEndian) { Data($0) } }
        var w = Data("RIFF".utf8)
        w += le32(UInt32(36 + pcm.count))
        w += Data("WAVEfmt ".utf8)
        w += le32(16) + le16(1) + le16(1) + le32(UInt32(rate)) + le32(UInt32(rate * 2)) + le16(2) + le16(16)
        w += Data("data".utf8) + le32(UInt32(pcm.count)) + pcm
        return w
    }
}
