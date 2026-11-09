import Foundation

// Rules behind the message actions: pinned messages, failed sends and their retry, and what a
// selection of several messages allows (like Signal Desktop).

/// A pinned message of a chat (cached in `Conversation.pins`; the pin itself is stored on the message).
public struct MessagePin: Equatable, Hashable {
    public var ts: Int64            // original timestamp of the pinned message
    public var authorKey: String
    public var pinnedAtMs: Int64
    public var expiresMs: Int64     // 0 = pinned until unpinned
    /// Timeline position of the message, to find it without scanning the whole chat (not compared).
    public var sortTs: Int64 = 0

    public init(ts: Int64, authorKey: String, pinnedAtMs: Int64, expiresMs: Int64, sortTs: Int64 = 0) {
        self.ts = ts
        self.authorKey = authorKey
        self.pinnedAtMs = pinnedAtMs
        self.expiresMs = expiresMs
        self.sortTs = sortTs
    }

    public static func == (a: MessagePin, b: MessagePin) -> Bool {
        a.ts == b.ts && a.authorKey == b.authorKey && a.pinnedAtMs == b.pinnedAtMs && a.expiresMs == b.expiresMs
    }

    public func hash(into h: inout Hasher) {
        h.combine(ts)
        h.combine(authorKey)
        h.combine(pinnedAtMs)
    }

    public func isActive(now: Int64) -> Bool { expiresMs <= 0 || now < expiresMs }
}

public enum PinRules {
    /// Signal keeps at most three pinned messages per chat; a new pin replaces the oldest.
    public static let maxPins = 3

    /// When a pin made at `pinnedAt` for `durationSeconds` ends; 0 = never (signal-cli sends -1 for forever).
    public static func expiry(pinnedAt: Int64, durationSeconds: Int) -> Int64 {
        durationSeconds > 0 ? pinnedAt + Int64(durationSeconds) * 1000 : 0
    }
}

public enum MessageSelectionRules {
    /// "Delete for everyone" is offered for a day, like the official clients.
    public static let deleteForEveryoneWindowMs: Int64 = 24 * 60 * 60 * 1000

    public static func canDeleteForEveryone(_ m: Message, now: Int64) -> Bool {
        let age = now - m.ts
        return m.outgoing && !m.deleted && !m.sendFailed && age >= 0 && age <= deleteForEveryoneWindowMs
    }

    /// All selected messages must qualify, as for a single message.
    public static func canDeleteForEveryone(_ msgs: [Message], now: Int64) -> Bool {
        !msgs.isEmpty && msgs.allSatisfy { canDeleteForEveryone($0, now: now) }
    }

    public static func canForward(_ m: Message) -> Bool {
        !m.deleted && !m.sendFailed && !m.viewOnce && !m.isPoll && !(m.text.isEmpty && m.attachments.isEmpty)
    }

    public static func canForward(_ msgs: [Message]) -> Bool { !msgs.isEmpty && msgs.allSatisfy(canForward) }

    /// Pins, reactions and replies need a message the others have received.
    public static func canInteract(_ m: Message) -> Bool { !m.deleted && !m.sendFailed }
}

public enum RetrySend {
    /// signal-cli `send` parameters that send `m` again: text, styles, mentions, quote, sticker and View Once.
    /// Attachments, the link preview and the recipient are added by the caller (they need staged files).
    public static func params(_ m: Message) -> JSON {
        var p: JSON = [:]
        if !m.text.isEmpty { p["message"] = m.text }
        if !m.text.isEmpty && !m.textStyles.isEmpty { p["textStyle"] = m.textStyles.map(\.cliString) }
        let mentions = m.mentions.filter { !$0.uuid.isEmpty }
        if !mentions.isEmpty { p["mention"] = mentions.map { "\($0.start):\($0.length):\($0.uuid)" } }
        if let s = m.attachments.first(where: \.isSticker) { p["sticker"] = "\(s.stickerPackId):\(s.stickerId)" }
        if m.viewOnce { p["viewOnce"] = true }
        if m.quote.valid && !m.quote.authorKey.isEmpty {
            p["quoteTimestamp"] = m.quote.id
            p["quoteAuthor"] = m.quote.authorKey
            p["quoteMessage"] = m.quote.text
        }
        return p
    }

    /// Local files of the attachments to send again (not stickers).
    public static func attachmentPaths(_ m: Message) -> [String] {
        m.attachments.filter { !$0.isSticker && !$0.path.isEmpty }.map(\.path)
    }
}

extension ChatState {
    // MARK: - Pinned messages

    /// Pins a message (ours or a peer's). At most `PinRules.maxPins` stay pinned: the oldest are unpinned.
    /// Returns the records to persist; empty when nothing changed (redelivery, older pin, unknown message).
    public mutating func applyPin(_ key: String, targetTs: Int64, authors: [String], atMs: Int64, durationSeconds: Int) -> [JSON] {
        guard let c = convs[key], let i = findMessage(c, ts: targetTs, authors: authors), !c.msgs[i].deleted,
              !c.msgs[i].sendFailed, atMs > c.msgs[i].pinnedAtMs else { return [] }
        convs[key]!.msgs[i].pinnedAtMs = atMs
        convs[key]!.msgs[i].pinExpiresMs = PinRules.expiry(pinnedAt: atMs, durationSeconds: durationSeconds)
        let m = convs[key]!.msgs[i]
        var recs = [Records.pinUpdate(key, m)]
        let author = effectiveAuthor(c, m)
        var pins = convs[key]!.pins.filter { !($0.ts == m.ts && $0.authorKey == author) && $0.isActive(now: atMs) }
        pins.append(MessagePin(ts: m.ts, authorKey: author, pinnedAtMs: m.pinnedAtMs, expiresMs: m.pinExpiresMs, sortTs: m.sortTs))
        pins.sort { $0.pinnedAtMs < $1.pinnedAtMs }
        while pins.count > PinRules.maxPins {
            let old = pins.removeFirst()
            if let j = findMessage(convs[key]!, ts: old.ts, authors: [old.authorKey]) {
                convs[key]!.msgs[j].pinnedAtMs = 0
                convs[key]!.msgs[j].pinExpiresMs = 0
                recs.append(Records.pinUpdate(key, convs[key]!.msgs[j]))
            }
        }
        convs[key]!.pins = pins
        return recs
    }

    /// Unpins a message. Returns the record to persist, nil if it was not pinned.
    public mutating func applyUnpin(_ key: String, targetTs: Int64, authors: [String]) -> JSON? {
        guard let c = convs[key], let i = findMessage(c, ts: targetTs, authors: authors), c.msgs[i].pinnedAtMs > 0 else { return nil }
        let m = c.msgs[i], author = effectiveAuthor(c, m)
        convs[key]!.msgs[i].pinnedAtMs = 0
        convs[key]!.msgs[i].pinExpiresMs = 0
        convs[key]!.pins.removeAll { $0.ts == m.ts && $0.authorKey == author }
        return Records.pinUpdate(key, convs[key]!.msgs[i])
    }

    /// Pinned messages still shown, newest pin first (with the message; pins of removed messages are skipped).
    public func activePins(_ key: String, now: Int64) -> [(pin: MessagePin, message: Message)] {
        guard let c = convs[key], !c.pins.isEmpty else { return [] }
        return c.pins.reversed().compactMap { p in
            guard p.isActive(now: now), let i = pinnedIndex(c, p), !c.msgs[i].deleted else { return nil }
            return (p, c.msgs[i])
        }
    }

    /// The pinned message: by binary search on its timeline position (the list is sorted by it), else by a scan.
    func pinnedIndex(_ c: Conversation, _ p: MessagePin) -> Int? {
        if p.sortTs > 0 {
            var lo = 0, hi = c.msgs.count
            while lo < hi {
                let mid = (lo + hi) / 2
                if c.msgs[mid].sortTs < p.sortTs { lo = mid + 1 } else { hi = mid }
            }
            var i = lo
            while i < c.msgs.count && c.msgs[i].sortTs == p.sortTs {
                if c.msgs[i].ts == p.ts && effectiveAuthor(c, c.msgs[i]) == p.authorKey { return i }
                i += 1
            }
        }
        return findMessage(c, ts: p.ts, authors: [p.authorKey])
    }

    /// The pins of a chat before a change that may have to be taken back (`restorePins`).
    public func pinSnapshot(_ key: String) -> [MessagePin] { convs[key]?.pins ?? [] }

    /// Puts the pins of a chat back to a snapshot (a pin or unpin signal-cli could not send).
    public mutating func restorePins(_ key: String, _ snapshot: [MessagePin]) {
        guard let c = convs[key] else { return }
        for p in c.pins + snapshot {
            guard let i = findMessage(convs[key]!, ts: p.ts, authors: [p.authorKey]) else { continue }
            let s = snapshot.first { $0.ts == p.ts && $0.authorKey == p.authorKey }
            if convs[key]!.msgs[i].pinnedAtMs != (s?.pinnedAtMs ?? 0) { convs[key]!.msgs[i].pinnedAtMs = s?.pinnedAtMs ?? 0 }
            if convs[key]!.msgs[i].pinExpiresMs != (s?.expiresMs ?? 0) { convs[key]!.msgs[i].pinExpiresMs = s?.expiresMs ?? 0 }
        }
        if convs[key]!.pins != snapshot { convs[key]!.pins = snapshot }
    }

    /// Rebuilds the pin cache of every chat from its messages (after loading the history).
    public mutating func rebuildPins() {
        for key in convs.keys {
            let c = convs[key]!
            var pins: [MessagePin] = []
            for m in c.msgs where m.pinnedAtMs > 0 && !m.deleted {
                pins.append(MessagePin(ts: m.ts, authorKey: effectiveAuthor(c, m), pinnedAtMs: m.pinnedAtMs, expiresMs: m.pinExpiresMs,
                                       sortTs: m.sortTs))
            }
            pins.sort { $0.pinnedAtMs < $1.pinnedAtMs }
            if pins != c.pins { convs[key]!.pins = pins }
        }
    }

    // MARK: - Failed sends

    /// signal-cli could not send a pending message: it stays in the chat, marked failed, and is no longer pending.
    /// Returns the record that keeps it in the history (nil when the preview is gone).
    public mutating func failPendingSend(_ id: String) -> JSON? {
        guard let p = pendingSends.removeValue(forKey: id) else { return nil }
        let key = p.conversationKey
        guard let c = convs[key], let i = c.msgs.firstIndex(where: {
            $0.ts == p.temporaryTimestamp && $0.outgoing && $0.authorKey == account
        }) else { return nil }
        convs[key]!.msgs[i].sendFailed = true
        return Records.message(key, convs[key]!.msgs[i])
    }

    /// A failed message is sent again: it becomes a pending send (same bubble). Returns the pending id.
    public mutating func beginRetry(_ key: String, ts: Int64, id: String = UUID().uuidString) -> String? {
        guard let c = convs[key], let i = c.msgs.firstIndex(where: { $0.ts == ts && $0.outgoing && $0.sendFailed }) else { return nil }
        convs[key]!.msgs[i].sendFailed = false
        var p = PendingSend()
        p.conversationKey = key
        p.temporaryTimestamp = ts
        p.message = convs[key]!.msgs[i]
        pendingSends[id] = p
        return id
    }
}
