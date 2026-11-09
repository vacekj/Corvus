import Foundation

/// The own Signal profile as signal-cli reports it: our entry in `listContacts` (JsonContact) carries the
/// username and, under `profile`, the given and family name, the about text and its emoji.
public struct OwnProfile: Equatable {
    public var givenName = ""
    public var familyName = ""
    public var about = ""
    public var aboutEmoji = ""
    public var username = ""
    public var hasAvatar = false

    public init(givenName: String = "", familyName: String = "", about: String = "", aboutEmoji: String = "",
                username: String = "", hasAvatar: Bool = false) {
        self.givenName = givenName
        self.familyName = familyName
        self.about = about
        self.aboutEmoji = aboutEmoji
        self.username = username
        self.hasAvatar = hasAvatar
    }

    public init(contact c: JSON) {
        let p = jsonObject(c["profile"])
        self.init(givenName: jsonString(p["givenName"]), familyName: jsonString(p["familyName"]),
                  about: jsonString(p["about"]), aboutEmoji: jsonString(p["aboutEmoji"]),
                  username: jsonString(c["username"]), hasAvatar: jsonBool(p["hasAvatar"]))
    }

    /// Our entry in a `listContacts` result (nil when signal-cli did not list it).
    public static func find(in result: Any?, account: String) -> OwnProfile? {
        guard !account.isEmpty else { return nil }
        return jsonArray(result).map(jsonObject)
            .first { jsonString($0["number"]) == account || jsonString($0["uuid"]) == account }
            .map(OwnProfile.init(contact:))
    }

    public var name: String {
        [givenName, familyName].filter { !$0.isEmpty }.joined(separator: " ")
    }

    /// "😀 Text", as Signal shows the about line.
    public var aboutLine: String {
        [aboutEmoji, about].filter { !$0.isEmpty }.joined(separator: " ")
    }
}

/// `updateProfile` parameters. signal-cli leaves out options unchanged, so only what differs is sent
/// (an empty string clears a field; the given name cannot be cleared).
public enum ProfileParams {
    public static func update(from before: OwnProfile, givenName: String, familyName: String,
                              about: String, aboutEmoji: String) -> JSON {
        func clean(_ s: String) -> String { s.trimmingCharacters(in: .whitespacesAndNewlines) }
        var p: JSON = [:]
        let given = clean(givenName), family = clean(familyName), text = clean(about), emoji = clean(aboutEmoji)
        if !given.isEmpty && given != before.givenName { p["givenName"] = given }
        if family != before.familyName { p["familyName"] = family }
        if text != before.about { p["about"] = text }
        if emoji != before.aboutEmoji { p["aboutEmoji"] = emoji }
        return p
    }

    public static func avatar(_ path: String) -> JSON { ["avatar": path] }
    public static let removeAvatar: JSON = ["removeAvatar": true]

    /// Applies sent parameters to the profile we show (optimistic update).
    public static func apply(_ params: JSON, to p: inout OwnProfile) {
        if let v = params["givenName"] as? String { p.givenName = v }
        if let v = params["familyName"] as? String { p.familyName = v }
        if let v = params["about"] as? String { p.about = v }
        if let v = params["aboutEmoji"] as? String { p.aboutEmoji = v }
    }
}

/// Signal usernames: a nickname of 3–32 characters (a–z, 0–9, "_", not starting with a digit) and a numeric
/// discriminator ("name.42"). signal-cli picks a free discriminator when only the nickname is given.
public enum Username {
    public static let minLength = 3
    public static let maxLength = 32

    /// Why `text` cannot be a username, or nil when it can.
    public static func problem(_ text: String) -> String? {
        let t = text.trimmingCharacters(in: .whitespaces)
        if t.isEmpty { return "Enter a username." }
        let parts = t.split(separator: ".", omittingEmptySubsequences: false)
        if parts.count > 2 { return "A username can contain only one dot." }
        let nick = String(parts[0])
        if nick.count < minLength { return "Usernames must have at least \(minLength) characters." }
        if nick.count > maxLength { return "Usernames can have at most \(maxLength) characters." }
        if nick.first?.isNumber == true { return "Usernames cannot begin with a number." }
        if !nick.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_") }) {
            return "Usernames can only include a–z, 0–9 and _."
        }
        if parts.count == 2 {
            let d = parts[1]
            if d.count < 2 || d.count > 9 || !d.allSatisfy({ $0.isASCII && $0.isNumber }) {
                return "The number after the dot must have 2 to 9 digits."
            }
            if d.allSatisfy({ $0 == "0" }) { return "The number after the dot cannot be 00." }
            if d.count > 2 && d.first == "0" { return "The number after the dot cannot start with 0." }
        }
        return nil
    }

    public static func set(_ name: String) -> JSON { ["username": name.trimmingCharacters(in: .whitespaces)] }
    public static let delete: JSON = ["deleteUsername": true]
}

/// Result of `updateAccount --username`: the username with its discriminator and the username link
/// (https://signal.me/#eu/…), which signal-cli reports only when the username is set.
public struct UsernameResult: Equatable {
    public var username = ""
    public var link = ""

    public init(username: String = "", link: String = "") {
        self.username = username
        self.link = link
    }

    public init(json: Any?) {
        let o = jsonObject(json)
        self.init(username: jsonString(o["username"]), link: jsonString(o["usernameLink"]))
    }
}

/// `updateContact` parameters for the Signal nickname and note of a person (synced to the other devices
/// through the storage service). Empty strings clear them.
public enum ContactParams {
    public static func nickname(recipient: String, given: String, family: String) -> JSON {
        ["recipient": recipient,
         "nickGivenName": given.trimmingCharacters(in: .whitespacesAndNewlines),
         "nickFamilyName": family.trimmingCharacters(in: .whitespacesAndNewlines)]
    }

    public static func note(recipient: String, note: String) -> JSON {
        ["recipient": recipient, "note": note.trimmingCharacters(in: .whitespacesAndNewlines)]
    }

    /// "given family", as the nickname is shown.
    public static func join(given: String, family: String) -> String {
        [given, family].map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
            .joined(separator: " ")
    }
}
