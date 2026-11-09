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

    func sendReadReceipts(_ key: String, _ msgs: [Message]) {
        guard privacy.readReceipts, cli.isRunning, let c = chats.convs[key], mayAcknowledge(key) else { return }
        var byAuthor: [String: [Int64]] = [:]
        for m in msgs where !m.outgoing && !m.deleted && !m.isNotice && m.ts > 0 {
            let author = chats.resolveKey(chats.effectiveAuthor(c, m))
            guard !author.isEmpty, author != account, !isBlocked(author) else { continue }
            byAuthor[author, default: []].append(m.ts)
        }
        for (author, ts) in byAuthor {
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
                    .font(.caption).foregroundStyle(.secondary)
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
