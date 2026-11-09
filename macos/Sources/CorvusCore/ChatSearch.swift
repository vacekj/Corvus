import Foundation

/// Search in one conversation (pure, so it can run off the main thread on a copy of the messages).
public enum ChatSearch {
    /// Ids of the messages whose sender, text, quote or attachment names contain `needle`, oldest first.
    /// Returns nil when the surrounding task was cancelled.
    public static func matches(_ msgs: [Message], _ needle: String) -> [String]? {
        let needle = needle.trimmingCharacters(in: .whitespaces)
        guard !needle.isEmpty else { return [] }
        var out: [String] = []
        for (i, m) in msgs.enumerated() {
            if i % 512 == 0 && Task.isCancelled { return nil }
            var s = m.sender + "\n" + m.text + "\n" + m.quote.text
            for a in m.attachments { s += "\n" + a.filename }
            if s.localizedCaseInsensitiveContains(needle) { out.append(m.id) }
        }
        return out
    }

    /// The match to show after a new search: the newest one, or (when refreshing) the one that was selected
    /// if it is still a match. -1 when there are none.
    public static func position(in ids: [String], keeping selected: String?) -> Int {
        guard !ids.isEmpty else { return -1 }
        if let selected, let i = ids.lastIndex(of: selected) { return i }
        return ids.count - 1
    }

    /// The next match; backwards (previous, ↑) goes to older messages. Wraps around.
    public static func step(_ position: Int, count: Int, backwards: Bool) -> Int {
        guard count > 0 else { return -1 }
        return (position + (backwards ? count - 1 : 1)) % count
    }
}
