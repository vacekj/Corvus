import Foundation

/// A Signal link preview attached to a message (same fields as `LinkPreview` in src/Model.h).
/// Only the sender's data is ever shown for incoming previews: nothing here triggers a network request.
public struct LinkPreview: Equatable, Hashable {
    public var url = ""                // https URL the preview stands for
    public var title = ""
    public var description = ""
    public var imageId = ""            // signal-cli attachment id of an incoming preview image
    public var imageContentType = ""
    public var imageFilename = ""
    public var imageSize: Int64 = 0
    public var imageThumb = Data()     // small image kept in the encrypted history

    public init() {}

    /// Like the Qt app: an https URL with a host and a non-empty title.
    public var isValid: Bool {
        guard let u = LinkPreviews.parse(url), u.scheme?.lowercased() == "https", !(u.host ?? "").isEmpty else { return false }
        return !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    public var host: String { LinkPreviews.parse(url)?.host ?? "" }

    /// The URL to open when the preview is clicked: http(s) only.
    public var openURL: URL? {
        guard let u = LinkPreviews.parse(url), ["http", "https"].contains(u.scheme?.lowercased() ?? "") else { return nil }
        return u
    }
}

/// Title, description and image URL found in the `<head>` of a page.
public struct PageMetadata: Equatable {
    public var title = ""
    public var description = ""
    public var imageURL = ""
    public init(title: String = "", description: String = "", imageURL: String = "") {
        self.title = title
        self.description = description
        self.imageURL = imageURL
    }
}

/// Pure helpers for generating link previews when sending (port of the static helpers in src/MainWindow.cpp).
public enum LinkPreviews {
    public static let maxPageBytes = 1024 * 1024
    public static let maxImageBytes = 5 * 1024 * 1024
    public static let maxRedirects = 5
    public static let maxTitle = 240
    public static let maxDescription = 280

    /// Parses a URL strictly enough for previews: no whitespace or control characters.
    static func parse(_ s: String) -> URL? {
        guard !s.isEmpty, !s.contains(where: { $0.isWhitespace || $0.isNewline || $0.unicodeScalars.contains { $0.value < 0x20 } }) else { return nil }
        return URL(string: s)
    }

    private static let linkRegex = try! NSRegularExpression(pattern: #"https://[^\s<>"']+"#, options: .caseInsensitive)

    /// The first https link of `text`, with the spelling of the message body (signal-cli requires the
    /// preview URL to occur in the body, so it must not be normalised).
    public static func firstHttpsLink(in text: String) -> String? {
        let ns = text as NSString
        guard let m = linkRegex.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)) else { return nil }
        var c = ns.substring(with: m.range)
        func count(_ ch: Character) -> Int { c.filter { $0 == ch }.count }
        while let last = c.last {
            if ".,!?;:".contains(last) { c.removeLast(); continue }
            // Only unmatched closing brackets are punctuation; parentheses inside URLs are legal.
            if last == ")" && count(")") > count("(") { c.removeLast(); continue }
            if last == "]" && count("]") > count("[") { c.removeLast(); continue }
            break
        }
        guard let u = parse(c), u.scheme?.lowercased() == "https", !(u.host ?? "").isEmpty else { return nil }
        return c
    }

    /// Whether the app may fetch this URL for a preview: https, a public-looking host name (no IP literal,
    /// no local / internal names) and no credentials in the URL.
    public static func isSafeToFetch(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "https", let host = url.host?.lowercased(), !host.isEmpty,
              url.user == nil, url.password == nil else { return false }
        if host == "localhost" || [".localhost", ".local", ".internal", ".test"].contains(where: host.hasSuffix) { return false }
        if !host.contains(".") { return false }
        var v4 = in_addr(), v6 = in6_addr()
        let bare = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        if inet_pton(AF_INET, bare, &v4) == 1 || inet_pton(AF_INET6, bare, &v6) == 1 { return false }
        return true
    }

    // MARK: HTML

    private static let entities: [String: String] = [
        "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": " ", "copy": "©", "reg": "®",
        "trade": "™", "mdash": "—", "ndash": "–", "hellip": "…", "laquo": "«", "raquo": "»", "lsquo": "‘",
        "rsquo": "’", "ldquo": "“", "rdquo": "”", "bull": "•", "middot": "·", "euro": "€", "pound": "£",
    ]

    /// Decodes character references and collapses whitespace (like `QString::simplified`).
    public static func htmlUnescape(_ s: String) -> String {
        var out = ""
        var i = s.startIndex
        while i < s.endIndex {
            let ch = s[i]
            if ch == "&", let semi = s[i...].prefix(12).firstIndex(of: ";") {
                let name = String(s[s.index(after: i)..<semi])
                var replacement: String?
                if name.hasPrefix("#") {
                    let digits = name.dropFirst()
                    let value = digits.lowercased().hasPrefix("x") ? UInt32(digits.dropFirst(), radix: 16) : UInt32(digits, radix: 10)
                    if let value, let scalar = Unicode.Scalar(value) { replacement = String(Character(scalar)) }
                } else {
                    replacement = entities[name.lowercased()]
                }
                if let replacement {
                    out += replacement
                    i = s.index(after: semi)
                    continue
                }
            }
            out.append(ch)
            i = s.index(after: i)
        }
        return out.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).joined(separator: " ")
    }

    private static let metaRegex = try! NSRegularExpression(pattern: #"<meta\b[^>]*>"#, options: .caseInsensitive)
    private static let attrRegex = try! NSRegularExpression(
        pattern: #"([A-Za-z_:][-A-Za-z0-9_:.]*)\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s"'>]+))"#)
    private static let titleRegex = try! NSRegularExpression(
        pattern: #"<title\b[^>]*>(.*?)</title\s*>"#, options: [.caseInsensitive, .dotMatchesLineSeparators])

    private static func attributes(of tag: String) -> [String: String] {
        let ns = tag as NSString
        var result: [String: String] = [:]
        for m in attrRegex.matches(in: tag, range: NSRange(location: 0, length: ns.length)) {
            let name = ns.substring(with: m.range(at: 1)).lowercased()
            for g in 2...4 where m.range(at: g).location != NSNotFound {
                if result[name] == nil { result[name] = htmlUnescape(ns.substring(with: m.range(at: g))) }
                break
            }
        }
        return result
    }

    /// OpenGraph / Twitter card / plain HTML metadata, with the same fallbacks and limits as the Qt app.
    public static func parseMetadata(html: String) -> PageMetadata {
        let ns = html as NSString
        let tags = metaRegex.matches(in: html, range: NSRange(location: 0, length: ns.length))
            .map { attributes(of: ns.substring(with: $0.range)) }
        func meta(_ wanted: [String]) -> String {
            for want in wanted {
                for t in tags where t["property"]?.lowercased() == want || t["name"]?.lowercased() == want {
                    let v = (t["content"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                    if !v.isEmpty { return String(v.prefix(1000)) }
                }
            }
            return ""
        }
        var out = PageMetadata()
        out.title = meta(["og:title", "twitter:title"])
        if out.title.isEmpty,
           let m = titleRegex.firstMatch(in: html, range: NSRange(location: 0, length: ns.length)) {
            out.title = htmlUnescape(ns.substring(with: m.range(at: 1)))
        }
        out.title = String(out.title.prefix(maxTitle)).trimmingCharacters(in: .whitespacesAndNewlines)
        out.description = String(meta(["og:description", "description", "twitter:description"]).prefix(maxDescription))
        out.imageURL = meta(["og:image", "og:image:url", "twitter:image"])
        return out
    }

    /// Image URL of the metadata resolved against the page URL.
    public static func resolveImageURL(_ value: String, base: URL) -> URL? {
        guard let rel = parse(value) else { return nil }
        return URL(string: rel.absoluteString, relativeTo: base)?.absoluteURL
    }

    public static func imageSuffix(forContentType contentType: String) -> String? {
        switch contentType.split(separator: ";").first.map({ $0.trimmingCharacters(in: .whitespaces).lowercased() }) {
        case "image/jpeg", "image/jpg": return "jpg"
        case "image/png": return "png"
        case "image/webp": return "webp"
        case "image/gif": return "gif"
        default: return nil
        }
    }

    // MARK: signal-cli

    /// `send` parameters of a preview (signal-cli 0.14 JSON-RPC, camelCase of --preview-url, --preview-title,
    /// --preview-description and --preview-image). The URL must also occur in the message body.
    public static func sendParams(_ lp: LinkPreview, imagePath: String?) -> JSON {
        var p: JSON = ["previewUrl": lp.url, "previewTitle": lp.title]
        if !lp.description.isEmpty { p["previewDescription"] = lp.description }
        if let imagePath, !imagePath.isEmpty { p["previewImage"] = imagePath }
        return p
    }
}
