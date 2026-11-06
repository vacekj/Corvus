import Foundation

/// Result of merging an imported history (Signal Desktop) into the chat state.
public struct ImportSummary: Equatable {
    public var messagesAdded = 0
    public var messagesKnown = 0
    public var reactionsAdded = 0
    public var conversationsAdded = 0
    public var namesSet = 0
    public var receiptsUpdated = 0
    public init() {}
}

extension ChatState {
    /// Merges records from `corvus-signal-import` (the same record format as the history store).
    /// Messages already in the history (same conversation, timestamp and author) are kept as they
    /// are, so running the import again changes nothing. Returns what changed; the caller rewrites
    /// the history file from `allRecords()` afterwards.
    @discardableResult
    public mutating func mergeImported(_ records: [JSON]) -> ImportSummary {
        var sum = ImportSummary()
        for o in records {
            let t = jsonString(o["t"])
            let raw = jsonString(o["c"])
            if raw.isEmpty { continue }
            let key = raw.hasPrefix("g:") ? raw : resolveKey(raw)
            let group = key.hasPrefix("g:")
            switch t {
            case "m":
                if convs[key] == nil {
                    ensure(key, title: group ? "Group" : key, group: group)
                    sum.conversationsAdded += 1
                }
                var m = Records.messageFromRecord(o)
                if !m.authorKey.isEmpty && !m.outgoing { m.authorKey = resolveKey(m.authorKey) }
                if m.outgoing && !account.isEmpty { m.authorKey = account }
                let c = convs[key]!
                let author = effectiveAuthor(c, m)
                if let i = findMessage(c, ts: m.ts, authors: author.isEmpty ? [] : [author]) {
                    sum.messagesKnown += 1
                    // Known outgoing messages still take the delivery and read state (never lowered).
                    if m.outgoing && c.msgs[i].outgoing && (m.receiptStatus > 0 || !m.recipientReceipts.isEmpty) {
                        var cur = c.msgs[i]
                        cur.receiptStatus = max(cur.receiptStatus, m.receiptStatus)
                        for (who, r) in m.recipientReceipts {
                            var x = cur.recipientReceipts[who] ?? RecipientReceipt()
                            x.status = max(x.status, r.status)
                            if x.deliveredAtMs <= 0 { x.deliveredAtMs = r.deliveredAtMs }
                            if x.readAtMs <= 0 { x.readAtMs = r.readAtMs }
                            cur.recipientReceipts[who] = x
                        }
                        if cur.receiptStatus != c.msgs[i].receiptStatus || cur.recipientReceipts != c.msgs[i].recipientReceipts { convs[key]!.msgs[i] = cur; sum.receiptsUpdated += 1 }
                    }
                    continue
                }
                convs[key]!.insertSorted(m)
                sum.messagesAdded += 1
            case "r":
                guard let c = convs[key] else { continue }
                var au = jsonString(o["au"])
                if !au.isEmpty { au = resolveKey(au) }
                guard let i = findMessage(c, ts: jsonInt64(o["ts"]), authors: au.isEmpty ? [] : [au]) else { continue }
                var by = jsonString(o["by"]), e = jsonString(o["e"])
                by = resolveKey(by)
                if by.isEmpty || e.isEmpty || c.msgs[i].reactions[by] != nil { continue }
                e = String(e.prefix(16))
                convs[key]!.msgs[i].reactions[by] = e
                sum.reactionsAdded += 1
            case "n":
                let n = jsonString(o["n"])
                if n.isEmpty { continue }
                if convs[key] == nil { ensure(key, title: n, group: group) }
                let cur = convs[key]!
                if cur.storedName.isEmpty && cur.localNickname.isEmpty
                    && (cur.title == key || cur.title == "Group" || cur.title.isEmpty) {
                    convs[key]!.storedName = n
                    convs[key]!.title = contactNames[key] ?? n
                    sum.namesSet += 1
                }
            default:
                break
            }
        }
        // Conversations that only got a name but no message are not worth a sidebar entry.
        for (k, c) in convs where c.msgs.isEmpty && !records.isEmpty && c.storedName == c.title && sum.namesSet > 0 {
            if !records.contains(where: { jsonString($0["t"]) == "m" && jsonString($0["c"]) == k }) && !c.archived && c.localNickname.isEmpty {
                convs.removeValue(forKey: k)
            }
        }
        return sum
    }
}

/// Decryption of Signal Desktop attachment files (IV || AES-256-CBC || HMAC-SHA256, 64-byte key).
public enum DesktopAttachment {
    public static func isSafeName(_ name: String) -> Bool {
        !name.isEmpty && name.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) && $0.isASCII || $0 == "_" }
    }

    public static func decrypt(_ data: Data, localKey: String, size: Int64) throws -> Data {
        if localKey.isEmpty { return data }
        guard let key = Data(base64Encoded: localKey), key.count == 64 else { throw ImportError("Bad attachment key.") }
        guard data.count >= 64 else { throw ImportError("The attachment file is damaged.") }
        let body = data.prefix(data.count - 32), mac = data.suffix(32)
        let expected = HMAC<SHA256>.authenticationCode(for: body, using: SymmetricKey(data: key.suffix(32)))
        guard Data(expected) == mac else { throw ImportError("The attachment file failed its integrity check.") }
        let iv = body.prefix(16), ct = body.dropFirst(16)
        var out = try aesCBCDecrypt(Data(ct), key: Data(key.prefix(32)), iv: Data(iv))
        if size > 0 && Int(size) < out.count { out = out.prefix(Int(size)) }
        return out
    }
}

public struct ImportError: LocalizedError {
    public let message: String
    public init(_ m: String) { message = m }
    public var errorDescription: String? { message }
}
