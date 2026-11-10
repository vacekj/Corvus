import AppKit
import CorvusCore

/// Sending a text message to any chat without going through the main window's composer: replies from a
/// notification and the composer of a chat opened in its own window. Text (with **markdown** styles and
/// @mentions in groups) and an optional quote; attachments and link previews stay with the main composer.
extension AppModel {
    /// Why a text cannot be sent to this chat now, or nil.
    func quickSendProblem(_ key: String) -> String? {
        guard chats.convs[key] != nil else { return "This chat no longer exists." }
        if !connected { return "Not connected to Signal." }
        if isSendLocked(key) { return "Accept the message request first." }
        return nil
    }

    /// Shows the message right away (dimmed until signal-cli confirms it) and sends it. `failed` gets the
    /// error text if the send does not go through; the preview is removed again then.
    func sendQuickText(_ raw: String, to key: String, quote: Quote = Quote(), failed: ((String) -> Void)? = nil) {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        if let problem = quickSendProblem(key) {
            failed?(problem)
            return
        }
        guard let c = chats.convs[key] else { return }

        var p: JSON = [:]
        let formatted = parseMarkdownStyles(text)
        p["message"] = formatted.text
        if !formatted.styles.isEmpty { p["textStyle"] = formatted.styles.map(\.cliString) }
        let mentions = c.isGroup ? resolveMentions(text: formatted.text, candidates: mentionCandidates(key)) : []
        if !mentions.isEmpty { p["mention"] = mentions.map { "\($0.start):\($0.length):\($0.uuid)" } }
        if quote.valid && !quote.authorKey.isEmpty {
            p["quoteTimestamp"] = quote.id
            p["quoteAuthor"] = quote.authorKey
            p["quoteMessage"] = quote.text
        }
        addRecipient(&p, c)

        var preview = Message()
        preview.ts = nowMs()
        while chats.findMessage(chats.convs[key]!, ts: preview.ts, authors: []) != nil { preview.ts += 1 }
        preview.orderTs = max(preview.ts, (chats.convs[key]!.msgs.last?.sortTs ?? 0) + 1)
        preview.text = formatted.text
        preview.textStyles = formatted.styles
        preview.mentions = mentions
        preview.outgoing = true
        preview.authorKey = account
        if c.isGroup { preview.sentToKeys = groupRecipientKeys(key) }
        preview.expiresInSeconds = c.expirationSeconds
        preview.quote = quote

        let pendingId = UUID().uuidString
        var pending = PendingSend()
        pending.conversationKey = key
        pending.temporaryTimestamp = preview.ts
        pending.message = preview
        chats.pendingSends[pendingId] = pending
        chats.convs[key]!.insertSorted(preview)
        listChanged()

        Task { [p] in
            var result: Any?
            var err: String?
            do { result = try await cli.call("send", p) } catch { err = error.localizedDescription }
            guard let pendingNow = chats.pendingSends[pendingId] else { return }
            if let err, !pendingNow.echoReceived {
                chats.removePendingPreview(pendingNow)
                chats.pendingSends.removeValue(forKey: pendingId)
                listChanged()
                failed?(err)
                return
            }
            if pendingNow.echoReceived {
                chats.pendingSends.removeValue(forKey: pendingId)
            } else {
                var ts = jsonInt64(jsonObject(result)["timestamp"])
                if ts <= 0 { ts = nowMs() }
                persist(chats.finalizePendingSend(pendingId, timestamp: ts))
                listChanged()
            }
        }
    }

    /// Marks a chat read the way opening it does (read receipts, disappearing-message timers) without opening it.
    func markReadWithoutOpening(_ key: String) {
        guard chats.convs[key] != nil else { return }
        if chats.hasIncomingExpirationToStart(key) { persist(chats.startIncomingExpirationTimers(key, now: nowMs())) }
        markChatRead(key)
        notifier.close(key)
    }

    /// "Reply" in a message notification.
    func replyFromNotification(_ key: String, _ text: String) {
        guard chats.convs[key] != nil, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        markReadWithoutOpening(key) // replying means the messages were read
        sendQuickText(text, to: key) { [weak self] error in
            guard let self, let c = self.chats.convs[key] else { return }
            // The user is not looking at Corvus: say so where they replied.
            let hidden = self.notify.content == .hidden
            self.notifier.notify(key: key, title: hidden ? "Corvus" : self.title(c), body: "Your reply was not sent: \(error)",
                                 icon: nil)
        }
    }
}
