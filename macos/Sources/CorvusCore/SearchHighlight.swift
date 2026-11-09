import Foundation

/// Where a search query occurs in a text, for highlighting. The comparison options match the searches that
/// found the message: `ChatSearch` (case-insensitive, localized) and the chat list search (also ignoring
/// diacritics).
public enum SearchHighlight {
    public static let chatOptions: String.CompareOptions = [.caseInsensitive]
    public static let listOptions: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]

    /// All non-overlapping occurrences of `query` (trimmed) in `text`, in order.
    /// `locale` as in the search: `ChatSearch` compares localized, the chat list search does not.
    public static func ranges(of query: String, in text: String, options: String.CompareOptions = chatOptions,
                              locale: Locale? = .current, limit: Int = 200) -> [Range<String.Index>] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty, !text.isEmpty else { return [] }
        var out: [Range<String.Index>] = []
        var from = text.startIndex
        while from < text.endIndex, out.count < limit,
              let r = text.range(of: q, options: options, range: from..<text.endIndex, locale: locale) {
            if r.isEmpty { break }
            out.append(r)
            from = r.upperBound
        }
        return out
    }

    /// The same as UTF-16 ranges (NSString / NSTextView offsets).
    public static func nsRanges(of query: String, in text: String, options: String.CompareOptions = chatOptions,
                                locale: Locale? = .current) -> [NSRange] {
        ranges(of: query, in: text, options: options, locale: locale).map { NSRange($0, in: text) }
    }
}
