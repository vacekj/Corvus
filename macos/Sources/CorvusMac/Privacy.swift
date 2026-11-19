import AppKit
import CorvusCore
import SwiftUI

/// Read receipts and typing indicators, sent only when switched on in Settings → Privacy and only to chats
/// that may see activity (accepted requests, not blocked: `mayAcknowledge`).
extension AppModel {
    func applyPrivacy(_ p: PrivacySettings) {
        if privacy.typingIndicators && !p.typingIndicators { composerTypingReset() }
        privacy = p
        p.save()
    }

    /// The newest `count` incoming messages of the chat were read.
    func sendReadReceipts(_ key: String, newest count: Int) {
        guard count > 0, let c = chats.convs[key] else { return }
        let msgs = c.msgs.reversed().filter { !$0.outgoing }.prefix(min(count, 100))
        sendReadReceipts(key, Array(msgs))
    }

    /// Reading here is told to the user's other devices (always, like the official clients) and, when
    /// read receipts are on, to the authors.
    func sendReadReceipts(_ key: String, _ msgs: [Message]) {
        guard cli.isRunning, let c = chats.convs[key] else { return }
        var byAuthor: [String: [Int64]] = [:]
        for m in msgs where !m.outgoing && !m.deleted && !m.isNotice && m.ts > 0 {
            let author = chats.resolveKey(chats.effectiveAuthor(c, m))
            guard !author.isEmpty, author != account else { continue }
            byAuthor[author, default: []].append(m.ts)
        }
        if byAuthor.isEmpty { return }
        let synced = byAuthor.flatMap { author, ts in ts.map { ["sender": author, "timestamp": $0] as [String: Any] } }
        Task { try? await cli.call("sendSyncRead", ["messages": synced]) }
        guard privacy.readReceipts, mayAcknowledge(key) else { return }
        for (author, ts) in byAuthor where !isBlocked(author) {
            Task { try? await cli.call("sendReceipt", ["recipient": author, "targetTimestamp": ts, "type": "read"]) }
        }
    }
}

struct PrivacySettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var p = PrivacySettings()
    @State private var loaded = false

    var body: some View {
        Form {
            Section("Messages") {
                Toggle("Send read receipts", isOn: $p.readReceipts)
                Toggle("Send typing indicators", isOn: $p.typingIndicators)
                Text("Never sent for message requests you have not accepted or to blocked people.")
                    .font(TypeScale.caption).foregroundStyle(.secondary)
            }
            AccountPrivacySections()
        }
        .formStyle(.grouped)
        .onAppear {
            if !loaded { p = model.privacy; loaded = true }
        }
        .onChange(of: p) { _, new in model.applyPrivacy(new) }
    }
}

extension AppModel {
    /// Messages read on another device: the chats holding them count only newer incoming messages as unread.
    func handleReadSync(_ items: [ReadSyncItem]) {
        var changed = false
        for it in items {
            let author = chats.resolveKey(it.sender)
            for key in chats.convs.keys where chats.convs[key]!.unread > 0 || chats.convs[key]!.markedUnread {
                let c = chats.convs[key]!
                guard key == author || c.isGroup else { continue }
                // Only the unread tail is searched: older messages are read already.
                var newer = 0, found = false
                for m in c.msgs.reversed() where !m.outgoing && !m.isNotice {
                    if m.ts == it.timestamp && chats.resolveKey(chats.effectiveAuthor(c, m)) == author { found = true; break }
                    if m.ts > it.timestamp { newer += 1 }
                    if newer > c.unread { break }
                }
                guard found else { continue }
                if newer < c.unread { chats.convs[key]!.unread = newer; changed = true }
                if newer == 0 {
                    notifier.close(key)
                    if c.markedUnread { setMarkedUnread(key, false) }
                }
            }
        }
        if changed { listChanged() }
    }
}
