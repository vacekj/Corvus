import AppKit
import CorvusCore

// Chat state shared with the phone and other devices: archive, pins and "mark as unread" go through
// the Storage Service, "delete for me" through sync messages. Mutes: MuteDurations.swift.

/// Phone-side flags as last seen, so a change made here before it reached the phone is not undone
/// by an older listing, and chats never flagged there keep their local state.
@MainActor
enum PhoneFlags {
    private static let defaultsKey = "phoneFlags"
    static var seen: [String: Bool] = (UserDefaults.standard.dictionary(forKey: defaultsKey) as? [String: Bool]) ?? [:] {
        didSet { UserDefaults.standard.set(seen, forKey: defaultsKey) }
    }
    /// Muted groups whose @mentions stay quiet too (the phone's "Mentions: don't notify").
    static var quietMentions: Set<String> = []
}

extension AppModel {
    /// `recipient` or `groupId` of a chat for the backend.
    func chatParams(_ key: String) -> JSON {
        key.hasPrefix("g:") ? ["groupId": String(key.dropFirst(2))] : ["recipient": key]
    }

    /// Writes archive / pin / unread state to the Storage Service. Pinning past Signal's limit of
    /// four keeps the pin here only.
    func pushChatState(_ key: String, _ state: JSON) {
        guard cli.isRunning, !key.isEmpty else { return }
        var p = chatParams(key)
        p.merge(state) { _, new in new }
        Task {
            do {
                _ = try await cli.call("setChatState", p)
            } catch {
                if state["pinned"] as? Bool == true {
                    showFlash("Pinned here only: Signal keeps at most 4 pinned chats on your phone.", seconds: 6)
                }
            }
        }
    }

    /// A pin or "marked unread" flag from the phone: followed only when it changed there.
    func applyPhoneFlag(_ kind: String, _ key: String, _ value: Bool) {
        let id = kind + "|" + key
        let previous = PhoneFlags.seen[id]
        guard previous != value, chats.convs[key] != nil else { return }
        PhoneFlags.seen[id] = value
        if previous == nil && !value { return } // never set there: keep the local state
        switch kind {
        case "pin": setPinned(key, value, push: false)
        default: setMarkedUnread(key, value, push: false)
        }
    }

    /// The user is @mentioned in the message.
    func mentionsMe(_ m: Message) -> Bool {
        m.mentions.contains { !$0.uuid.isEmpty && ($0.uuid == account || chats.resolveKey($0.uuid) == account) }
    }

    /// No alert for the message: the chat is muted, except for @mentions in groups that let them
    /// through (Signal's default).
    func mutedFor(_ key: String, _ m: Message) -> Bool {
        guard let c = chats.convs[key], c.isMuted(at: nowMs()) else { return false }
        if c.isGroup && !PhoneFlags.quietMentions.contains(key) && mentionsMe(m) { return false }
        return true
    }

    // MARK: - Delete for me

    /// Tells the other devices that messages (or, with `wholeChat`, the chat) were deleted here.
    func syncDeleteForMe(_ key: String, _ msgs: [Message], wholeChat: Bool = false) {
        guard cli.isRunning else { return }
        var p = chatParams(key)
        p["messages"] = msgs.filter { $0.notice.kind == .none && $0.ts > 0 }.map { m -> JSON in
            ["author": m.outgoing || m.authorKey.isEmpty ? account : m.authorKey, "timestamp": m.ts]
        }
        if wholeChat { p["wholeChat"] = true }
        Task { try? await cli.call("sendDeleteForMe", p) }
    }

    /// Messages or chats deleted "for me" on another device.
    func handleDeleteForMe(_ env: JSON) {
        let d = jsonObject(jsonObject(env["syncMessage"])["deleteForMe"])
        if d.isEmpty { return }
        for x in jsonArray(d["messageDeletes"]) {
            let o = jsonObject(x)
            guard let key = deleteForMeKey(o["conversation"]), let c = chats.convs[key] else { continue }
            var msgs: [Message] = []
            for mv in jsonArray(o["messages"]) {
                let mo = jsonObject(mv)
                let author = chats.resolveKey(jsonString(mo["author"]))
                let ts = jsonInt64(mo["timestamp"])
                if let i = chats.findMessage(c, ts: ts, authors: author == account ? [] : [author]) { msgs.append(c.msgs[i]) }
            }
            if !msgs.isEmpty { removeMessages(key, msgs, sync: false) }
        }
        for x in jsonArray(d["conversationDeletes"]) {
            let o = jsonObject(x)
            guard let key = deleteForMeKey(o["conversation"]), let c = chats.convs[key] else { continue }
            let newest = jsonArray(o["mostRecentMessages"]).map { jsonInt64(jsonObject($0)["timestamp"]) }.max() ?? 0
            let doomed = newest > 0 ? c.msgs.filter { $0.ts <= newest } : c.msgs
            if doomed.count == c.msgs.count {
                removeConversation(key)
            } else {
                removeMessages(key, doomed, sync: false)
            }
        }
        listChanged()
    }

    private func deleteForMeKey(_ v: Any?) -> String? {
        let o = jsonObject(v)
        let group = jsonString(o["groupId"])
        if !group.isEmpty { return "g:" + group }
        let r = jsonString(o["recipient"])
        return r.isEmpty ? nil : chats.resolveKey(r)
    }
}
