import Foundation

// Message content that is not a plain text body: shared contact cards, payment notifications, shared
// locations, long texts (sent as an attachment) and chat notices.

/// A contact card ("Share contact"). signal-cli: dataMessage.contacts[] with `name` {given, family, middle,
/// prefix, suffix, nickname}, `avatar` {attachment, isProfile}, `phone`/`email` [{value, type, label}],
/// `address` [{type, label, street, pobox, neighborhood, city, region, postcode, country}] and `organization`.
/// The history stores the same shape (`json`), so one parser reads both.
public struct SharedContact: Equatable, Hashable {
    public struct Field: Equatable, Hashable {
        public var value = ""
        public var type = ""      // HOME, MOBILE, WORK, CUSTOM
        public var label = ""     // custom label
        public init(value: String = "", type: String = "", label: String = "") {
            self.value = value
            self.type = type
            self.label = label
        }

        /// "Mobile", "Work", the custom label, …
        public var typeLabel: String {
            if !label.isEmpty { return label }
            switch type.uppercased() {
            case "HOME": return "Home"
            case "MOBILE": return "Mobile"
            case "WORK": return "Work"
            default: return ""
            }
        }
    }

    public var given = ""
    public var family = ""
    public var middle = ""
    public var prefix = ""
    public var suffix = ""
    public var nickname = ""
    public var organization = ""
    public var phones: [Field] = []
    public var emails: [Field] = []
    public var addresses: [String] = []      // one line each
    public var avatarId = ""                 // signal-cli attachment id of the contact's picture

    public init() {}

    public var displayName: String {
        let full = [prefix, given, middle, family, suffix].filter { !$0.isEmpty }.joined(separator: " ")
        if !full.isEmpty { return full }
        if !nickname.isEmpty { return nickname }
        if !organization.isEmpty { return organization }
        return phones.first?.value ?? emails.first?.value ?? ""
    }

    public var isEmpty: Bool { displayName.isEmpty }

    /// The first phone number in a form signal-cli accepts as a recipient ("+420 777-123 456" -> "+420777123456"),
    /// nil when there is no international number.
    public var signalNumber: String? {
        for p in phones {
            let digits = p.value.filter { $0.isNumber || $0 == "+" }
            if digits.hasPrefix("+"), digits.dropFirst().allSatisfy(\.isNumber), digits.count >= 8 { return digits }
            if digits.hasPrefix("00"), digits.count >= 9, digits.allSatisfy(\.isNumber) { return "+" + digits.dropFirst(2) }
        }
        return nil
    }

    public static func parse(_ o: JSON) -> SharedContact {
        var c = SharedContact()
        let n = jsonObject(o["name"])
        c.given = jsonString(n["given"])
        c.family = jsonString(n["family"])
        c.middle = jsonString(n["middle"])
        c.prefix = jsonString(n["prefix"])
        c.suffix = jsonString(n["suffix"])
        c.nickname = jsonString(n["nickname"])
        if c.nickname.isEmpty { c.nickname = jsonString(n["display"]) }
        c.organization = jsonString(o["organization"])
        func fields(_ v: Any?) -> [Field] {
            jsonArray(v).compactMap { e in
                let f = jsonObject(e)
                let value = jsonString(f["value"]).trimmingCharacters(in: .whitespacesAndNewlines)
                return value.isEmpty ? nil : Field(value: value, type: jsonString(f["type"]), label: jsonString(f["label"]))
            }
        }
        c.phones = fields(o["phone"])
        c.emails = fields(o["email"])
        c.addresses = jsonArray(o["address"]).compactMap { e in
            if let s = e as? String { return s.isEmpty ? nil : s }
            let a = jsonObject(e)
            let line = ["street", "pobox", "neighborhood", "postcode", "city", "region", "country"]
                .map { jsonString(a[$0]).trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .joined(separator: ", ")
            return line.isEmpty ? nil : line
        }
        c.avatarId = jsonString(jsonObject(jsonObject(o["avatar"])["attachment"])["id"])
        return c
    }

    /// The record form (same keys as signal-cli; addresses already joined to one line).
    public var json: JSON {
        var name: JSON = [:]
        for (k, v) in [("given", given), ("family", family), ("middle", middle), ("prefix", prefix),
                       ("suffix", suffix), ("nickname", nickname)] where !v.isEmpty { name[k] = v }
        var o: JSON = [:]
        if !name.isEmpty { o["name"] = name }
        if !organization.isEmpty { o["organization"] = organization }
        func fields(_ list: [Field]) -> [JSON] {
            list.map { f in
                var e: JSON = ["value": f.value]
                if !f.type.isEmpty { e["type"] = f.type }
                if !f.label.isEmpty { e["label"] = f.label }
                return e
            }
        }
        if !phones.isEmpty { o["phone"] = fields(phones) }
        if !emails.isEmpty { o["email"] = fields(emails) }
        if !addresses.isEmpty { o["address"] = addresses }
        if !avatarId.isEmpty { o["avatar"] = ["attachment": ["id": avatarId] as JSON] as JSON }
        return o
    }
}

/// A MobileCoin payment notification (signal-cli: dataMessage.payment {note, receipt}). The amount is only in
/// the encrypted receipt, which needs a wallet: like Signal Desktop, only the note and a notice are shown.
public struct PaymentNote: Equatable, Hashable {
    public var note = ""
    public init(note: String = "") { self.note = note }
}

/// A chat event shown as a centred note.
public struct MessageNotice: Equatable, Hashable {
    public enum Kind: String { case none = "", timer = "timer" }
    public var kind = Kind.none
    public var seconds = 0              // .timer: the new disappearing-message timer (0 = off)

    public init(kind: Kind = .none, seconds: Int = 0) {
        self.kind = kind
        self.seconds = seconds
    }

    public static func timer(_ seconds: Int) -> MessageNotice { MessageNotice(kind: .timer, seconds: max(0, seconds)) }

    var json: JSON { ["k": kind.rawValue, "v": seconds] }

    static func parse(_ o: JSON) -> MessageNotice {
        MessageNotice(kind: Kind(rawValue: jsonString(o["k"])) ?? .none, seconds: jsonInt(o["v"]))
    }
}

public extension Message {
    var isNotice: Bool { notice.kind != .none }

    /// The text is only a fallback line (for the chat list, notifications and the Qt app); the bubble shows
    /// the contact cards / the payment instead.
    var textIsFallback: Bool { !sharedContacts.isEmpty || payment != nil }

    /// The attachment with the full text of a long message, until it has been merged into `text`.
    var longTextAttachmentIndex: Int? { attachments.firstIndex(where: \.isLongText) }
}

public extension Attachment {
    /// Signal sends texts over 2000 bytes truncated in the body plus the whole text as this attachment.
    static let longTextType = "text/x-signal-plain"
    var isLongText: Bool { contentType.caseInsensitiveCompare(Attachment.longTextType) == .orderedSame }
}

public enum MessageFallback {
    public static func contact(_ contacts: [SharedContact]) -> String {
        let name = contacts.first?.displayName ?? ""
        return "👤 " + (name.isEmpty ? "Contact" : name)
    }

    public static func payment(_ p: PaymentNote) -> String {
        p.note.isEmpty ? "💸 Payment" : "💸 Payment: " + p.note
    }
}

/// Long messages: the full text from the attachment, joined to the body already shown.
public enum LongText {
    /// Texts longer than this many characters are shown shortened, with "Read more" (Signal Desktop: 800 / +3000).
    public static let initialLength = 800
    public static let increment = 3000
    /// Shorter texts are always shown whole (cutting off a few characters helps nobody).
    public static let threshold = 1000

    /// The full text for a message whose body is `displayed` (mention placeholders already replaced by
    /// "@Name", see `mentions`). `full` is the attachment text, which starts with the original body.
    public static func merge(displayed: String, mentions: [MentionRange], full: String) -> String {
        let fullText = full.replacingOccurrences(of: "\r\n", with: "\n")
        if mentions.isEmpty {
            return fullText.hasPrefix(displayed) || displayed.isEmpty ? fullText : displayed + tail(of: fullText, after: displayed.utf16.count)
        }
        // The original body had one placeholder per mention where `displayed` has "@Name".
        let rawLength = displayed.utf16.count - mentions.reduce(0) { $0 + $1.length } + mentions.count
        return displayed + tail(of: fullText, after: rawLength)
    }

    private static func tail(of full: String, after utf16Offset: Int) -> String {
        let u = full.utf16
        guard utf16Offset >= 0, utf16Offset < u.count else { return "" }
        let start = u.index(u.startIndex, offsetBy: utf16Offset)
        let s = String(decoding: Array(u[start...]), as: UTF16.self)
        return s.replacingOccurrences(of: "\u{FFFC}", with: "@…") // mentions past the body: names unknown
    }

    /// Where to cut a text for the shortened view: at most `limit` characters, at a word boundary when there is
    /// one in the last fifth. nil when the text is short enough to show whole.
    public static func cut(_ text: String, limit: Int) -> String.Index? {
        guard text.utf16.count > max(limit, threshold), text.count > max(limit, threshold) else { return nil }
        let hard = text.index(text.startIndex, offsetBy: limit)
        let floor = text.index(text.startIndex, offsetBy: limit * 4 / 5)
        if let space = text[floor..<hard].lastIndex(where: { $0.isWhitespace }) { return space }
        return hard
    }
}

/// A location shared from Signal for Android/iOS: the text is "[name\n][address\n]https://maps.google.com/maps?q=LAT%2CLON"
/// and a map picture comes as an attachment.
public struct LocationShare: Equatable {
    public var latitude: Double
    public var longitude: Double
    public var title: String           // place name or address (may be empty)
    public var address: String

    public static func parse(_ text: String) -> LocationShare? {
        guard text.contains("maps.google.com/maps?q=") else { return nil } // quick rejection for every other message
        let lines = text.split(separator: "\n", omittingEmptySubsequences: true).map { $0.trimmingCharacters(in: .whitespaces) }
        guard let last = lines.last, lines.count <= 4,
              last.hasPrefix("https://maps.google.com/maps?q=") || last.hasPrefix("http://maps.google.com/maps?q="),
              let comps = URLComponents(string: last),
              let q = comps.queryItems?.first(where: { $0.name == "q" })?.value else { return nil }
        let parts = q.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        guard parts.count == 2, let lat = Double(parts[0]), let lon = Double(parts[1]),
              (-90...90).contains(lat), (-180...180).contains(lon) else { return nil }
        let info = Array(lines.dropLast())
        return LocationShare(latitude: lat, longitude: lon, title: info.first ?? "",
                             address: info.dropFirst().joined(separator: ", "))
    }

    /// Opens Apple Maps at the place.
    public var mapsURL: URL? {
        var c = URLComponents(string: "https://maps.apple.com/")!
        var items = [URLQueryItem(name: "ll", value: "\(latitude),\(longitude)")]
        items.append(URLQueryItem(name: "q", value: title.isEmpty ? "\(latitude),\(longitude)" : title))
        c.queryItems = items
        return c.url
    }

    public var coordinateText: String { String(format: "%.5f, %.5f", latitude, longitude) }
}

// MARK: - Envelope / record helpers

func parseSharedContacts(_ dm: JSON) -> [SharedContact] {
    jsonArray(dm["contacts"]).map { SharedContact.parse(jsonObject($0)) }.filter { !$0.isEmpty }
}

func parsePayment(_ dm: JSON) -> PaymentNote? {
    guard let p = dm["payment"] as? JSON else { return nil }
    return PaymentNote(note: jsonString(p["note"]))
}

extension Records {
    /// Extras of the content above ("sc" contacts, "py" payment, "nt" notice).
    static func contentExtras(_ m: Message, into d: inout JSON) {
        if m.deleted { return }
        if !m.sharedContacts.isEmpty { d["sc"] = m.sharedContacts.map(\.json) }
        if let p = m.payment { d["py"] = ["n": p.note] as JSON }
        if m.isNotice { d["nt"] = m.notice.json }
    }

    static func applyContentExtras(_ m: inout Message, _ d: JSON) {
        if d["sc"] != nil { m.sharedContacts = jsonArray(d["sc"]).map { SharedContact.parse(jsonObject($0)) } }
        if let p = d["py"] as? JSON { m.payment = PaymentNote(note: jsonString(p["n"])) }
        if let n = d["nt"] as? JSON { m.notice = MessageNotice.parse(n) }
    }

    /// The full text of a long message replaced the shortened body; the text attachment is dropped.
    /// An "update" record with "ed" (keeping the edit state) and "at".
    public static func longTextUpdate(_ conv: String, _ m: Message) -> JSON {
        var e: JSON = ["x": m.text, "et": m.editTs, "ec": m.editCount]
        if !m.textStyles.isEmpty { e["st"] = textStylesToJson(m.textStyles) }
        if !m.mentions.isEmpty { e["mn"] = mentionsToJson(m.mentions) }
        var rec = attachmentsUpdate(conv, m)
        var d = jsonObject(rec["d"])
        d["ed"] = e
        rec["d"] = d
        return rec
    }
}

public extension ChatState {
    /// Replaces the shortened body of a long message with the whole text. Returns the record to persist.
    mutating func applyLongText(_ key: String, ts: Int64, author: String, full: String) -> JSON? {
        guard let c = convs[key], let i = findMessage(c, ts: ts, authors: [author]),
              let ai = c.msgs[i].longTextAttachmentIndex, !c.msgs[i].deleted else { return nil }
        var m = c.msgs[i]
        if !full.isEmpty { m.text = LongText.merge(displayed: m.text, mentions: m.mentions, full: full) }
        m.attachments.remove(at: ai)
        convs[key]!.msgs[i] = m
        return Records.longTextUpdate(key, m)
    }
}
