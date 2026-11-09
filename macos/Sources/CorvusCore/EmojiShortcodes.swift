import Foundation

/// ":shortcode:" lookup for the composer. Codes are the emoji names with underscores
/// ("face_with_tears_of_joy") plus the common short aliases people know from Signal, Slack and GitHub
/// ("joy", "+1", "heart").
public struct EmojiShortcodeIndex {
    public struct Match: Equatable, Hashable {
        public let emoji: String
        public let code: String
        public init(emoji: String, code: String) {
            self.emoji = emoji
            self.code = code
        }
    }

    private struct Item {
        let code: String
        let words: [Substring]
        let emoji: String
        let alias: Bool
    }

    private let items: [Item]
    private let byCode: [String: String]

    /// `names`: (emoji, name) in catalog order (that order breaks ties).
    public init(names: [(emoji: String, name: String)], aliases: [(String, String)] = EmojiShortcodeIndex.commonAliases) {
        var items: [Item] = []
        var byCode: [String: String] = [:]
        for (code, emoji) in aliases where byCode[code] == nil {
            items.append(Item(code: code, words: [Substring(code)], emoji: emoji, alias: true))
            byCode[code] = emoji
        }
        for (emoji, name) in names {
            let code = Self.code(for: name)
            guard !code.isEmpty else { continue }
            items.append(Item(code: code, words: code.split(separator: "_"), emoji: emoji, alias: false))
            if byCode[code] == nil { byCode[code] = emoji }
        }
        self.items = items
        self.byCode = byCode
    }

    /// "smiling face with open mouth" -> "smiling_face_with_open_mouth".
    public static func code(for name: String) -> String {
        var out = ""
        var gap = false
        for ch in name.lowercased() {
            if ch.isLetter || ch.isNumber {
                if gap && !out.isEmpty { out.append("_") }
                out.append(ch)
                gap = false
            } else {
                gap = true
            }
        }
        return out
    }

    public func emoji(forCode code: String) -> String? { byCode[code.lowercased()] }

    /// Best matches for the text typed after ":", one per emoji: exact code, then aliases starting with the query,
    /// then codes starting with it, then codes with a word starting with it, then codes containing it.
    public func search(_ query: String, limit: Int = 8) -> [Match] {
        let q = query.lowercased()
        guard !q.isEmpty else { return [] }
        var tiers: [[Match]] = Array(repeating: [], count: 5)
        var seen = Set<String>()
        // An exact code first (also when it is the name of an emoji listed later).
        if let e = byCode[q] {
            tiers[0].append(Match(emoji: e, code: q))
            seen.insert(e)
        }
        for it in items where !seen.contains(it.emoji) {
            let tier: Int
            if it.code.hasPrefix(q) { tier = it.alias ? 1 : 2 }
            else if it.words.contains(where: { $0.hasPrefix(q) }) { tier = 3 }
            else if q.count >= 3 && it.code.contains(q) { tier = 4 }
            else { continue }
            tiers[tier].append(Match(emoji: it.emoji, code: it.code))
            seen.insert(it.emoji)
            if tier <= 1 && tiers[0].count + tiers[1].count >= limit { break }
        }
        return Array(tiers.joined().prefix(limit))
    }

    /// Short names in common use, most wanted first (they rank above the long names).
    public static let commonAliases: [(String, String)] = [
        ("smile", "😄"), ("smiley", "😃"), ("grinning", "😀"), ("grin", "😁"), ("laughing", "😆"), ("joy", "😂"),
        ("rofl", "🤣"), ("sweat_smile", "😅"), ("slightly_smiling_face", "🙂"), ("upside_down", "🙃"), ("wink", "😉"),
        ("blush", "😊"), ("innocent", "😇"), ("heart_eyes", "😍"), ("star_struck", "🤩"), ("kissing_heart", "😘"),
        ("yum", "😋"), ("stuck_out_tongue", "😛"), ("zany", "🤪"), ("hugs", "🤗"), ("thinking", "🤔"),
        ("shush", "🤫"), ("neutral_face", "😐"), ("expressionless", "😑"), ("no_mouth", "😶"), ("smirk", "😏"),
        ("unamused", "😒"), ("roll_eyes", "🙄"), ("grimacing", "😬"), ("relieved", "😌"), ("pensive", "😔"),
        ("sleepy", "😪"), ("sleeping", "😴"), ("mask", "😷"), ("nauseated", "🤢"), ("vomit", "🤮"), ("hot", "🥵"),
        ("cold", "🥶"), ("dizzy_face", "😵"), ("exploding_head", "🤯"), ("cowboy", "🤠"), ("partying", "🥳"),
        ("party", "🥳"), ("sunglasses", "😎"), ("nerd", "🤓"), ("confused", "😕"), ("worried", "😟"),
        ("frowning", "🙁"), ("open_mouth", "😮"), ("astonished", "😲"), ("flushed", "😳"), ("pleading", "🥺"),
        ("fearful", "😨"), ("cold_sweat", "😰"), ("cry", "😢"), ("sob", "😭"), ("scream", "😱"), ("confounded", "😖"),
        ("disappointed", "😞"), ("sweat", "😓"), ("weary", "😩"), ("tired_face", "😫"), ("yawning", "🥱"),
        ("triumph", "😤"), ("rage", "😡"), ("angry", "😠"), ("cursing", "🤬"), ("smiling_imp", "😈"), ("skull", "💀"),
        ("poop", "💩"), ("clown", "🤡"), ("ghost", "👻"), ("alien", "👽"), ("robot", "🤖"), ("see_no_evil", "🙈"),
        ("hear_no_evil", "🙉"), ("speak_no_evil", "🙊"), ("heart", "❤️"), ("orange_heart", "🧡"),
        ("yellow_heart", "💛"), ("green_heart", "💚"), ("blue_heart", "💙"), ("purple_heart", "💜"),
        ("black_heart", "🖤"), ("white_heart", "🤍"), ("broken_heart", "💔"), ("two_hearts", "💕"),
        ("sparkling_heart", "💖"), ("100", "💯"), ("boom", "💥"), ("collision", "💥"), ("zzz", "💤"),
        ("wave", "👋"), ("raised_hand", "✋"), ("ok_hand", "👌"), ("pinched_fingers", "🤌"), ("v", "✌️"),
        ("crossed_fingers", "🤞"), ("love_you", "🤟"), ("metal", "🤘"), ("call_me", "🤙"), ("point_left", "👈"),
        ("point_right", "👉"), ("point_up", "☝️"), ("point_down", "👇"), ("middle_finger", "🖕"), ("+1", "👍"),
        ("thumbsup", "👍"), ("-1", "👎"), ("thumbsdown", "👎"), ("fist", "✊"), ("punch", "👊"), ("clap", "👏"),
        ("raised_hands", "🙌"), ("open_hands", "👐"), ("handshake", "🤝"), ("pray", "🙏"), ("muscle", "💪"),
        ("eyes", "👀"), ("brain", "🧠"), ("shrug", "🤷"), ("facepalm", "🤦"), ("ok_woman", "🙆"), ("bow", "🙇"),
        ("dog", "🐶"), ("cat", "🐱"), ("unicorn", "🦄"), ("monkey", "🐒"), ("pig", "🐷"), ("panda", "🐼"),
        ("bug", "🐛"), ("snake", "🐍"), ("turtle", "🐢"), ("rose", "🌹"), ("sunflower", "🌻"), ("tulip", "🌷"),
        ("seedling", "🌱"), ("christmas_tree", "🎄"), ("sun", "☀️"), ("sunny", "☀️"), ("cloud", "☁️"),
        ("rainbow", "🌈"), ("snowflake", "❄️"), ("zap", "⚡"), ("fire", "🔥"), ("droplet", "💧"), ("star", "⭐"),
        ("star2", "🌟"), ("sparkles", "✨"), ("moon", "🌙"), ("earth", "🌍"), ("apple", "🍎"), ("banana", "🍌"),
        ("avocado", "🥑"), ("pizza", "🍕"), ("hamburger", "🍔"), ("fries", "🍟"), ("taco", "🌮"), ("cake", "🍰"),
        ("birthday", "🎂"), ("cookie", "🍪"), ("chocolate", "🍫"), ("coffee", "☕"), ("tea", "🍵"), ("beer", "🍺"),
        ("beers", "🍻"), ("wine", "🍷"), ("cocktail", "🍸"), ("champagne", "🍾"), ("clinking_glasses", "🥂"),
        ("tada", "🎉"), ("confetti_ball", "🎊"), ("balloon", "🎈"), ("gift", "🎁"), ("trophy", "🏆"),
        ("medal", "🏅"), ("soccer", "⚽"), ("basketball", "🏀"), ("football", "🏈"), ("tennis", "🎾"),
        ("video_game", "🎮"), ("dart", "🎯"), ("musical_note", "🎵"), ("notes", "🎶"), ("guitar", "🎸"),
        ("car", "🚗"), ("taxi", "🚕"), ("bus", "🚌"), ("bike", "🚲"), ("airplane", "✈️"), ("rocket", "🚀"),
        ("house", "🏠"), ("office", "🏢"), ("hourglass", "⌛"), ("watch", "⌚"), ("alarm_clock", "⏰"),
        ("phone", "📱"), ("iphone", "📱"), ("computer", "💻"), ("camera", "📷"), ("tv", "📺"), ("bulb", "💡"),
        ("moneybag", "💰"), ("money", "💵"), ("credit_card", "💳"), ("gem", "💎"), ("wrench", "🔧"),
        ("hammer", "🔨"), ("gear", "⚙️"), ("lock", "🔒"), ("unlock", "🔓"), ("key", "🔑"), ("bell", "🔔"),
        ("book", "📖"), ("memo", "📝"), ("pencil", "✏️"), ("pushpin", "📌"), ("paperclip", "📎"),
        ("calendar", "📅"), ("email", "📧"), ("envelope", "✉️"), ("package", "📦"), ("pill", "💊"),
        ("warning", "⚠️"), ("no_entry", "⛔"), ("x", "❌"), ("heavy_check_mark", "✔️"),
        ("white_check_mark", "✅"), ("check", "✅"), ("question", "❓"), ("exclamation", "❗"), ("bangbang", "‼️"),
        ("recycle", "♻️"), ("arrow_right", "➡️"), ("arrow_left", "⬅️"), ("arrow_up", "⬆️"), ("arrow_down", "⬇️"),
        ("new", "🆕"), ("ok", "🆗"), ("sos", "🆘"), ("red_circle", "🔴"), ("green_circle", "🟢"),
        ("checkered_flag", "🏁"), ("rainbow_flag", "🏳️‍🌈"), ("pirate_flag", "🏴‍☠️"),
    ]
}

/// Skin tones of emoji (Fitzpatrick modifiers U+1F3FB…U+1F3FF); tone 0 is the yellow default.
public enum EmojiSkinTone {
    public static let modifiers: [Unicode.Scalar] = [
        "\u{1F3FB}", "\u{1F3FC}", "\u{1F3FD}", "\u{1F3FE}", "\u{1F3FF}",
    ]

    /// The variant of an emoji in `tone` (1…5) from its catalog `variants` (5 single tones, or 25 for emoji
    /// with two people: the one with both people in the tone is used). The emoji itself when there is none.
    public static func apply(_ tone: Int, to emoji: String, variants: [String]) -> String {
        guard tone >= 1, tone <= modifiers.count, !variants.isEmpty else { return emoji }
        let wanted = modifiers[tone - 1]
        let isModifier: (Unicode.Scalar) -> Bool = { modifiers.contains($0) }
        return variants.first { v in
            let mods = v.unicodeScalars.filter(isModifier)
            return !mods.isEmpty && mods.allSatisfy { $0 == wanted }
        } ?? emoji
    }
}

/// The ":query" before the caret: a colon at the start or after whitespace / an opening bracket, then at least
/// two code characters. Offsets are UTF-16 units (NSTextView ranges); `range` covers the colon and the query.
public func emojiShortcodeQuery(text: String, caret: Int) -> (range: NSRange, query: String)? {
    let u = Array(text.utf16)
    guard caret > 0, caret <= u.count else { return nil }
    var i = caret
    while i > 0, isCodeUnit(u[i - 1]), caret - i < 40 { i -= 1 }
    let length = caret - i
    guard length >= 2, i > 0, u[i - 1] == 0x3A /* : */ else { return nil }
    if i >= 2, !isBoundary(u[i - 2]) { return nil }
    let query = String(decoding: u[i..<caret], as: UTF16.self)
    // "::" or a query of only punctuation ("+-") is not a code being typed.
    guard query.contains(where: { $0.isLetter || $0.isNumber }) else { return nil }
    return (NSRange(location: i - 1, length: length + 1), query)
}

/// A complete ":code:" ending at the caret (the user typed the closing colon), for replacing it right away.
public func emojiShortcodeCompleted(text: String, caret: Int) -> (range: NSRange, code: String)? {
    let u = Array(text.utf16)
    guard caret >= 4, caret <= u.count, u[caret - 1] == 0x3A else { return nil }
    guard let q = emojiShortcodeQuery(text: String(decoding: u[0..<(caret - 1)], as: UTF16.self), caret: caret - 1) else { return nil }
    return (NSRange(location: q.range.location, length: q.range.length + 1), q.query)
}

private func isCodeUnit(_ c: UInt16) -> Bool {
    (c >= 0x61 && c <= 0x7A) || (c >= 0x41 && c <= 0x5A) || (c >= 0x30 && c <= 0x39) || c == 0x5F || c == 0x2B || c == 0x2D
}

private func isBoundary(_ c: UInt16) -> Bool {
    c == 0x20 || c == 0x0A || c == 0x09 || c == 0x28 || c == 0x5B || c == 0x7B || c == 0xA0
}
