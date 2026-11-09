import Foundation

/// A Signal group invite link: https://signal.group/#<URL-safe base64 of the invite> (also sgnl://signal.group/#…).
/// signal-cli's `joinGroup --uri` takes the https form. Nothing about the group can be read from the link
/// without the server, so the app shows the link itself when asking whether to join.
public struct GroupInviteLink: Equatable, Identifiable {
    /// Always the https form.
    public let url: String

    public var id: String { url }

    /// The part after "#".
    public var code: String { String(url.dropFirst(Self.prefix.count)) }

    static let prefix = "https://signal.group/#"

    public static func parse(_ text: String) -> GroupInviteLink? {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = t.lowercased()
        let starts = ["https://signal.group", "http://signal.group", "sgnl://signal.group"]
        guard let start = starts.first(where: { lower.hasPrefix($0) }), let hash = t.firstIndex(of: "#") else { return nil }
        // Only "/" or nothing between the host and "#".
        let hostEnd = t.index(t.startIndex, offsetBy: start.count)
        guard hostEnd <= hash else { return nil }
        let path = t[hostEnd..<hash]
        guard path.isEmpty || path == "/" else { return nil }
        let code = t[t.index(after: hash)...]
        // The invite is a protobuf with a 32-byte master key and a password: never shorter than ~40 characters.
        guard code.count >= 40, code.count <= 512, code.allSatisfy(isBase64URL) else { return nil }
        return GroupInviteLink(url: prefix + code)
    }

    /// The first group link in `text` (a whole message, for example).
    public static func find(in text: String) -> GroupInviteLink? {
        if let l = parse(text) { return l }
        for word in text.split(whereSeparator: { $0.isWhitespace || "<>\"'()[]".contains($0) }) {
            if let l = parse(String(word)) { return l }
        }
        return nil
    }

    private static func isBase64URL(_ c: Character) -> Bool {
        c.isASCII && (c.isLetter || c.isNumber || c == "-" || c == "_" || c == "=" || c == "+" || c == "/")
    }

    init(url: String) { self.url = url }
}

/// Result of `joinGroup`: `{"groupId", "onlyRequested", "timestamp", "results"}`.
public struct GroupJoinResult: Equatable {
    public var groupId = ""
    /// The link needs an admin's approval: we asked to join and are not a member yet.
    public var onlyRequested = false

    public init(groupId: String = "", onlyRequested: Bool = false) {
        self.groupId = groupId
        self.onlyRequested = onlyRequested
    }

    public init(json: Any?) {
        let o = jsonObject(json)
        self.init(groupId: jsonString(o["groupId"]), onlyRequested: jsonBool(o["onlyRequested"]))
    }
}
