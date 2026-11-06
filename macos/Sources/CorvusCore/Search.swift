import Foundation

// Quick switcher (⌘K) matching and the "Messages" search of the chat list.

public enum FuzzyMatch {
    private static func fold(_ s: String) -> [Character] {
        Array(s.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil))
    }

    /// Score of `query` against `candidate`, nil when the query's characters do not all appear in order.
    /// Higher is better: a prefix beats a word start beats a match inside a word, and runs of consecutive
    /// characters beat scattered ones. Case and diacritics are ignored ("zl" finds "Žluťoučký").
    public static func score(_ query: String, _ candidate: String) -> Int? {
        let q = fold(query.trimmingCharacters(in: .whitespaces)).filter { !$0.isWhitespace }
        if q.isEmpty { return 0 }
        let c = fold(candidate)
        guard !c.isEmpty else { return nil }
        // A plain substring is the strongest signal; check it first.
        let cs = String(c), qs = String(q)
        if let r = cs.range(of: qs) {
            let at = cs.distance(from: cs.startIndex, to: r.lowerBound)
            if at == 0 { return 1000 - c.count }
            let wordStart = !c[at - 1].isLetter && !c[at - 1].isNumber
            return (wordStart ? 800 : 600) - at - c.count / 4
        }
        var score = 0, qi = 0, prev = -2
        for (i, ch) in c.enumerated() where qi < q.count && ch == q[qi] {
            let wordStart = i == 0 || (!c[i - 1].isLetter && !c[i - 1].isNumber)
            score += wordStart ? 12 : (i == prev + 1 ? 8 : 1)
            prev = i
            qi += 1
        }
        guard qi == q.count else { return nil }
        return score * 4 - c.count / 4
    }
}

/// A message found by the chat list search.
public struct MessageSearchHit: Equatable, Identifiable {
    public var key = ""          // conversation
    public var ts: Int64 = 0
    public var authorKey = ""
    public var outgoing = false
    public var sender = ""
    public var snippet = ""      // one line around the first match

    public init() {}

    public var id: String { "\(key)|\(ts)|\(authorKey)|\(outgoing)" }
    public var time: Date { Date(timeIntervalSince1970: TimeInterval(ts) / 1000) }
}

/// Messages of all chats whose text contains `query` (ignoring case and diacritics), newest first.
/// Pure, so the chat list runs it on a copy of the chats off the main thread.
public func searchMessages(_ convs: [String: Conversation], query: String, limit: Int = 50) -> [MessageSearchHit] {
    let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard q.count >= 2 else { return [] }
    var hits: [MessageSearchHit] = []
    for c in convs.values {
        for m in c.msgs.reversed() where !m.deleted && !m.viewOnce && !m.text.isEmpty {
            guard let r = m.text.range(of: q, options: [.caseInsensitive, .diacriticInsensitive]) else { continue }
            var h = MessageSearchHit()
            h.key = c.key
            h.ts = m.ts
            h.authorKey = m.authorKey
            h.outgoing = m.outgoing
            h.sender = m.sender
            h.snippet = snippet(m.text, around: r)
            hits.append(h)
            if hits.count > limit * 4 { break } // enough candidates from one chat
        }
    }
    hits.sort { $0.ts != $1.ts ? $0.ts > $1.ts : $0.key < $1.key }
    return Array(hits.prefix(limit))
}

/// Up to ~30 characters before the match and the rest of the line, on one line.
func snippet(_ text: String, around r: Range<String.Index>) -> String {
    let lead = 30
    let start = text.index(r.lowerBound, offsetBy: -lead, limitedBy: text.startIndex) ?? text.startIndex
    var s = String(text[start...].prefix(160)).replacingOccurrences(of: "\n", with: " ")
    if start != text.startIndex {
        // start at a word boundary
        if let sp = s.firstIndex(of: " "), s.distance(from: s.startIndex, to: sp) < 12 { s = String(s[s.index(after: sp)...]) }
        s = "…" + s
    }
    return s
}
