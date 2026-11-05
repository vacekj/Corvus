import Foundation

// Signal text formatting: styles (bold, italic, ...) and @mentions.
//
// All offsets are UTF-16 code units, like Signal and signal-cli. History keys are the ones of the
// Qt app (src/Records.cpp): "st" = ["start:length:STYLE", ...], "mn" = [{"s": start, "l": length, "u": uuid}].

public enum TextStyle: String, CaseIterable {
    case bold = "BOLD"
    case italic = "ITALIC"
    case strikethrough = "STRIKETHROUGH"
    case monospace = "MONOSPACE"
    case spoiler = "SPOILER"
}

/// A styled part of a message. `style` stays a string so unknown styles of newer clients survive a round trip.
public struct TextStyleRange: Equatable, Hashable {
    public var start: Int
    public var length: Int
    public var style: String

    public init(start: Int, length: Int, style: String) {
        self.start = start
        self.length = length
        self.style = style
    }

    public init(start: Int, length: Int, style: TextStyle) {
        self.init(start: start, length: length, style: style.rawValue)
    }

    public var textStyle: TextStyle? { TextStyle(rawValue: style) }

    /// signal-cli `--text-style` / JSON-RPC `textStyle` syntax: "start:length:STYLE".
    public var cliString: String { "\(start):\(length):\(style)" }

    public init?(cliString s: String) {
        let p = s.split(separator: ":", omittingEmptySubsequences: false)
        guard p.count == 3, let start = Int(p[0]), let length = Int(p[1]), start >= 0, length > 0, !p[2].isEmpty
        else { return nil }
        self.init(start: start, length: length, style: String(p[2]))
    }
}

/// An @mention inside the message text. `start`/`length` cover the mention in `Message.text`, which is either a
/// single U+FFFC placeholder (as received by Qt-app history) or the already inserted "@Name".
public struct MentionRange: Equatable, Hashable {
    public var start: Int
    public var length: Int
    public var uuid: String       // ACI UUID, or phone number for legacy accounts

    public init(start: Int, length: Int, uuid: String = "") {
        self.start = start
        self.length = length
        self.uuid = uuid
    }
}

/// Text together with its styles and mentions.
public struct FormattedBody: Equatable {
    public var text = ""
    public var styles: [TextStyleRange] = []
    public var mentions: [MentionRange] = []

    public init(text: String = "", styles: [TextStyleRange] = [], mentions: [MentionRange] = []) {
        self.text = text
        self.styles = styles
        self.mentions = mentions
    }
}

public let mentionPlaceholder: UInt16 = 0xFFFC

// MARK: - signal-cli JSON

/// Styles of an incoming dataMessage. signal-cli (JsonDataMessage) lists `textStyles: [{style, start, length}]`;
/// the string form "start:length:STYLE" (as used by `send`, and read by the Qt app from "textStyle") is accepted too.
public func parseTextStyles(_ dm: JSON) -> [TextStyleRange] {
    var out: [TextStyleRange] = []
    for key in ["textStyles", "textStyle"] {
        for v in jsonArray(dm[key]) {
            if let s = v as? String {
                if let r = TextStyleRange(cliString: s) { out.append(r) }
            } else if let o = v as? JSON {
                let start = jsonInt(o["start"]), length = jsonInt(o["length"]), style = jsonString(o["style"])
                if start >= 0, length > 0, !style.isEmpty { out.append(TextStyleRange(start: start, length: length, style: style)) }
            }
        }
        if !out.isEmpty { break }
    }
    return out
}

// MARK: - Offsets

/// Replaces mention placeholders (U+FFFC) of `text` by "@name" and keeps styles and mentions aligned.
/// `label` gets the index into `mentions` and returns the name (without "@"). Mentions whose text is not a
/// placeholder (already expanded, or a legacy range over "@Name") are kept unchanged.
public func expandMentions(text: String, styles: [TextStyleRange], mentions: [MentionRange],
                           label: (Int) -> String) -> FormattedBody {
    let src = Array(text.utf16)
    let n = src.count
    let order = mentions.indices.filter { mentions[$0].start >= 0 && mentions[$0].length > 0 && mentions[$0].start < n }
        .sorted { mentions[$0].start < mentions[$1].start }

    var out: [UInt16] = []
    out.reserveCapacity(n + 16)
    var map = [Int](repeating: 0, count: n + 1)   // old offset -> new offset
    var outMentions: [MentionRange] = []
    var pos = 0
    for i in order {
        let m = mentions[i]
        if m.start < pos { continue } // overlapping
        while pos < m.start { map[pos] = out.count; out.append(src[pos]); pos += 1 }
        if src[pos] == mentionPlaceholder {
            let replacement = Array(("@" + label(i)).utf16)
            let newStart = out.count
            map[pos] = newStart
            out.append(contentsOf: replacement)
            pos += 1
            map[pos] = out.count
            outMentions.append(MentionRange(start: newStart, length: replacement.count, uuid: m.uuid))
        } else {
            let length = min(m.length, n - pos)
            let newStart = out.count
            while pos < m.start + length { map[pos] = out.count; out.append(src[pos]); pos += 1 }
            map[pos] = out.count
            outMentions.append(MentionRange(start: newStart, length: length, uuid: m.uuid))
        }
    }
    while pos < n { map[pos] = out.count; out.append(src[pos]); pos += 1 }
    map[n] = out.count

    var outStyles: [TextStyleRange] = []
    for s in styles where s.start >= 0 && s.length > 0 && !s.style.isEmpty {
        let a = min(s.start, n), b = min(s.start + s.length, n)
        let na = map[a], nb = map[b]
        if nb > na { outStyles.append(TextStyleRange(start: na, length: nb - na, style: s.style)) }
    }
    return FormattedBody(text: String(decoding: out, as: UTF16.self), styles: outStyles, mentions: outMentions)
}

/// Receive path: signal-cli reports each mention with a placeholder in the text (offsets in UTF-16 units).
public func substituteMentions(_ text: String, _ mentions: [Mention], styles: [TextStyleRange],
                               name: (Mention) -> String) -> FormattedBody {
    let ranges = mentions.map { MentionRange(start: $0.start, length: $0.length, uuid: $0.uuid.isEmpty ? $0.number : $0.uuid) }
    return expandMentions(text: text, styles: styles, mentions: ranges) { name(mentions[$0]) }
}

// MARK: - Rendering model

/// A stretch of text with one set of styles (and, for a mention, its range). Offsets are UTF-16 units.
public struct StyledRun: Equatable {
    public var location: Int
    public var length: Int
    public var styles: Set<TextStyle>
    public var mention: MentionRange?
    /// Index (in order of appearance) of the spoiler this run belongs to; nil outside spoilers.
    public var spoiler: Int?
}

/// Splits the text into runs of equal formatting.
public func styledRuns(text: String, styles: [TextStyleRange], mentions: [MentionRange] = []) -> [StyledRun] {
    let n = text.utf16.count
    guard n > 0 else { return [] }
    var active = [Set<TextStyle>](repeating: [], count: n)
    var spoilerId = [Int?](repeating: nil, count: n)
    var spoilerCount = 0
    for s in styles.sorted(by: { $0.start < $1.start }) {
        guard let st = s.textStyle, s.start >= 0, s.length > 0, s.start < n else { continue }
        let end = min(n, s.start + s.length)
        for i in s.start..<end { active[i].insert(st) }
        if st == .spoiler {
            for i in s.start..<end { spoilerId[i] = spoilerCount }
            spoilerCount += 1
        }
    }
    var mentionAt = [Int?](repeating: nil, count: n)
    for (k, m) in mentions.enumerated() where m.start >= 0 && m.length > 0 && m.start < n {
        for i in m.start..<min(n, m.start + m.length) where mentionAt[i] == nil { mentionAt[i] = k }
    }

    var runs: [StyledRun] = []
    var i = 0
    while i < n {
        var j = i + 1
        while j < n && active[j] == active[i] && mentionAt[j] == mentionAt[i] && spoilerId[j] == spoilerId[i] { j += 1 }
        runs.append(StyledRun(location: i, length: j - i, styles: active[i],
                              mention: mentionAt[i].map { mentions[$0] }, spoiler: spoilerId[i]))
        i = j
    }
    return runs
}

// MARK: - Composer markdown

private struct MarkerSpec {
    let token: [Character]
    let style: TextStyle
    let literal: Bool           // content is not parsed further (monospace)
    let wordBoundary: Bool      // may not touch letters/digits outside (so snake_case stays untouched)
}

private let markerSpecs: [MarkerSpec] = [
    MarkerSpec(token: ["|", "|"], style: .spoiler, literal: false, wordBoundary: false),
    MarkerSpec(token: ["*", "*"], style: .bold, literal: false, wordBoundary: false),
    MarkerSpec(token: ["~", "~"], style: .strikethrough, literal: false, wordBoundary: false),
    MarkerSpec(token: ["`"], style: .monospace, literal: true, wordBoundary: false),
    MarkerSpec(token: ["_"], style: .italic, literal: false, wordBoundary: true),
    MarkerSpec(token: ["~"], style: .strikethrough, literal: false, wordBoundary: true),
]

private func isWordCharacter(_ c: Character) -> Bool { c.isLetter || c.isNumber }

private func matches(_ chars: [Character], at i: Int, _ token: [Character]) -> Bool {
    guard i >= 0, i + token.count <= chars.count else { return false }
    for k in 0..<token.count where chars[i + k] != token[k] { return false }
    return true
}

/// Parses one level of markdown. Returns the plain text and the styles relative to its start.
private func parseMarkdown(_ chars: [Character]) -> (text: String, units: Int, styles: [TextStyleRange]) {
    var text = ""
    var units = 0
    var styles: [TextStyleRange] = []
    var i = 0
    outer: while i < chars.count {
        for spec in markerSpecs where matches(chars, at: i, spec.token) {
            let open = i, contentStart = i + spec.token.count
            if spec.wordBoundary && open > 0 && isWordCharacter(chars[open - 1]) { continue }
            guard contentStart < chars.count, !chars[contentStart].isWhitespace else { continue }
            var j = contentStart
            while j < chars.count {
                if matches(chars, at: j, spec.token), j > contentStart, !chars[j - 1].isWhitespace {
                    let after = j + spec.token.count
                    if !(spec.wordBoundary && after < chars.count && isWordCharacter(chars[after])) {
                        let content = Array(chars[contentStart..<j])
                        let inner: (text: String, units: Int, styles: [TextStyleRange])
                        if spec.literal {
                            let s = String(content)
                            inner = (s, s.utf16.count, [])
                        } else {
                            inner = parseMarkdown(content)
                        }
                        guard inner.units > 0, content.contains(where: { $0 != spec.token[0] }) else { break }
                        styles.append(TextStyleRange(start: units, length: inner.units, style: spec.style))
                        for s in inner.styles {
                            styles.append(TextStyleRange(start: units + s.start, length: s.length, style: s.style))
                        }
                        text += inner.text
                        units += inner.units
                        i = after
                        continue outer
                    }
                }
                if spec.literal && matches(chars, at: j, spec.token) { break } // a monospace span ends at the next backtick
                j += 1
            }
        }
        let c = chars[i]
        text.append(c)
        units += String(c).utf16.count
        i += 1
    }
    return (text, units, styles)
}

/// Composer input with markdown-like markers → plain text plus Signal styles.
/// `**bold**`, `_italic_`, `~strike~` (or `~~strike~~`), `` `mono` ``, `||spoiler||`.
public func parseMarkdownStyles(_ input: String) -> (text: String, styles: [TextStyleRange]) {
    let r = parseMarkdown(Array(input))
    return (r.text, r.styles.sorted { $0.start != $1.start ? $0.start < $1.start : $0.length > $1.length })
}

/// The inverse of `parseMarkdownStyles`, for editing a sent message.
public func markdownSource(text: String, styles: [TextStyleRange]) -> String {
    let units = Array(text.utf16)
    let n = units.count
    func token(_ s: String) -> String? {
        switch TextStyle(rawValue: s) {
        case .bold: return "**"
        case .italic: return "_"
        case .strikethrough: return "~"
        case .monospace: return "`"
        case .spoiler: return "||"
        case nil: return nil
        }
    }
    var opens = [[String]](repeating: [], count: n + 1)
    var closes = [[String]](repeating: [], count: n + 1)
    // Outer ranges open first and close last.
    for s in styles.sorted(by: { $0.start != $1.start ? $0.start < $1.start : $0.length > $1.length }) {
        guard let t = token(s.style), s.start >= 0, s.length > 0, s.start < n else { continue }
        opens[s.start].append(t)
        closes[min(n, s.start + s.length)].insert(t, at: 0)
    }
    var out: [UInt16] = []
    for i in 0...n {
        for t in closes[i] { out.append(contentsOf: t.utf16) }
        for t in opens[i] { out.append(contentsOf: t.utf16) }
        if i < n { out.append(units[i]) }
    }
    return String(decoding: out, as: UTF16.self)
}

// MARK: - History records

extension Records {
    static func textStylesToJson(_ styles: [TextStyleRange]) -> [String] {
        styles.filter { $0.start >= 0 && $0.length > 0 && !$0.style.isEmpty }.map(\.cliString)
    }

    static func textStylesFromJson(_ a: Any?) -> [TextStyleRange] {
        jsonArray(a).compactMap { ($0 as? String).flatMap(TextStyleRange.init(cliString:)) }
    }

    static func mentionsToJson(_ mentions: [MentionRange]) -> [JSON] {
        mentions.filter { $0.start >= 0 && $0.length > 0 }.map { m in
            var o: JSON = ["s": m.start, "l": m.length]
            if !m.uuid.isEmpty { o["u"] = m.uuid }
            return o
        }
    }

    static func mentionsFromJson(_ a: Any?) -> [MentionRange] {
        jsonArray(a).compactMap { v in
            let o = jsonObject(v)
            let start = o["s"] == nil ? -1 : jsonInt(o["s"]), length = jsonInt(o["l"])
            guard start >= 0, length > 0 else { return nil }
            return MentionRange(start: start, length: length, uuid: jsonString(o["u"]))
        }
    }
}
