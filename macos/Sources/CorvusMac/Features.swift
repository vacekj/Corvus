import AppKit
import AVFoundation
import CorvusCore
import SwiftUI

/// An installed sticker pack as reported by `listStickerPacks`.
struct StickerPack: Identifiable, Equatable {
    struct Sticker: Identifiable, Equatable {
        var id: Int
        var emoji: String
        var key: String          // "packId:stickerId"
    }

    var id: String               // pack id (hex)
    var title: String
    var author: String
    var installed: Bool
    var stickers: [Sticker]
}

/// The identity of a contact as reported by `listIdentities`.
struct IdentityInfo: Equatable {
    var safetyNumber = ""        // 60 digits
    var scannable = ""           // base64 of the scannable fingerprint (QR code)
    var trustLevel = ""          // UNTRUSTED, TRUSTED_UNVERIFIED, TRUSTED_VERIFIED
    var addedMs: Int64 = 0

    var isVerified: Bool { trustLevel == "TRUSTED_VERIFIED" }

    /// 12 blocks of 5 digits, as shown by the official clients.
    var blocks: [String] {
        let digits = Array(safetyNumber.filter(\.isNumber))
        return stride(from: 0, to: digits.count, by: 5).map { String(digits[$0..<min($0 + 5, digits.count)]) }
    }
}

extension AppModel {
    // MARK: - Stickers

    static func stickerKey(_ packId: String, _ stickerId: Int) -> String { "\(packId):\(stickerId)" }

    func loadStickerPacks() {
        Task {
            guard let res = try? await cli.call("listStickerPacks") else { return }
            stickerPacks = jsonArray(res).map(jsonObject).compactMap { o in
                let packId = jsonString(o["packId"])
                guard !packId.isEmpty else { return nil }
                let stickers = jsonArray(o["stickers"]).map(jsonObject).map { s in
                    let id = jsonInt(s["id"])
                    return StickerPack.Sticker(id: id, emoji: jsonString(s["emoji"]), key: AppModel.stickerKey(packId, id))
                }
                return StickerPack(id: packId, title: jsonString(o["title"]), author: jsonString(o["author"]),
                                   installed: jsonBool(o["installed"]), stickers: stickers)
            }
            .filter { $0.installed && !$0.stickers.isEmpty }
        }
    }

    /// Sticker images come from signal-cli's sticker store (`getSticker`), cached in memory.
    func loadSticker(packId: String, stickerId: Int) {
        let k = AppModel.stickerKey(packId, stickerId)
        guard stickerImages[k] == nil, !stickerPending.contains(k), cli.isRunning else { return }
        stickerPending.insert(k)
        Task {
            defer { stickerPending.remove(k) }
            for attempt in 0..<3 {
                if let res = try? await cli.call("getSticker", ["packId": packId, "stickerId": stickerId]),
                   let data = Data(base64Encoded: jsonString(jsonObject(res)["data"])), !data.isEmpty {
                    stickerImages[k] = data
                    return
                }
                // A just received pack may still be downloading.
                try? await Task.sleep(for: .seconds(2 * (attempt + 1)))
            }
        }
    }

    func sendSticker(packId: String, stickerId: Int) {
        sendMessage(sticker: Attachment.sticker(packId: packId, stickerId: stickerId))
    }

    /// Opens the sticker picker of the composer with the "add pack" field shown (menu command).
    func requestStickerPackAdd() {
        stickerPackAddPending = true
        stickerPackAddRequest += 1
    }

    /// Installs a pack from a signal.art link; returns an error message on failure.
    func addStickerPack(_ link: StickerPackLink) async -> String? {
        do {
            try await cli.call("addStickerPack", ["uri": link.uri])
            showFlash("Sticker pack added.", seconds: 5)
            loadStickerPacks()
            return nil
        } catch {
            return "Could not add the sticker pack: \(error.localizedDescription)"
        }
    }

    // MARK: - Polls

    func createPoll(question: String, options: [String], allowMultiple: Bool) {
        guard let key = current, let c = chats.convs[key], !isSendLocked(key) else { return }
        let q = question.trimmingCharacters(in: .whitespacesAndNewlines)
        let opts = options.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        guard !q.isEmpty, (2...10).contains(opts.count) else {
            showFlash("A poll needs a question and 2 to 10 options.", seconds: 6)
            return
        }
        var p: JSON = ["question": q, "options": opts, "noMulti": !allowMultiple]
        addRecipient(&p, c)
        Task { [p] in
            do {
                let res = try await cli.call("sendPollCreate", p)
                var ts = jsonInt64(jsonObject(res)["timestamp"])
                if ts <= 0 { ts = nowMs() }
                var m = Message()
                m.ts = ts
                m.outgoing = true
                m.authorKey = account
                m.text = "📊 " + q
                m.poll.question = q
                m.poll.options = opts
                m.poll.allowMultiple = allowMultiple
                m.expiresInSeconds = c.expirationSeconds
                if m.expiresInSeconds > 0 { m.expirationStartMs = ts }
                addMessage(key, m)
            } catch {
                showFlash("Could not send the poll: \(error.localizedDescription)")
            }
        }
    }

    /// Votes (or changes the vote) on a poll; an empty selection takes the vote back.
    func votePoll(_ id: String, options chosen: [Int]) {
        guard let c = currentConversation, let (_, m) = message(withId: id), m.isPoll, !m.poll.ended else { return }
        let author = chats.effectiveAuthor(c, m)
        let count = (m.poll.voteCounts[account] ?? 0) + 1
        var p: JSON = ["pollAuthor": author, "pollTimestamp": m.ts, "options": chosen, "voteCount": count]
        addRecipient(&p, c)
        let key = c.key, ts = m.ts
        Task { [p] in
            do {
                try await cli.call("sendPollVote", p)
                if let rec = chats.applyPollVote(key, targetTs: ts, authors: [author], voter: account, options: chosen, voteCount: count) {
                    persist(rec)
                }
            } catch {
                showFlash("Could not vote: \(error.localizedDescription)")
            }
        }
    }

    func endPoll(_ id: String) {
        guard let c = currentConversation, let (_, m) = message(withId: id), m.isPoll, m.outgoing, !m.poll.ended else { return }
        var p: JSON = ["pollTimestamp": m.ts]
        addRecipient(&p, c)
        let key = c.key, ts = m.ts
        Task { [p] in
            do {
                try await cli.call("sendPollTerminate", p)
                if let rec = chats.applyPollTerminate(key, targetTs: ts, authors: [account]) { persist(rec) }
            } catch {
                showFlash("Could not end the poll: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - View Once

    /// Opens View Once media once: it is shown in a viewer, then its reference is dropped for good.
    func openViewOnce(_ id: String) {
        guard let key = current, let c = chats.convs[key], let (_, m) = message(withId: id), m.viewOnce,
              !m.viewOnceConsumed, let att = m.attachments.first else { return }
        let author = chats.effectiveAuthor(c, m)
        showFlash("Loading …", seconds: 60)
        Task {
            defer { clearFlash() }
            do {
                let data = try await fetchAttachmentData(key, att)
                guard !data.isEmpty else { throw RpcError("The media is empty.") }
                if att.isVideo {
                    let suffix = AttachmentPolicy.mediaSuffix(filename: att.filename, contentType: att.contentType, fallback: "mp4")
                    let url = try Media.writeAttachmentTemp(data, name: "view-once." + suffix)
                    ImageViewerWindow.showViewOnce(video: url)
                } else {
                    guard NSImage(data: data) != nil else { throw RpcError("The picture could not be shown.") }
                    ImageViewerWindow.showViewOnce(image: data)
                }
                if let rec = chats.markViewOnceViewed(key, ts: m.ts, authors: [author]) {
                    // Rewrite instead of append, so the attachment reference is really gone from the file.
                    do { try store.rewrite(chats.allRecords()) } catch { persist(rec) }
                }
            } catch {
                await Dialogs.warn("View once media", error.localizedDescription)
            }
        }
    }

    var canSendViewOnce: Bool {
        pendingFiles.count == 1 && composerText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && ["image/", "video/"].contains { Media.mimeType(forFile: pendingFiles[0]).hasPrefix($0) }
    }

    // MARK: - Voice messages

    func startRecording() {
        guard !isRecording, current != nil else { return }
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            beginRecording()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { ok in
                Task { @MainActor in
                    if ok { self.beginRecording() } else { self.showFlash("Corvus may not use the microphone.", seconds: 6) }
                }
            }
        default:
            Task {
                if await Dialogs.confirm("Microphone access", "Allow Corvus to use the microphone in System Settings → Privacy & Security → Microphone.",
                                         ok: "Open System Settings") {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!)
                }
            }
        }
    }

    private func beginRecording() {
        let url = AppPaths.tempDir.appendingPathComponent("voice-\(UUID().uuidString).m4a")
        try? FileManager.default.createDirectory(at: AppPaths.tempDir, withIntermediateDirectories: true)
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 44100,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 64000,
        ]
        do {
            let r = try AVAudioRecorder(url: url, settings: settings)
            guard r.record() else { throw RpcError("The recording could not be started.") }
            recorder = r
            isRecording = true
            recordingStarted = Date()
        } catch {
            showFlash("Recording failed: \(error.localizedDescription)")
        }
    }

    /// Stops the recording; `send` false discards it.
    func stopRecording(send: Bool) {
        guard let r = recorder else { return }
        let duration = r.currentTime
        r.stop()
        recorder = nil
        isRecording = false
        recordingStarted = nil
        let path = r.url.path
        guard send, duration >= 0.5 else {
            try? FileManager.default.removeItem(atPath: path)
            if send { showFlash("The voice message was too short.", seconds: 4) }
            return
        }
        // Signal clients name voice notes like this.
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd-HHmmss"
        let named = AppPaths.tempDir.appendingPathComponent("Voice message \(f.string(from: Date())).m4a").path
        let file = (try? FileManager.default.moveItem(atPath: path, toPath: named)) != nil ? named : path
        let keep = pendingFiles, keepText = composerText
        pendingFiles = [file]
        composerText = ""
        voiceNoteNext = true
        sendMessage()
        // Whatever was in the composer before stays there; an unsent recording stays in the tray.
        let sent = pendingFiles.isEmpty
        pendingFiles = sent ? keep : keep + [file]
        composerText = keepText
    }

    // MARK: - Safety numbers

    func loadIdentity(_ key: String) async -> IdentityInfo? {
        guard let res = try? await cli.call("listIdentities", ["number": chats.resolveKey(key)]) else { return nil }
        let all = jsonArray(res).map(jsonObject)
        guard let o = all.first(where: { !jsonString($0["safetyNumber"]).isEmpty }) ?? all.first else { return nil }
        return IdentityInfo(safetyNumber: jsonString(o["safetyNumber"]), scannable: jsonString(o["scannableSafetyNumber"]),
                            trustLevel: jsonString(o["trustLevel"]), addedMs: jsonInt64(o["addedTimestamp"]))
    }

    /// Marks the contact as verified: signal-cli `trust --verified-safety-number`.
    func markVerified(_ key: String, _ info: IdentityInfo) async -> Bool {
        do {
            try await cli.call("trust", ["recipient": chats.resolveKey(key), "verifiedSafetyNumber": info.safetyNumber])
            showFlash("Marked as verified.", seconds: 5)
            return true
        } catch {
            showFlash("Could not mark as verified: \(error.localizedDescription)")
            return false
        }
    }

    /// Trust the current (possibly changed) key again without verifying it.
    func trustKnownKeys(_ key: String) async -> Bool {
        do {
            try await cli.call("trust", ["recipient": chats.resolveKey(key), "trustAllKnownKeys": true])
            showFlash("Verification cleared.", seconds: 5)
            return true
        } catch {
            showFlash("Could not change the trust: \(error.localizedDescription)")
            return false
        }
    }

    // MARK: - Forwarding

    static let maxForwardTargets = 5

    /// Forwards text, attachments or a sticker to up to five chats (like Signal Desktop).
    func forward(messageId: String, to targets: [String]) {
        guard let source = current, let (_, m) = message(withId: messageId), !m.deleted, !m.viewOnce, !m.isPoll else { return }
        let keys = Array(targets.prefix(AppModel.maxForwardTargets)).filter { chats.convs[$0] != nil && !isSendLocked($0) }
        guard !keys.isEmpty else { return }
        forwardMessageId = nil
        showFlash("Forwarding …", seconds: 120)
        Task {
            defer { clearFlash() }
            // Attachment data is fetched once and staged for all targets.
            var files: [String] = []
            let tmp = AppPaths.tempDir.appendingPathComponent("forward-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: tmp) }
            let sticker = m.attachments.first(where: \.isSticker)
            if sticker == nil {
                do {
                    try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
                    for (i, att) in m.attachments.enumerated() {
                        let data = try await fetchAttachmentData(source, att)
                        var name = (att.filename as NSString).lastPathComponent
                        if name.isEmpty { name = "attachment-\(i)." + Media.preferredSuffix(forMime: att.contentType) }
                        let url = tmp.appendingPathComponent("\(i)-" + name)
                        try data.write(to: url)
                        files.append(url.path)
                    }
                } catch {
                    showFlash("Could not forward the attachment: \(error.localizedDescription)")
                    return
                }
            }
            var failed: [String] = []
            for key in keys {
                guard let c = chats.convs[key] else { continue }
                var p: JSON = [:]
                if !m.text.isEmpty { p["message"] = m.text }
                if !m.text.isEmpty && !m.textStyles.isEmpty { p["textStyle"] = m.textStyles.map(\.cliString) }
                if let sticker { p["sticker"] = "\(sticker.stickerPackId):\(sticker.stickerId)" }
                let staged = Media.stageForSignalCli(files)
                if !files.isEmpty { p["attachments"] = staged.paths }
                addRecipient(&p, c)
                do {
                    let res = try await cli.call("send", p)
                    var ts = jsonInt64(jsonObject(res)["timestamp"])
                    if ts <= 0 { ts = nowMs() }
                    var copy = Message()
                    copy.ts = ts
                    copy.text = m.text
                    copy.textStyles = m.textStyles
                    copy.outgoing = true
                    copy.authorKey = account
                    copy.attachments = m.attachments.enumerated().map { i, a in
                        var b = a
                        b.id = ""
                        if i < files.count { b.path = "" }
                        return b
                    }
                    copy.expiresInSeconds = c.expirationSeconds
                    if copy.expiresInSeconds > 0 { copy.expirationStartMs = ts }
                    addMessage(key, copy)
                } catch {
                    failed.append(c.title)
                }
                try? FileManager.default.removeItem(at: staged.dir)
            }
            if !failed.isEmpty {
                showFlash("Forwarding failed for: \(failed.joined(separator: ", "))")
            } else {
                showFlash(keys.count == 1 ? "Forwarded." : "Forwarded to \(keys.count) chats.", seconds: 4)
            }
        }
    }

    // MARK: - Stories

    var activeStories: [Story] {
        let now = nowMs()
        return stories.filter { !$0.isExpired(now: now) }.sorted { $0.ts > $1.ts }
    }

    var unviewedStories: Int { activeStories.filter { !$0.viewed && !$0.outgoing }.count }

    func receiveStory(_ pe: ParsedEnvelope, srcKey: String) {
        var st = pe.story
        st.authorKey = pe.outgoing ? account : srcKey
        if st.authorName.isEmpty { st.authorName = pe.outgoing ? "You" : displayName(srcKey) }
        if st.isExpired(now: nowMs()) || stories.contains(where: { $0.id == st.id }) { return }
        stories.append(st)
        stories.removeAll { $0.isExpired(now: nowMs()) }
    }

    /// Title of the story list entry: the group for group stories, otherwise the author.
    func storyTitle(_ st: Story) -> String {
        if !st.groupId.isEmpty { return chats.convs["g:" + st.groupId]?.title ?? "Group story" }
        if st.outgoing { return "My Story" }
        let key = chats.resolveKey(st.authorKey)
        if let c = chats.convs[key], c.title != key { return c.title }
        return chats.contactNames[key] ?? (st.authorName.isEmpty ? key : st.authorName)
    }

    func markStoryViewed(_ id: String) {
        guard let i = stories.firstIndex(where: { $0.id == id }), !stories[i].viewed else { return }
        stories[i].viewed = true
    }

    func fetchStoryMedia(_ st: Story) async throws -> Data {
        guard let att = st.attachment, !att.id.isEmpty || !att.path.isEmpty else { throw RpcError("The story has no media.") }
        if !att.path.isEmpty, let d = FileManager.default.contents(atPath: att.path) { return d }
        var p: JSON = ["id": att.id]
        if !st.groupId.isEmpty { p["groupId"] = st.groupId } else { p["recipient"] = [chats.resolveKey(st.authorKey)] }
        let res = try await cli.call("getAttachment", p)
        return Data(base64Encoded: jsonString(jsonObject(res)["data"])) ?? Data()
    }

    func replyToStory(_ st: Story, text: String) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, st.allowsReplies, !st.outgoing else { return }
        let key = st.groupId.isEmpty ? chats.resolveKey(st.authorKey) : "g:" + st.groupId
        var p: JSON = ["message": t, "storyTimestamp": st.ts, "storyAuthor": chats.resolveKey(st.authorKey)]
        if st.groupId.isEmpty { p["recipient"] = [key] } else { p["groupId"] = st.groupId }
        Task { [p] in
            do {
                let res = try await cli.call("send", p)
                var ts = jsonInt64(jsonObject(res)["timestamp"])
                if ts <= 0 { ts = nowMs() }
                var m = Message()
                m.ts = ts
                m.text = t
                m.outgoing = true
                m.authorKey = account
                m.quote.valid = true
                m.quote.id = st.ts
                m.quote.authorKey = st.authorKey
                m.quote.text = "Story"
                m.quote.attachmentNote = "story"
                addMessage(key, m, title: st.groupId.isEmpty ? displayName(key) : "Group", group: !st.groupId.isEmpty)
                showFlash("Reply sent.", seconds: 3)
            } catch {
                showFlash("Could not reply to the story: \(error.localizedDescription)")
            }
        }
    }

    func reactToStory(_ st: Story, emoji: String) {
        guard st.allowsReplies, !st.outgoing else { return }
        var p: JSON = ["emoji": emoji, "targetAuthor": chats.resolveKey(st.authorKey), "targetTimestamp": st.ts, "story": true]
        if st.groupId.isEmpty { p["recipient"] = [chats.resolveKey(st.authorKey)] } else { p["groupId"] = st.groupId }
        Task { [p] in
            do {
                try await cli.call("sendReaction", p)
                showFlash("Reacted with \(emoji).", seconds: 3)
            } catch {
                showFlash("Could not react to the story: \(error.localizedDescription)")
            }
        }
    }

    /// Posts a photo or video story to "My Story" or to a group's story.
    func postStory(file: String, groupKey: String?, allowReplies: Bool) {
        let size = ((try? FileManager.default.attributesOfItem(atPath: file))?[.size] as? NSNumber)?.int64Value ?? 0
        guard size > 0, size <= Media.maxAttachment else {
            showFlash("The file cannot be posted as a story.", seconds: 6)
            return
        }
        let staged = Media.stageForSignalCli([file])
        var p: JSON = ["attachment": staged.paths.first ?? file]
        if !allowReplies { p["noReplies"] = true }
        if let groupKey { p["groupId"] = String(groupKey.dropFirst(2)) }
        showFlash("Posting story …", seconds: 120)
        Task { [p] in
            defer { try? FileManager.default.removeItem(at: staged.dir) }
            do {
                let res = try await cli.call("sendStory", p)
                var ts = jsonInt64(jsonObject(res)["timestamp"])
                if ts <= 0 { ts = nowMs() }
                var st = Story()
                st.ts = ts
                st.authorKey = account
                st.authorName = "You"
                st.outgoing = true
                st.allowsReplies = allowReplies
                st.groupId = groupKey.map { String($0.dropFirst(2)) } ?? ""
                var a = Attachment()
                a.filename = (file as NSString).lastPathComponent
                a.contentType = Media.mimeType(forFile: file)
                // Keep a private copy for viewing our own story (the original may be a temporary file).
                if let data = FileManager.default.contents(atPath: file),
                   let url = try? Media.writeAttachmentTemp(data, name: "story-" + a.filename) {
                    a.path = url.path
                }
                st.attachment = a
                stories.append(st)
                showFlash("Story posted.", seconds: 4)
            } catch {
                showFlash("Could not post the story: \(error.localizedDescription)")
            }
        }
    }

    func chooseStoryFile() -> String? {
        let panel = NSOpenPanel()
        panel.title = "Choose a photo or video for your story"
        panel.allowedContentTypes = [.image, .movie]
        panel.allowsMultipleSelection = false
        return panel.runModal() == .OK ? panel.url?.path : nil
    }
}

struct AVPlayerViewRepresentable: NSViewRepresentable {
    let player: AVPlayer
    func makeNSView(context: Context) -> NSView {
        let v = PlayerHostView()
        v.playerLayer.player = player
        return v
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    final class PlayerHostView: NSView {
        let playerLayer = AVPlayerLayer()
        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
            layer?.addSublayer(playerLayer)
        }

        required init?(coder: NSCoder) { fatalError() }
        override func layout() {
            super.layout()
            playerLayer.frame = bounds
        }
    }
}
