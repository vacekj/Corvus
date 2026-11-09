import Foundation

// Delivery and read receipts of outgoing messages. History keys are the ones of the Qt app
// (src/Records.cpp): "rs" = aggregate status 0..2, "rr" = {recipient: {"s": status, "d": deliveredAtMs, "r": readAtMs}}.

/// 0 = sent, 1 = delivered, 2 = read.
public struct RecipientReceipt: Equatable, Hashable {
    public var status = 0
    public var deliveredAtMs: Int64 = 0
    public var readAtMs: Int64 = 0

    public init(status: Int = 0, deliveredAtMs: Int64 = 0, readAtMs: Int64 = 0) {
        self.status = status
        self.deliveredAtMs = deliveredAtMs
        self.readAtMs = readAtMs
    }
}

/// A signal-cli `receiptMessage` envelope.
public struct ReceiptEvent: Equatable {
    public var sender = ""          // number / UUID of the recipient who sent the receipt
    public var status = 0           // 1 = delivered, 2 = read (or viewed)
    public var timestamps: [Int64] = []  // sent timestamps of the acknowledged messages
    public var timeMs: Int64 = 0    // when the receipt was created (envelope timestamp)

    public init() {}
}

/// signal-cli: {"sourceNumber": ..., "timestamp": <when>, "receiptMessage": {"when", "isDelivery", "isRead",
/// "isViewed", "timestamps": [<sent timestamps>]}}. Returns nil for anything else and for receipts without effect.
public func parseReceipt(_ env: JSON) -> ReceiptEvent? {
    let r = jsonObject(env["receiptMessage"])
    if r.isEmpty { return nil }
    var e = ReceiptEvent()
    e.sender = jsonString(env["sourceNumber"])
    if e.sender.isEmpty { e.sender = jsonString(env["sourceUuid"]) }
    if e.sender.isEmpty { e.sender = jsonString(env["source"]) }
    e.timeMs = jsonInt64(env["timestamp"])
    if e.timeMs <= 0 { e.timeMs = jsonInt64(r["when"]) }
    e.status = (jsonBool(r["isRead"]) || jsonBool(r["isViewed"])) ? 2 : (jsonBool(r["isDelivery"]) ? 1 : 0)
    e.timestamps = jsonArray(r["timestamps"]).map(jsonInt64).filter { $0 > 0 }
    return e.status > 0 && !e.sender.isEmpty && !e.timestamps.isEmpty ? e : nil
}

extension Message {
    /// The state shown next to an outgoing message: the best status over all recipients.
    public var deliveryStatus: Int {
        max(receiptStatus, recipientReceipts.values.map(\.status).max() ?? 0)
    }

    public func recipients(withStatusAtLeast status: Int) -> [String] {
        recipientReceipts.filter { $0.value.status >= status }.map(\.key).sorted()
    }
}

extension Records {
    static func recipientReceiptsToJson(_ receipts: [String: RecipientReceipt]) -> JSON {
        var o: JSON = [:]
        for (k, r) in receipts {
            o[k] = ["s": min(max(r.status, 0), 2), "d": r.deliveredAtMs, "r": r.readAtMs] as JSON
        }
        return o
    }

    static func recipientReceiptsFromJson(_ o: JSON) -> [String: RecipientReceipt] {
        var out: [String: RecipientReceipt] = [:]
        for (k, v) in o where !k.isEmpty {
            guard let r = v as? JSON else { continue }
            out[k] = RecipientReceipt(status: min(max(jsonInt(r["s"]), 0), 2),
                                      deliveredAtMs: jsonInt64(r["d"]), readAtMs: jsonInt64(r["r"]))
        }
        return out
    }

    /// Receipt state of an outgoing message: an "update" record with the extras "rs" and "rr".
    public static func receiptUpdate(_ conv: String, _ m: Message) -> JSON {
        var d: JSON = ["rs": min(max(m.receiptStatus, 0), 2)]
        if !m.recipientReceipts.isEmpty { d["rr"] = recipientReceiptsToJson(m.recipientReceipts) }
        return ["t": "u", "c": conv, "ts": m.ts, "au": m.authorKey, "d": d]
    }
}

extension ChatState {
    static let maxUnmatchedReceipts = 200

    /// Records the receipt of `recipient` for the outgoing messages with the sent timestamps `timestamps`.
    /// `key` is the conversation the receipt came from; group receipts do not name the group, so all
    /// conversations are searched (like the Qt app). Returns the records to persist.
    public mutating func applyReceipt(_ key: String, recipient: String, status: Int, timestamps: [Int64],
                                      atMs: Int64) -> [JSON] {
        let status = min(max(status, 1), 2)
        let who = resolveKey(recipient)
        guard !who.isEmpty, who != account else { return [] }
        var recs: [JSON] = []
        for ts in timestamps {
            let matched = applyReceipt(toTimestamp: ts, key: key, recipient: who, status: status, atMs: atMs, records: &recs)
            if !matched {
                // The message may still be waiting for its final timestamp (large group sends): keep it.
                var e = ReceiptEvent()
                e.sender = who
                e.status = status
                e.timestamps = [ts]
                e.timeMs = atMs
                unmatchedReceipts.append(e)
                if unmatchedReceipts.count > ChatState.maxUnmatchedReceipts {
                    unmatchedReceipts.removeFirst(unmatchedReceipts.count - ChatState.maxUnmatchedReceipts)
                }
            }
        }
        return recs
    }

    /// Applies receipts that arrived before their message was confirmed.
    mutating func replayUnmatchedReceipts(for ts: Int64) -> [JSON] {
        let pending = unmatchedReceipts.filter { $0.timestamps.contains(ts) }
        guard !pending.isEmpty else { return [] }
        unmatchedReceipts.removeAll { $0.timestamps.contains(ts) }
        var recs: [JSON] = []
        for e in pending {
            _ = applyReceipt(toTimestamp: ts, key: "", recipient: e.sender, status: e.status, atMs: e.timeMs, records: &recs)
        }
        return recs
    }

    /// True if a message with this timestamp exists (whether or not it changed).
    private mutating func applyReceipt(toTimestamp ts: Int64, key: String, recipient: String, status: Int,
                                       atMs: Int64, records: inout [JSON]) -> Bool {
        var found = false
        func apply(_ ck: String, _ state: inout ChatState) {
            guard var c = state.convs[ck] else { return }
            var changed = false
            for i in c.msgs.indices {
                var m = c.msgs[i]
                guard m.outgoing, !m.deleted, m.ts == ts || m.latestTs == ts else { continue }
                found = true
                var r = m.recipientReceipts[recipient] ?? RecipientReceipt()
                let before = r
                r.status = max(r.status, status)
                if status == 1 && r.deliveredAtMs <= 0 { r.deliveredAtMs = atMs }
                if status == 2 && r.readAtMs <= 0 { r.readAtMs = atMs }
                if r == before && m.recipientReceipts[recipient] != nil { continue }
                m.recipientReceipts[recipient] = r
                m.receiptStatus = max(m.receiptStatus, r.status)
                c.msgs[i] = m
                records.append(Records.receiptUpdate(ck, m))
                changed = true
            }
            if changed { state.convs[ck] = c }
        }
        if !key.isEmpty { apply(key, &self) }
        if !found {
            for ck in convs.keys.sorted() where ck != key { apply(ck, &self) }
        }
        return found
    }
}
