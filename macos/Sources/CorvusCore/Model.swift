import Foundation

public typealias JSON = [String: Any]

/// Lenient number conversions for JSON values (signal-cli sends numbers, older records may hold strings).
public func jsonInt64(_ v: Any?) -> Int64 {
    switch v {
    case let n as NSNumber: return n.int64Value
    case let s as String: return Int64(s) ?? 0
    default: return 0
    }
}

public func jsonInt(_ v: Any?) -> Int { Int(clamping: jsonInt64(v)) }
public func jsonBool(_ v: Any?) -> Bool { (v as? NSNumber)?.boolValue ?? false }
public func jsonString(_ v: Any?) -> String { v as? String ?? "" }
public func jsonObject(_ v: Any?) -> JSON { v as? JSON ?? [:] }
public func jsonArray(_ v: Any?) -> [Any] { v as? [Any] ?? [] }

public func nowMs() -> Int64 { Int64((Date().timeIntervalSince1970 * 1000).rounded()) }

public struct Attachment: Equatable, Hashable {
    public var id = ""          // signal-cli attachment id (for getAttachment)
    public var contentType = ""
    public var filename = ""
    public var path = ""        // local source file (outgoing attachments only)
    public var size: Int64 = 0
    public var width = 0
    public var height = 0
    public var thumb = Data()   // JPEG/PNG preview (<= 480 px), kept in the encrypted history
    // Imported from Signal Desktop: the still encrypted file copied into the Corvus data folder
    // ("imported-attachments/<encPath>") and its Signal Desktop file key (empty = plaintext file).
    public var encPath = ""
    public var localKey = ""

    public init() {}

    private var suffix: String {
        guard let dot = filename.lastIndex(of: ".") else { return filename.lowercased() }
        return String(filename[filename.index(after: dot)...]).lowercased()
    }

    public var isImage: Bool { contentType.hasPrefix("image/") }

    public var isAudio: Bool {
        if contentType.hasPrefix("audio/") { return true }
        return ["aac", "flac", "m4a", "mp3", "oga", "ogg", "opus", "wav", "weba", "webm"].contains(suffix)
    }

    public var isVideo: Bool {
        if contentType.lowercased().hasPrefix("video/") { return true }
        return ["3gp", "avi", "m4v", "mkv", "mov", "mp4", "mpeg", "mpg", "ogv", "webm"].contains(suffix)
    }

    public var isGif: Bool {
        contentType.caseInsensitiveCompare("image/gif") == .orderedSame || filename.lowercased().hasSuffix(".gif")
    }

    /// Stickers are stored like the Qt app does: a pseudo attachment named "signal-sticker:<packId>:<stickerId>.webp".
    public static let stickerPrefix = "signal-sticker:"

    public static func sticker(packId: String, stickerId: Int) -> Attachment {
        var a = Attachment()
        a.contentType = "image/webp"
        a.filename = "\(stickerPrefix)\(packId):\(stickerId).webp"
        return a
    }

    public var isSticker: Bool { filename.hasPrefix(Attachment.stickerPrefix) }

    public var stickerPackId: String {
        guard isSticker else { return "" }
        let rest = filename.dropFirst(Attachment.stickerPrefix.count)
        return rest.split(separator: ":", maxSplits: 1).first.map(String.init) ?? ""
    }

    public var stickerId: Int {
        guard isSticker else { return -1 }
        let parts = filename.dropFirst(Attachment.stickerPrefix.count).split(separator: ":", maxSplits: 1)
        guard parts.count == 2 else { return -1 }
        return Int(parts[1].split(separator: ".").first ?? "") ?? -1
    }
}

/// A Signal poll (sendPollCreate). Votes are keyed by voter (number/UUID); a voter's newer vote
/// (higher voteCount) replaces the older one, like the official clients.
public struct Poll: Equatable, Hashable {
    public var question = ""
    public var options: [String] = []
    public var allowMultiple = true
    public var ended = false
    public var votes: [String: [Int]] = [:]       // voter -> chosen option indexes
    public var voteCounts: [String: Int] = [:]    // voter -> voteCount of the stored vote

    public init() {}

    public var isValid: Bool { !question.isEmpty && options.count >= 2 }

    public func voters(for option: Int) -> [String] {
        votes.filter { $0.value.contains(option) }.map(\.key).sorted()
    }

    public var totalVoters: Int { votes.values.filter { !$0.isEmpty }.count }

    /// Applies a vote; false if it is older than the vote already known.
    @discardableResult
    public mutating func applyVote(voter: String, options chosen: [Int], voteCount: Int) -> Bool {
        if let known = voteCounts[voter], voteCount > 0, known >= voteCount { return false }
        let valid = chosen.filter { $0 >= 0 && $0 < options.count }
        votes[voter] = allowMultiple ? Array(Set(valid)).sorted() : Array(valid.prefix(1))
        voteCounts[voter] = voteCount
        return true
    }
}

public struct Quote: Equatable, Hashable {
    public var valid = false
    public var id: Int64 = 0         // timestamp of the quoted message
    public var authorKey = ""        // number or UUID of the quoted author
    public var text = ""
    public var attachmentNote = ""   // e.g. "image/png"

    public init() {}
}

public struct Message: Equatable, Identifiable {
    public var ts: Int64 = 0          // ms since epoch: Signal message identity and displayed time
    // Local timeline order is separate from Signal's sender timestamp (`ts`). A sender's
    // device clock can be wrong; the message must still appear where it was received.
    // Zero means a legacy history record without an explicit order value.
    public var orderTs: Int64 = 0
    public var sender = ""            // display name at the time of receiving
    public var text = ""
    public var outgoing = false
    public var authorKey = ""         // number/UUID of the author (own number for outgoing)
    public var quote = Quote()
    public var attachments: [Attachment] = []
    public var reactions: [String: String] = [:] // reactor key -> emoji

    // Editing: `ts` stays the timestamp of the original message and remains its protocol
    // identity. An edit arrives as a new timestamp, remembered in editTs; peers refer to
    // the message by that latest timestamp.
    public var editTs: Int64 = 0
    public var editCount = 0
    public var expiresInSeconds = 0
    public var expirationStartMs: Int64 = 0
    public var deleted = false        // deleted for everyone: only a placeholder is left

    // Signal View Once media (same rules as the Qt app): the attachment reference is kept only
    // until the media is opened; sent View Once media is never kept.
    public var viewOnce = false
    public var viewOnceViewed = false
    public var viewOnceExpired = false

    public var poll = Poll()          // valid for poll messages
    public var linkPreview = LinkPreview() // sender-provided preview card (never fetched by us when received)

    // Signal text formatting (see Formatting.swift); offsets are UTF-16 units of `text`.
    public var textStyles: [TextStyleRange] = []
    public var mentions: [MentionRange] = []

    // Outgoing messages: best status over all recipients (0 sent, 1 delivered, 2 read) and the state per recipient.
    public var receiptStatus = 0
    public var recipientReceipts: [String: RecipientReceipt] = [:]
    // Outgoing group messages: the members the message was sent to, captured when the send started
    // (self excluded, aliases resolved). Empty for other messages and for imported history that did
    // not record it; the hover detail then shows only the recipients of known receipts.
    public var sentToKeys: [String] = []
    // Own message signal-cli could not send: it stays in the chat, marked failed, until it is sent again
    // or deleted (like Signal Desktop). Local only.
    public var sendFailed = false
    // Signal pinned message: when it was pinned (0 = not pinned) and when the pin ends (0 = never).
    public var pinnedAtMs: Int64 = 0
    public var pinExpiresMs: Int64 = 0

    public init() {}

    public var id: String { "\(ts)|\(authorKey)|\(outgoing)" }
    public var time: Date { Date(timeIntervalSince1970: TimeInterval(ts) / 1000) }
    public var sortTs: Int64 { orderTs > 0 ? orderTs : ts }
    public var latestTs: Int64 { editTs > 0 ? editTs : ts }
    public var isEdited: Bool { editCount > 0 }

    // Same limits as the official clients: own text messages, 3 hours after sending, 10 edits.
    public static let editWindowMs: Int64 = 3 * 60 * 60 * 1000
    public static let maxEdits = 10

    /// Turns the message into the "This message was deleted." placeholder, dropping all content.
    public mutating func markDeleted() {
        deleted = true
        text = ""
        textStyles = []
        mentions = []
        attachments = []
        quote = Quote()
        reactions = [:]
        editTs = 0
        editCount = 0
        viewOnce = false
        viewOnceViewed = false
        viewOnceExpired = false
        poll = Poll()
        linkPreview = LinkPreview()
        pinnedAtMs = 0
        pinExpiresMs = 0
    }

    /// View Once media that has been opened (or was sent by us): only a placeholder remains.
    public var viewOnceConsumed: Bool { viewOnce && (outgoing || viewOnceViewed || viewOnceExpired) }

    public var isPoll: Bool { poll.isValid }

    public func canEdit(nowMs: Int64) -> Bool {
        outgoing && !deleted && !sendFailed && !isPoll && !text.isEmpty && editCount < Message.maxEdits && nowMs - ts <= Message.editWindowMs
    }
}

public struct Conversation: Identifiable {
    public var key = ""               // number/UUID or "g:<groupId>"
    public var title = ""
    public var isGroup = false
    public var msgs: [Message] = []
    public var unread = 0
    public var storedName = ""        // display name learnt from an incoming message (persisted)
    public var localNickname = ""     // local-only contact nickname (persisted)
    public var archived = false       // shown in the "Archived chats" folder
    public var sigArchived = false    // archive state last reported by signal-cli
    public var muted = false          // local "mute notifications"
    public var muteUntilMs: Int64 = 0 // end of a timed mute (ms since 1970); 0 = until unmuted
    public var folders: Set<String> = [] // chat folders this chat was picked for (local, persisted)
    public var wallpaper = ""         // chat wallpaper id; empty = the global one (local, persisted)
    public var pinned = false         // kept at the top of the chat list (local, persisted)
    public var markedUnread = false   // "Mark as unread" (local, persisted); cleared when the chat is opened
    public var expirationSeconds = 0  // Signal disappearing-message timer; 0 = disabled
    public var pins: [MessagePin] = []  // pinned messages (cache of the messages' pin state), oldest first

    public init(key: String = "", title: String = "", isGroup: Bool = false) {
        self.key = key
        self.title = title
        self.isGroup = isGroup
    }

    public var id: String { key }
    public var lastTs: Int64 { msgs.last?.sortTs ?? 0 }

    /// Inserts `m` keeping the list sorted by local timeline order. Returns the index.
    @discardableResult
    public mutating func insertSorted(_ m: Message) -> Int {
        var at = msgs.count
        while at > 0 && msgs[at - 1].sortTs > m.sortTs { at -= 1 }
        msgs.insert(m, at: at)
        return at
    }
}
