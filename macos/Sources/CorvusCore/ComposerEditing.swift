import Foundation

// Composer helpers: ⌘B / ⌘I markers and @mention autocomplete. Offsets are UTF-16 units (NSTextView ranges).

/// ⌘B / ⌘I: wraps the selection in a markdown marker ("**" bold, "_" italic), or removes the marker when the
/// selection is already wrapped. Without a selection the markers are inserted with the caret between them.
/// Returns the range to replace, its replacement and the selection afterwards.
public func toggleMarker(_ marker: String, text: String, selection: NSRange)
    -> (range: NSRange, replacement: String, selection: NSRange) {
    let ns = text as NSString
    let m = marker as NSString
    let ml = m.length
    let sel = NSRange(location: min(max(selection.location, 0), ns.length),
                      length: min(max(selection.length, 0), ns.length - min(max(selection.location, 0), ns.length)))
    let inner = ns.substring(with: sel)
    // The selection itself includes the markers: "**bold**" selected.
    if sel.length >= 2 * ml, inner.hasPrefix(marker), inner.hasSuffix(marker) {
        let unwrapped = (inner as NSString).substring(with: NSRange(location: ml, length: sel.length - 2 * ml))
        return (sel, unwrapped, NSRange(location: sel.location, length: (unwrapped as NSString).length))
    }
    // The markers surround the selection: **[bold]**.
    if sel.location >= ml, sel.location + sel.length + ml <= ns.length,
       ns.substring(with: NSRange(location: sel.location - ml, length: ml)) == marker,
       ns.substring(with: NSRange(location: sel.location + sel.length, length: ml)) == marker,
       sel.length > 0 {
        let outer = NSRange(location: sel.location - ml, length: sel.length + 2 * ml)
        return (outer, inner, NSRange(location: outer.location, length: sel.length))
    }
    return (sel, marker + inner + marker, NSRange(location: sel.location + ml, length: sel.length))
}

/// The "@name" being typed before the caret: the range covers the "@" and the query typed after it.
/// The "@" must start a word, and the query may not contain whitespace.
public func mentionQuery(text: String, caret: Int) -> (range: NSRange, query: String)? {
    let u = Array(text.utf16)
    guard caret >= 1, caret <= u.count else { return nil }
    var i = caret - 1
    while i >= 0 {
        let c = u[i]
        if c == 0x40 { // "@"
            if i > 0, let prev = Unicode.Scalar(u[i - 1]), !CharacterSet.whitespacesAndNewlines.contains(prev),
               !CharacterSet.punctuationCharacters.contains(prev) || prev == "@" { return nil }
            let query = String(decoding: u[(i + 1)..<caret], as: UTF16.self)
            return query.count <= 40 ? (NSRange(location: i, length: caret - i), query) : nil
        }
        if let s = Unicode.Scalar(c), CharacterSet.whitespacesAndNewlines.contains(s) { return nil }
        i -= 1
    }
    return nil
}

/// A group member who can be mentioned.
public struct MentionCandidate: Equatable {
    public var name: String
    public var id: String        // ACI UUID or number, as signal-cli's `mention` accepts it

    public init(name: String, id: String) {
        self.name = name
        self.id = id
    }
}

/// Members for an "@query": names starting with it, or with a word starting with it, first.
public func mentionSuggestions(_ query: String, _ candidates: [MentionCandidate], limit: Int = 6) -> [MentionCandidate] {
    let scored = candidates.compactMap { c in FuzzyMatch.score(query, c.name).map { (c, $0) } }
    return scored.sorted { $0.1 != $1.1 ? $0.1 > $1.1 : $0.0.name.localizedStandardCompare($1.0.name) == .orderedAscending }
        .prefix(limit).map(\.0)
}

/// Mentions in the text about to be sent: every "@Name" of a member (at a word start, not followed by a letter
/// or digit). Longer names win, so "@Ann Lee" is not taken for "@Ann".
public func resolveMentions(text: String, candidates: [MentionCandidate]) -> [MentionRange] {
    let ns = text as NSString
    var taken = IndexSet()
    var out: [MentionRange] = []
    for c in candidates.filter({ !$0.name.isEmpty && !$0.id.isEmpty }).sorted(by: { ($0.name as NSString).length > ($1.name as NSString).length }) {
        let needle = "@" + c.name
        var from = 0
        while from < ns.length {
            let r = ns.range(of: needle, options: [], range: NSRange(location: from, length: ns.length - from))
            if r.location == NSNotFound { break }
            from = r.location + 1
            if r.location > 0, let prev = Unicode.Scalar(ns.character(at: r.location - 1)),
               CharacterSet.alphanumerics.contains(prev) { continue }
            let end = r.location + r.length
            if end < ns.length, let next = Unicode.Scalar(ns.character(at: end)), CharacterSet.alphanumerics.contains(next) { continue }
            if taken.intersects(integersIn: r.location..<end) { continue }
            taken.insert(integersIn: r.location..<end)
            out.append(MentionRange(start: r.location, length: r.length, uuid: c.id))
        }
    }
    return out.sorted { $0.start < $1.start }
}
