import Foundation

// A direct chat is kept under the contact's number. When a message arrives before the backend knows the
// sender's number (a new contact, the phone's contact sync not done yet), it can only be filed under the
// sender's UUID, and a second chat with the same person appears. Once the number is known (`alias`), that
// chat is moved into the one under the number.

extension ChatState {
    /// Whether a direct chat is still filed under a UUID whose number is known (`mergeAliasedChats`).
    public func hasAliasedChats() -> Bool {
        alias.contains { uuid, number in
            !number.isEmpty && uuid != number && convs[uuid].map { !$0.isGroup } == true
        }
    }

    /// Moves every direct chat under a UUID whose number is known now into the chat under the number.
    /// Returns the moved chats as (UUID key, number key).
    public mutating func mergeAliasedChats() -> [(from: String, to: String)] {
        var merged: [(from: String, to: String)] = []
        for (uuid, number) in alias.sorted(by: { $0.key < $1.key })
        where !number.isEmpty && uuid != number && !number.hasPrefix("g:") {
            guard let from = convs[uuid], !from.isGroup, convs[number]?.isGroup != true else { continue }
            mergeChat(from, into: number)
            merged.append((uuid, number))
        }
        if !merged.isEmpty { rebuildPins() }
        return merged
    }

    mutating func mergeChat(_ from: Conversation, into key: String) {
        convs.removeValue(forKey: from.key)
        for (id, p) in pendingSends where p.conversationKey == from.key { pendingSends[id]!.conversationKey = key }
        let moved = from.msgs.map { Self.rekeyed($0, from.key, key) }
        guard var to = convs[key] else {
            var c = from
            c.key = key
            c.msgs = moved
            if c.title == from.key { c.title = contactNames[key] ?? key }
            convs[key] = c
            return
        }
        convs.removeValue(forKey: key) // one owner of the messages while they are inserted
        for m in moved where findMessage(to, ts: m.ts, authors: [effectiveAuthor(to, m)]) == nil {
            to.insertSorted(m)
        }
        to.unread += from.unread
        if to.storedName.isEmpty { to.storedName = from.storedName }
        if to.localNickname.isEmpty && !from.localNickname.isEmpty {
            to.localNickname = from.localNickname
            to.title = from.localNickname
        }
        to.archived = to.archived && from.archived // listed if either chat was
        if !to.muted && from.muted {
            to.muted = true
            to.muteUntilMs = from.muteUntilMs
        }
        to.folders.formUnion(from.folders)
        if to.wallpaper.isEmpty { to.wallpaper = from.wallpaper }
        to.pinned = to.pinned || from.pinned
        to.markedUnread = to.markedUnread || from.markedUnread
        convs[key] = to
    }

    /// The message with the UUID replaced by the number where it names the contact.
    static func rekeyed(_ m: Message, _ from: String, _ to: String) -> Message {
        var m = m
        if m.authorKey == from { m.authorKey = to }
        if let e = m.reactions.removeValue(forKey: from), m.reactions[to] == nil { m.reactions[to] = e }
        if m.quote.valid && m.quote.authorKey == from { m.quote.authorKey = to }
        return m
    }
}

extension AgentAccessSettings {
    /// Chat grants follow a chat that was moved to another key.
    public mutating func rekeyChat(_ from: String, to: String) {
        for i in grants.indices where grants[i].chats.contains(from) {
            grants[i].chats = grants[i].chats.map { $0 == from ? to : $0 }.reduce(into: [String]()) {
                if !$0.contains($1) { $0.append($1) }
            }
        }
    }
}
