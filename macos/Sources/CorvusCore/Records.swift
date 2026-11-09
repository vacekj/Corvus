import Foundation

/// Conversion between the in-memory model and the JSON records of the encrypted history store
/// (see history-store/src/store.rs `Record`). The keys must stay identical to the Qt app
/// (src/Records.cpp) so both read the same history file.
public enum Records {
    private static func attachmentToJson(_ a: Attachment) -> JSON {
        var o: JSON = [:]
        if !a.id.isEmpty { o["id"] = a.id }
        if !a.contentType.isEmpty { o["ct"] = a.contentType }
        if !a.filename.isEmpty { o["fn"] = a.filename }
        if !a.path.isEmpty { o["p"] = a.path }
        if a.size > 0 { o["sz"] = a.size }
        if a.width > 0 { o["w"] = a.width }
        if a.height > 0 { o["h"] = a.height }
        if !a.thumb.isEmpty { o["th"] = a.thumb.base64EncodedString() }
        if !a.encPath.isEmpty { o["ep"] = a.encPath; o["lk"] = a.localKey }
        return o
    }

    private static func attachmentFromJson(_ o: JSON) -> Attachment {
        var a = Attachment()
        a.id = jsonString(o["id"])
        a.contentType = jsonString(o["ct"])
        a.filename = jsonString(o["fn"])
        a.path = jsonString(o["p"])
        a.size = jsonInt64(o["sz"])
        a.width = jsonInt(o["w"])
        a.height = jsonInt(o["h"])
        a.thumb = Data(base64Encoded: jsonString(o["th"])) ?? Data()
        a.encPath = jsonString(o["ep"])
        a.localKey = jsonString(o["lk"])
        return a
    }

    // Edit state: x = current text, et = timestamp of the latest revision, ec = number of edits.
    private static func editToJson(_ m: Message) -> JSON {
        var e: JSON = ["x": m.text, "et": m.editTs, "ec": m.editCount]
        if !m.textStyles.isEmpty { e["st"] = textStylesToJson(m.textStyles) }
        if !m.mentions.isEmpty { e["mn"] = mentionsToJson(m.mentions) }
        return e
    }

    public static func message(_ conv: String, _ m: Message) -> JSON {
        var d: JSON = [:]
        if m.orderTs > 0 { d["ot"] = m.orderTs }
        if m.deleted { d["dl"] = true } // placeholder only: no quote, attachments or edit state
        if m.expiresInSeconds > 0 {
            d["ex"] = m.expiresInSeconds
            d["es"] = m.expirationStartMs
        }
        if m.quote.valid && !m.deleted {
            d["q"] = ["id": m.quote.id, "a": m.quote.authorKey, "t": m.quote.text, "n": m.quote.attachmentNote] as JSON
        }
        if m.viewOnce {
            d["vo"] = true
            if m.viewOnceViewed { d["vv"] = true }
            if m.viewOnceExpired { d["ve"] = true }
        }
        // Never keep sent or consumed View Once media in the history. For an unopened incoming item only
        // the opaque signal-cli attachment reference is stored (same rule as src/Records.cpp).
        let keepViewOnceRef = !m.viewOnce || (!m.outgoing && !m.viewOnceViewed && !m.viewOnceExpired)
        if !m.attachments.isEmpty && !m.deleted && keepViewOnceRef {
            var atts = m.attachments
            if m.viewOnce { for i in atts.indices { atts[i].thumb = Data(); atts[i].path = "" } }
            d["at"] = atts.map(attachmentToJson)
        }
        if m.poll.isValid && !m.deleted { d["pl"] = pollToJson(m.poll) }
        if !m.textStyles.isEmpty && !m.deleted { d["st"] = textStylesToJson(m.textStyles) }
        if !m.mentions.isEmpty && !m.deleted { d["mn"] = mentionsToJson(m.mentions) }
        // "to" is local-only: the Qt app ignores unknown extras. It keeps the recipients of a group
        // send so receipt details can show sent/waiting members and a denominator after a restart.
        if m.outgoing && !m.sentToKeys.isEmpty { d["to"] = m.sentToKeys }
        if m.outgoing && m.receiptStatus > 0 { d["rs"] = min(m.receiptStatus, 2) }
        if m.outgoing && !m.recipientReceipts.isEmpty { d["rr"] = recipientReceiptsToJson(m.recipientReceipts) }
        if let lp = linkPreviewExtra(m) { d["lp"] = lp }
        // Local-only extras (the Qt app ignores them): a failed send and a pinned message.
        if m.outgoing && m.sendFailed && !m.deleted { d["fs"] = true }
        if m.pinnedAtMs > 0 && !m.deleted { d["pn"] = pinToJson(m) }
        var rec: JSON = ["t": "m", "c": conv, "ts": m.ts, "s": m.sender, "x": m.deleted ? "" : m.text,
                         "o": m.outgoing, "au": m.authorKey]
        if m.editCount > 0 && !m.deleted { d["ed"] = editToJson(m) }
        if !d.isEmpty { rec["d"] = d }
        return rec
    }

    /// Text edit of a message: an "update" record with the extra "ed"; ts = original timestamp.
    /// "lp" is the preview sent with the edit; empty removes the old one (same as the Qt app).
    public static func edit(_ conv: String, _ m: Message) -> JSON {
        ["t": "u", "c": conv, "ts": m.ts, "au": m.authorKey, "d": ["ed": editToJson(m), "lp": linkPreviewExtra(m) ?? JSON()] as JSON]
    }

    /// Delete for everyone: an "update" record with the extra "dl"; ts = original timestamp.
    public static func deletion(_ conv: String, _ m: Message) -> JSON {
        ["t": "u", "c": conv, "ts": m.ts, "au": m.authorKey, "d": ["dl": true] as JSON]
    }

    /// Pinned / unpinned message: "pn" {at: pinned at, ex: pin ends (0 = never)}; an empty object unpins.
    public static func pinUpdate(_ conv: String, _ m: Message) -> JSON {
        ["t": "u", "c": conv, "ts": m.ts, "au": m.authorKey, "d": ["pn": m.pinnedAtMs > 0 ? pinToJson(m) : JSON()] as JSON]
    }

    static func pinToJson(_ m: Message) -> JSON {
        var o: JSON = ["at": m.pinnedAtMs]
        if m.pinExpiresMs > 0 { o["ex"] = m.pinExpiresMs }
        return o
    }

    public static func expirationUpdate(_ conv: String, _ m: Message) -> JSON {
        ["t": "u", "c": conv, "ts": m.ts, "au": m.authorKey,
         "d": ["ex": m.expiresInSeconds, "es": m.expirationStartMs] as JSON]
    }

    /// The View Once media was opened: drop the attachment reference for good.
    public static func viewOnceUpdate(_ conv: String, _ m: Message) -> JSON {
        ["t": "u", "c": conv, "ts": m.ts, "au": m.authorKey,
         "d": ["vv": m.viewOnceViewed, "ve": m.viewOnceExpired, "at": [Any]()] as JSON]
    }

    /// Poll state after a vote or after the poll was closed (the whole poll is stored again).
    public static func pollUpdate(_ conv: String, _ m: Message) -> JSON {
        ["t": "u", "c": conv, "ts": m.ts, "au": m.authorKey, "d": ["pl": pollToJson(m.poll)] as JSON]
    }

    // Poll: q = question, o = options, m = multiple choice, e = ended, v = votes {voter: [idx]}, n = vote counts.
    // Not used by the Qt app, which ignores unknown extras and shows the fallback text of the message.
    static func pollToJson(_ p: Poll) -> JSON {
        var o: JSON = ["q": p.question, "o": p.options, "m": p.allowMultiple]
        if p.ended { o["e"] = true }
        if !p.votes.isEmpty { o["v"] = p.votes }
        if !p.voteCounts.isEmpty { o["n"] = p.voteCounts }
        return o
    }

    static func pollFromJson(_ o: JSON) -> Poll {
        var p = Poll()
        p.question = jsonString(o["q"])
        p.options = jsonArray(o["o"]).map(jsonString)
        p.allowMultiple = o["m"] == nil ? true : jsonBool(o["m"])
        p.ended = jsonBool(o["e"])
        for (k, v) in jsonObject(o["v"]) { p.votes[k] = jsonArray(v).map(jsonInt) }
        for (k, v) in jsonObject(o["n"]) { p.voteCounts[k] = jsonInt(v) }
        return p
    }

    public static func attachmentsUpdate(_ conv: String, _ m: Message) -> JSON {
        ["t": "u", "c": conv, "ts": m.ts, "au": m.authorKey, "d": ["at": m.attachments.map(attachmentToJson)] as JSON]
    }

    /// Extras ("d": quote, attachments, edit state, expiry, deletion) as stored in message / update records.
    public static func applyExtras(_ m: inout Message, _ d: JSON) {
        if d["ot"] != nil { m.orderTs = jsonInt64(d["ot"]) }
        if let q = d["q"] as? JSON {
            m.quote.valid = true
            m.quote.id = jsonInt64(q["id"])
            m.quote.authorKey = jsonString(q["a"])
            m.quote.text = jsonString(q["t"])
            m.quote.attachmentNote = jsonString(q["n"])
        }
        if d["st"] != nil { m.textStyles = textStylesFromJson(d["st"]) }
        if d["mn"] != nil { m.mentions = mentionsFromJson(d["mn"]) }
        if let to = d["to"], m.outgoing {
            var keys: [String] = []
            var seen = Set<String>()
            for key in jsonArray(to).map(jsonString) {
                guard !key.isEmpty, seen.insert(key).inserted else { continue }
                keys.append(key)
            }
            m.sentToKeys = keys
        }
        if d["rs"] != nil && m.outgoing { m.receiptStatus = min(max(jsonInt(d["rs"]), 0), 2) }
        if d["rr"] != nil && m.outgoing { m.recipientReceipts = recipientReceiptsFromJson(jsonObject(d["rr"])) }
        if let e = d["ed"] as? JSON {
            if e["x"] != nil {
                // The edit record carries the whole new body: text without "st"/"mn" is unformatted.
                m.text = jsonString(e["x"])
                m.textStyles = textStylesFromJson(e["st"])
                m.mentions = mentionsFromJson(e["mn"])
            }
            m.editTs = jsonInt64(e["et"])
            m.editCount = jsonInt(e["ec"])
        }
        if d["ex"] != nil {
            m.expiresInSeconds = jsonInt(d["ex"])
            m.expirationStartMs = jsonInt64(d["es"])
        }
        if d["vo"] != nil { m.viewOnce = jsonBool(d["vo"]) }
        if d["vv"] != nil { m.viewOnceViewed = jsonBool(d["vv"]) }
        if d["ve"] != nil { m.viewOnceExpired = jsonBool(d["ve"]) }
        if let pl = d["pl"] as? JSON { m.poll = pollFromJson(pl) }
        if let lp = d["lp"] as? JSON { m.linkPreview = linkPreviewFromJson(lp) }
        if d["fs"] != nil { m.sendFailed = m.outgoing && jsonBool(d["fs"]) }
        if let pn = d["pn"] as? JSON {
            m.pinnedAtMs = jsonInt64(pn["at"])
            m.pinExpiresMs = m.pinnedAtMs > 0 ? jsonInt64(pn["ex"]) : 0
        }
        if d["at"] != nil {
            m.attachments = jsonArray(d["at"]).map { attachmentFromJson(jsonObject($0)) }
        }
        if m.viewOnce && (m.viewOnceViewed || m.viewOnceExpired) { m.attachments = [] }
        if jsonBool(d["dl"]) { // last: wins over anything else in the same record
            m.markDeleted()
        }
    }

    public static func messageFromRecord(_ rec: JSON) -> Message {
        var m = Message()
        m.ts = jsonInt64(rec["ts"])
        m.sender = jsonString(rec["s"])
        m.text = jsonString(rec["x"])
        m.outgoing = jsonBool(rec["o"])
        m.authorKey = jsonString(rec["au"])
        applyExtras(&m, jsonObject(rec["d"]))
        return m
    }

    public static func reaction(_ conv: String, ts: Int64, author: String, by: String, emoji: String) -> JSON {
        ["t": "r", "c": conv, "ts": ts, "au": author, "by": by, "e": emoji]
    }

    public static func archive(_ conv: String, archived: Bool, sigArchived: Bool) -> JSON {
        ["t": "a", "c": conv, "v": archived, "s": sigArchived]
    }

    public static func mute(_ conv: String, _ muted: Bool) -> JSON { ["t": "k", "c": conv, "v": muted] }
    public static func expiration(_ conv: String, _ seconds: Int) -> JSON { ["t": "e", "c": conv, "v": seconds] }
    public static func name(_ conv: String, _ n: String) -> JSON { ["t": "n", "c": conv, "n": n] }
    public static func nickname(_ conv: String, _ n: String) -> JSON { ["t": "p", "c": conv, "n": n] }
    public static func pin(_ conv: String, _ pinned: Bool) -> JSON { ["t": "pin", "c": conv, "v": pinned] }
    public static func markedUnread(_ conv: String, _ marked: Bool) -> JSON { ["t": "mu", "c": conv, "v": marked] }
}
