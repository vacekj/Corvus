import Foundation

/// A signal-cli "receive" envelope reduced to what the GUI needs.
public struct ParsedEnvelope {
    public enum Kind { case none, message, reaction, edit, remoteDelete, expirationUpdate, pollVote, pollTerminate, story }

    public var kind: Kind = .none
    public var outgoing = false        // sent by one of our own other devices (sync message)
    public var src = ""                // sender number / UUID (incoming)
    public var srcName = ""            // sender's profile name
    public var destination = ""        // recipient number / UUID (outgoing 1:1)
    public var groupId = ""            // set for group messages
    public var expirationSeconds = 0
    public var msg = Message()         // message: ts, text, attachments, quote (author keys unresolved)

    // Reaction
    public var emoji = ""
    public var remove = false
    public var targetNumber = ""
    public var targetUuid = ""
    public var targetTs: Int64 = 0     // reaction: reacted message; edit/remoteDelete: timestamp of the target message

    // @mentions in msg.text (message, edit)
    public var mentions: [Mention] = []

    // Poll vote: target poll = targetNumber/targetUuid + targetTs
    public var pollOptions: [Int] = []
    public var voteCount = 0

    // Story (kind == .story) and story replies / story reactions (storyContext)
    public var story = Story()
    public var isStoryReaction = false

    public init() {}
}

/// A Signal story. Stories are kept in memory only (they disappear after 24 hours anyway).
public struct Story: Equatable, Identifiable {
    public var ts: Int64 = 0
    public var authorKey = ""         // number/UUID (own number for our stories)
    public var authorName = ""
    public var groupId = ""           // posted to a group story; empty = "My Story"
    public var outgoing = false
    public var allowsReplies = true
    public var attachment: Attachment?
    public var text = ""              // text story
    public var textColor = ""         // "#AARRGGBB" or "#RRGGBB"
    public var backgroundColor = ""
    public var gradient: [String] = []
    public var previewUrl = ""
    public var viewed = false

    public init() {}

    public var id: String { "\(ts)|\(authorKey)" }
    public var time: Date { Date(timeIntervalSince1970: TimeInterval(ts) / 1000) }
    public var isValid: Bool { ts > 0 && (attachment != nil || !text.isEmpty) }
    /// Stories are shown for 24 hours.
    public func isExpired(now: Int64) -> Bool { now - ts > 24 * 60 * 60 * 1000 }
}

private func parseStory(_ sm: JSON, ts: Int64) -> Story {
    var st = Story()
    st.ts = ts
    st.allowsReplies = sm["allowsReplies"] == nil ? true : jsonBool(sm["allowsReplies"])
    st.groupId = jsonString(sm["groupId"])
    let fa = jsonObject(sm["fileAttachment"])
    if !fa.isEmpty {
        var a = Attachment()
        a.id = jsonString(fa["id"])
        a.contentType = jsonString(fa["contentType"])
        a.filename = jsonString(fa["filename"])
        a.size = jsonInt64(fa["size"])
        a.width = jsonInt(fa["width"])
        a.height = jsonInt(fa["height"])
        st.attachment = a
    }
    let ta = jsonObject(sm["textAttachment"])
    if !ta.isEmpty {
        st.text = jsonString(ta["text"])
        st.textColor = jsonString(ta["textForegroundColor"])
        st.backgroundColor = jsonString(ta["backgroundColor"])
        if st.backgroundColor.isEmpty { st.backgroundColor = jsonString(ta["textBackgroundColor"]) }
        let g = jsonObject(ta["backgroundGradient"])
        st.gradient = jsonArray(g["colors"]).map(jsonString).filter { !$0.isEmpty }
        if st.gradient.isEmpty {
            st.gradient = [jsonString(g["startColor"]), jsonString(g["endColor"])].filter { !$0.isEmpty }
        }
        st.previewUrl = jsonString(jsonObject(ta["preview"])["url"])
    }
    return st
}

/// An @mention: Signal puts U+FFFC into the text and names the person separately (offsets in UTF-16 units).
public struct Mention: Equatable {
    public var start = 0
    public var length = 0
    public var number = ""
    public var uuid = ""
    public var name = ""

    public init(start: Int = 0, length: Int = 0, number: String = "", uuid: String = "", name: String = "") {
        self.start = start
        self.length = length
        self.number = number
        self.uuid = uuid
        self.name = name
    }
}

/// Replaces the mention placeholders in `text` with "@" + name.
public func applyMentions(_ text: String, _ mentions: [Mention], name: (Mention) -> String) -> String {
    let s = NSMutableString(string: text)
    for m in mentions.sorted(by: { $0.start > $1.start }) {
        guard m.start >= 0, m.length > 0, m.start + m.length <= s.length else { continue }
        s.replaceCharacters(in: NSRange(location: m.start, length: m.length), with: "@" + name(m))
    }
    return s as String
}

private func parseMentions(_ dm: JSON) -> [Mention] {
    jsonArray(dm["mentions"]).map { v in
        let o = jsonObject(v)
        return Mention(start: Int(jsonInt64(o["start"])), length: Int(jsonInt64(o["length"])),
                       number: jsonString(o["number"]), uuid: jsonString(o["uuid"]), name: jsonString(o["name"]))
    }
}

private func parseAttachments(_ dm: JSON) -> [Attachment] {
    jsonArray(dm["attachments"]).map { v in
        let o = jsonObject(v)
        var a = Attachment()
        a.id = jsonString(o["id"])
        a.contentType = jsonString(o["contentType"])
        a.filename = jsonString(o["filename"])
        a.size = jsonInt64(o["size"])
        a.width = jsonInt(o["width"])
        a.height = jsonInt(o["height"])
        return a
    }
}

private func parseQuote(_ dm: JSON) -> Quote {
    var q = Quote()
    let o = jsonObject(dm["quote"])
    if o.isEmpty { return q }
    q.valid = true
    q.id = jsonInt64(o["id"])
    q.authorKey = jsonString(o["authorNumber"])
    if q.authorKey.isEmpty { q.authorKey = jsonString(o["authorUuid"]) }
    if q.authorKey.isEmpty { q.authorKey = jsonString(o["author"]) }
    q.text = jsonString(o["text"])
    if let first = jsonArray(o["attachments"]).first {
        q.attachmentNote = jsonString(jsonObject(first)["contentType"])
    }
    return q
}

private func groupIdOf(_ dm: JSON) -> String {
    jsonString(jsonObject(dm["groupInfo"])["groupId"])
}

// Fills reaction or message data from a dataMessage-like object (also used for sync sentMessage).
private func parseBody(_ dm: JSON, _ out: inout ParsedEnvelope, envelopeTs: Int64) {
    out.groupId = groupIdOf(dm)
    out.expirationSeconds = jsonInt(dm["expiresInSeconds"])
    if jsonBool(dm["isExpirationUpdate"]) {
        out.kind = .expirationUpdate
        return
    }
    let r = jsonObject(dm["reaction"])
    let storyContext = jsonObject(dm["storyContext"])
    if !r.isEmpty && !storyContext.isEmpty && !jsonBool(r["isRemove"]) {
        // A reaction to a story arrives in the 1:1 chat, like in the official clients.
        out.isStoryReaction = true
        out.msg.text = jsonString(r["emoji"])
        var q = Quote()
        q.valid = true
        q.id = jsonInt64(storyContext["sentTimestamp"])
        q.authorKey = jsonString(storyContext["authorNumber"])
        if q.authorKey.isEmpty { q.authorKey = jsonString(storyContext["authorUuid"]) }
        q.text = "Reacted to a story"
        q.attachmentNote = "story"
        out.msg.quote = q
        var ts = jsonInt64(dm["timestamp"])
        if ts <= 0 { ts = envelopeTs }
        out.msg.ts = ts > 0 ? ts : nowMs()
        out.kind = out.msg.text.isEmpty ? .none : .message
        return
    }
    if !r.isEmpty {
        out.kind = .reaction
        out.emoji = jsonString(r["emoji"])
        out.remove = jsonBool(r["isRemove"])
        out.targetNumber = jsonString(r["targetAuthorNumber"])
        if out.targetNumber.isEmpty { out.targetNumber = jsonString(r["targetAuthor"]) }
        out.targetUuid = jsonString(r["targetAuthorUuid"])
        out.targetTs = jsonInt64(r["targetSentTimestamp"])
        return
    }
    // "Delete for everyone": {"remoteDelete": {"timestamp": <sent timestamp of the deleted message>}}
    let rd = jsonObject(dm["remoteDelete"])
    if !rd.isEmpty {
        out.targetTs = jsonInt64(rd["timestamp"])
        if out.targetTs > 0 { out.kind = .remoteDelete }
        return
    }

    // Poll vote: {"pollVote": {"authorNumber", "authorUuid", "targetSentTimestamp", "optionIndexes", "voteCount"}}
    let pv = jsonObject(dm["pollVote"])
    if !pv.isEmpty {
        out.targetNumber = jsonString(pv["authorNumber"])
        if out.targetNumber.isEmpty { out.targetNumber = jsonString(pv["author"]) }
        out.targetUuid = jsonString(pv["authorUuid"])
        out.targetTs = jsonInt64(pv["targetSentTimestamp"])
        out.pollOptions = jsonArray(pv["optionIndexes"]).map(jsonInt)
        out.voteCount = jsonInt(pv["voteCount"])
        if out.targetTs > 0 { out.kind = .pollVote }
        return
    }
    let pt = jsonObject(dm["pollTerminate"])
    if !pt.isEmpty {
        out.targetTs = jsonInt64(pt["targetSentTimestamp"])
        if out.targetTs > 0 { out.kind = .pollTerminate }
        return
    }

    out.msg.viewOnce = jsonBool(dm["viewOnce"])
    out.msg.text = jsonString(dm["message"])
    out.mentions = parseMentions(dm)
    out.msg.attachments = parseAttachments(dm)
    if !out.msg.viewOnce { out.msg.linkPreview = parseLinkPreview(dm) }
    // Sticker: {"sticker": {"packId": "<hex>", "stickerId": 3}}
    let sticker = jsonObject(dm["sticker"])
    if !sticker.isEmpty {
        var packId = jsonString(sticker["packId"])
        if packId.isEmpty { packId = jsonString(sticker["packID"]) }
        let idValue = sticker["stickerId"] ?? sticker["id"]
        let stickerId = idValue == nil ? -1 : jsonInt(idValue)
        if !packId.isEmpty && stickerId >= 0 {
            out.msg.attachments = [Attachment.sticker(packId: packId, stickerId: stickerId)]
        }
    }
    // Poll: {"pollCreate": {"question", "allowMultiple", "options"}}
    let pc = jsonObject(dm["pollCreate"])
    if !pc.isEmpty {
        var poll = Poll()
        poll.question = jsonString(pc["question"])
        poll.allowMultiple = pc["allowMultiple"] == nil ? true : jsonBool(pc["allowMultiple"])
        poll.options = jsonArray(pc["options"]).map(jsonString)
        if poll.isValid {
            out.msg.poll = poll
            // Fallback text for clients without poll support (the Qt app shows the text).
            if out.msg.text.isEmpty { out.msg.text = "📊 " + poll.question }
        }
    }
    out.msg.quote = parseQuote(dm)
    // A reply or reaction to a story: {"storyContext": {"authorNumber", "authorUuid", "sentTimestamp"}}
    let sc = jsonObject(dm["storyContext"])
    if !sc.isEmpty && !out.msg.quote.valid {
        var q = Quote()
        q.valid = true
        q.id = jsonInt64(sc["sentTimestamp"])
        q.authorKey = jsonString(sc["authorNumber"])
        if q.authorKey.isEmpty { q.authorKey = jsonString(sc["authorUuid"]) }
        q.text = "Story"
        q.attachmentNote = "story"
        out.msg.quote = q
    }
    out.msg.expiresInSeconds = out.expirationSeconds
    if out.msg.text.isEmpty && out.msg.attachments.isEmpty { return } // receipts, typing, sessions, ...

    var ts = jsonInt64(dm["timestamp"])
    if ts <= 0 { ts = envelopeTs }
    out.msg.ts = ts > 0 ? ts : nowMs()
    out.kind = .message
}

// signal-cli: {"editMessage": {"targetSentTimestamp": ..., "dataMessage": {...}}}
// (top level for incoming edits, inside syncMessage.sentMessage for edits from our other devices).
// Only the text is taken over; attachments of an edit are not changed by the official clients either.
@discardableResult
private func parseEdit(_ edit: JSON, _ out: inout ParsedEnvelope, envelopeTs: Int64) -> Bool {
    let dm = jsonObject(edit["dataMessage"])
    let target = jsonInt64(edit["targetSentTimestamp"])
    let text = jsonString(dm["message"])
    if dm.isEmpty || target <= 0 || text.isEmpty { return false }
    var ts = jsonInt64(dm["timestamp"])
    if ts <= 0 { ts = envelopeTs }
    out.kind = .edit
    out.targetTs = target
    out.msg.text = text
    out.mentions = parseMentions(dm)
    out.msg.ts = ts > 0 ? ts : nowMs()
    out.groupId = groupIdOf(dm)
    return true
}

public func parseEnvelope(_ env: JSON) -> ParsedEnvelope {
    var out = ParsedEnvelope()
    out.src = jsonString(env["sourceNumber"])
    if out.src.isEmpty { out.src = jsonString(env["sourceUuid"]) }
    if out.src.isEmpty { out.src = jsonString(env["source"]) }
    out.srcName = jsonString(env["sourceName"])
    let envTs = jsonInt64(env["timestamp"])

    let dm = jsonObject(env["dataMessage"])
    if !dm.isEmpty {
        parseBody(dm, &out, envelopeTs: envTs)
        return out
    }

    let edit = jsonObject(env["editMessage"])
    if !edit.isEmpty {
        parseEdit(edit, &out, envelopeTs: envTs)
        return out
    }

    let sm = jsonObject(env["storyMessage"])
    if !sm.isEmpty {
        out.story = parseStory(sm, ts: envTs > 0 ? envTs : nowMs())
        out.story.authorName = out.srcName
        if out.story.isValid { out.kind = .story }
        return out
    }
    let sentStory = jsonObject(jsonObject(env["syncMessage"])["sentStoryMessage"])
    if !sentStory.isEmpty {
        out.outgoing = true
        out.story = parseStory(sentStory, ts: envTs > 0 ? envTs : nowMs())
        out.story.outgoing = true
        if out.story.isValid { out.kind = .story }
        return out
    }

    let sent = jsonObject(jsonObject(env["syncMessage"])["sentMessage"])
    if !sent.isEmpty {
        out.outgoing = true
        out.destination = jsonString(sent["destinationNumber"])
        if out.destination.isEmpty { out.destination = jsonString(sent["destination"]) }
        if out.destination.isEmpty { out.destination = jsonString(sent["destinationUuid"]) }
        let sentEdit = jsonObject(sent["editMessage"])
        if !sentEdit.isEmpty {
            parseEdit(sentEdit, &out, envelopeTs: envTs)
        } else {
            parseBody(sent, &out, envelopeTs: envTs)
        }
        out.msg.outgoing = true
    }
    return out
}
