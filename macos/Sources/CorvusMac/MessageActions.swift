import AppKit
import CorvusCore
import Foundation

/// Message actions beyond send/edit/delete: pinned messages, retrying failed sends and actions on a
/// selection of several messages.
extension AppModel {
    // MARK: - Pinned messages

    /// Pin durations offered in the message menu (signal-cli `--pin-duration`, -1 = forever).
    static let pinDurations: [(label: String, seconds: Int)] = [
        ("For 24 hours", 24 * 60 * 60), ("For 7 days", 7 * 24 * 60 * 60), ("For 30 days", 30 * 24 * 60 * 60), ("Forever", -1),
    ]

    /// Pins a message for everyone in the chat. Shown at once; taken back if signal-cli fails.
    func pinMessage(_ id: String, seconds: Int) {
        guard connected, let c = currentConversation, let (_, m) = message(withId: id), MessageSelectionRules.canInteract(m),
              !chats.isPendingPreview(c.key, ts: m.ts) else { return }
        let key = c.key, ts = m.ts, author = chats.effectiveAuthor(c, m)
        var p: JSON = ["targetAuthor": author, "targetTimestamp": m.latestTs, "pinDuration": seconds]
        addRecipient(&p, c)
        let before = chats.pinSnapshot(key)
        let recs = chats.applyPin(key, targetTs: ts, authors: [author], atMs: nowMs(), durationSeconds: seconds)
        Task { [p] in
            do {
                try await cli.call("sendPinMessage", p)
                persist(recs)
            } catch {
                chats.restorePins(key, before)
                showFlash("Could not pin the message: \(error.localizedDescription)", seconds: 8)
            }
        }
    }

    func unpinMessage(_ key: String, ts: Int64, author: String) {
        guard connected, let c = chats.convs[key], let i = chats.findMessage(c, ts: ts, authors: [author]) else { return }
        let m = c.msgs[i]
        var p: JSON = ["targetAuthor": author, "targetTimestamp": m.latestTs]
        addRecipient(&p, c)
        let before = chats.pinSnapshot(key)
        guard let rec = chats.applyUnpin(key, targetTs: ts, authors: [author]) else { return }
        Task { [p] in
            do {
                try await cli.call("sendUnpinMessage", p)
                persist(rec)
            } catch {
                chats.restorePins(key, before)
                showFlash("Could not unpin the message: \(error.localizedDescription)", seconds: 8)
            }
        }
    }

    /// A pin or unpin from a peer or from one of our other devices.
    func handlePinEnvelope(_ pe: ParsedEnvelope, key: String) {
        let authors = [pe.targetNumber, pe.targetUuid].filter { !$0.isEmpty }
        if pe.kind == .pin {
            let recs = chats.applyPin(key, targetTs: pe.targetTs, authors: authors, atMs: pe.msg.ts, durationSeconds: pe.pinDurationSeconds)
            if !recs.isEmpty { persist(recs) }
        } else if let rec = chats.applyUnpin(key, targetTs: pe.targetTs, authors: authors) {
            persist(rec)
        }
    }

    // MARK: - Failed sends

    /// Sends a failed message again with the same content (text, styles, mentions, quote, attachments,
    /// sticker, link preview). The bubble stays where it is and is shown as sending meanwhile.
    func retrySend(_ id: String) {
        guard let c = currentConversation, let (_, m) = message(withId: id), m.sendFailed else { return }
        guard connected else {
            showFlash("Not connected to Signal.", seconds: 5)
            return
        }
        guard !isSendLocked(c.key) else { return }
        let files = RetrySend.attachmentPaths(m)
        if files.contains(where: { !FileManager.default.fileExists(atPath: $0) }) {
            showFlash("The attachment is no longer available. Delete the message and attach the file again.", seconds: 8)
            return
        }
        var p = RetrySend.params(m)
        let staged = Media.stageForBackend(files)
        if !files.isEmpty { p["attachments"] = staged.paths }
        if m.linkPreview.isValid && !m.viewOnce {
            let image = m.linkPreview.imageThumb.isEmpty ? nil : (try? Media.writeTemp(m.linkPreview.imageThumb, name: "preview.jpg"))?.path
            p.merge(LinkPreviews.sendParams(m.linkPreview, imagePath: image)) { $1 }
        }
        addRecipient(&p, c)
        let key = c.key
        guard let pendingId = chats.beginRetry(key, ts: m.ts) else { return }
        listChanged()
        Task { [p] in
            var result: Any?
            var err: String?
            do { result = try await cli.call("send", p) } catch { err = error.localizedDescription }
            try? FileManager.default.removeItem(at: staged.dir)
            guard let pendingNow = chats.pendingSends[pendingId] else { return }
            if let err, !pendingNow.echoReceived {
                _ = chats.failPendingSend(pendingId)
                rewriteHistoryAfterRetry() // the failed record may have been dropped by a rewrite meanwhile
                listChanged()
                showFlash("Sending failed: \(err)", seconds: 8)
                return
            }
            if pendingNow.echoReceived {
                chats.pendingSends.removeValue(forKey: pendingId)
            } else {
                var ts = jsonInt64(jsonObject(result)["timestamp"])
                if ts <= 0 { ts = nowMs() }
                _ = chats.finalizePendingSend(pendingId, timestamp: ts)
            }
            // The history still holds the failed record under the old timestamp: rewrite it.
            rewriteHistoryAfterRetry()
            listChanged()
        }
    }

    private func rewriteHistoryAfterRetry() {
        writer.rewrite(chats) { [weak self] error in
            guard let error, let self else { return }
            showFlash("Could not update the history: \(error.localizedDescription)")
        }
    }

    // MARK: - Several messages

    /// The selected messages of the open chat, oldest first (ids that no longer exist are skipped).
    func messages(withIds ids: Set<String>) -> [Message] {
        guard let c = currentConversation, !ids.isEmpty else { return [] }
        var out: [Message] = []
        // Selections are usually recent: search from the end and stop once all are found.
        for m in c.msgs.reversed() where ids.contains(m.id) {
            out.append(m)
            if out.count == ids.count { break }
        }
        return out.reversed()
    }

    /// Deletes the selected messages from this device or for everyone. True when they were deleted
    /// (the selection ends then).
    func deleteSelected(_ ids: Set<String>, forEveryone: Bool) async -> Bool {
        guard let c = currentConversation else { return false }
        let msgs = messages(withIds: ids)
        guard !msgs.isEmpty else { return true }
        if msgs.contains(where: { chats.isPendingPreview(c.key, ts: $0.ts) }) {
            showFlash("Wait until the messages have finished sending before deleting them.", seconds: 6)
            return false
        }
        if forEveryone && !MessageSelectionRules.canDeleteForEveryone(msgs, now: nowMs()) { return false }
        let n = msgs.count
        let what = n == 1 ? "this message" : "these \(n) messages"
        let r = await Dialogs.ask(n == 1 ? "Delete message" : "Delete \(n) messages",
                                  forEveryone ? "Delete \(what) for everyone?" : "Delete \(what) from this device?",
                                  buttons: [forEveryone ? "Delete for everyone" : "Delete for me"],
                                  style: .warning, cancel: true, destructive: [0])
        guard r == 0 else { return false }
        let key = c.key
        if !forEveryone {
            removeMessages(key, msgs)
            return true
        }
        var failed = 0, deleted = 0
        for m in msgs {
            var p: JSON = ["targetTimestamp": m.ts]
            if c.isGroup { p["groupIds"] = [String(key.dropFirst(2))] } else { p["recipients"] = [chats.resolveKey(key)] }
            do {
                try await cli.call("remoteDelete", p)
                if applyDelete(key, ts: m.ts, authors: []) { deleted += 1 }
            } catch {
                failed += 1
            }
        }
        if failed > 0 {
            showFlash("Could not delete \(failed) of \(n) messages for everyone.")
        } else if deleted > 0 {
            showFlash(deleted == 1 ? "Message deleted for everyone." : "\(deleted) messages deleted for everyone.", seconds: 5)
        }
        return true
    }

    /// Delete for me: all at once, with one rewrite of the history.
    private func removeMessages(_ key: String, _ msgs: [Message]) {
        guard chats.convs[key] != nil else { return }
        let ids = Set(msgs.map(\.id))
        let removed = chats.convs[key]!.msgs.filter { ids.contains($0.id) }
        guard !removed.isEmpty else { return }
        if editKey == key && removed.contains(where: { $0.ts == editTs }) { cancelEdit() }
        chats.convs[key]!.msgs.removeAll { ids.contains($0.id) }
        if removed.contains(where: { $0.pinnedAtMs > 0 }) { chats.rebuildPins() }
        writer.rewrite(chats) { [weak self] error in
            guard let error, let self else { return }
            // The file still holds the messages: show them again.
            if chats.convs[key] != nil {
                for m in removed where !chats.convs[key]!.msgs.contains(where: { $0.id == m.id }) {
                    _ = chats.convs[key]!.insertSorted(m)
                }
                updateSearch()
            }
            showFlash("Could not remove the messages from history: \(error.localizedDescription)")
        }
        updateSearch()
        listChanged()
    }
}
