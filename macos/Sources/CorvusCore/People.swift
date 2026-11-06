import Foundation

/// How people are named and listed in the info panel and member lists: raw service ids (UUIDs) are
/// never shown when anything better is known.
public enum People {
    /// Name of someone known only by a service id.
    public static let unknown = "Unknown"

    /// A Signal service id ("ACI"/"PNI" UUID, optionally with a "PNI:" prefix).
    public static func isServiceId(_ s: String) -> Bool {
        var t = Substring(s)
        if let colon = t.firstIndex(of: ":"), t[..<colon].allSatisfy(\.isLetter) { t = t[t.index(after: colon)...] }
        return UUID(uuidString: String(t)) != nil
    }

    /// "+" and digits: an E.164 phone number.
    public static func isPhoneNumber(_ s: String) -> Bool {
        s.count >= 4 && s.hasPrefix("+") && s.dropFirst().allSatisfy(\.isNumber)
    }

    /// The first usable name: names that are themselves service ids are skipped; then the phone number;
    /// a person known only by a service id is `unknown`.
    public static func displayName(names: [String], number: String = "", unknown: String = People.unknown) -> String {
        for n in names {
            let t = n.trimmingCharacters(in: .whitespacesAndNewlines)
            if !t.isEmpty && !isServiceId(t) { return t }
        }
        return number.isEmpty || isServiceId(number) ? unknown : number
    }

    /// Second line under a name: the phone number or username, unless the name already shows it or it
    /// is a service id.
    public static func detail(title: String, address: String) -> String {
        address.isEmpty || address == title || isServiceId(address) ? "" : address
    }

    /// Member order: you first, then admins, then everybody by name (A–Z, numbers and "Unknown" after
    /// real names), ties broken by id so the order is stable.
    public static func sortedMembers(_ members: [GroupMember], isSelf: (GroupMember) -> Bool,
                                     name: (GroupMember) -> String) -> [GroupMember] {
        let keyed = members.map { m -> (m: GroupMember, rank: Int, named: Bool, name: String) in
            let n = name(m)
            let named = !(isPhoneNumber(n) || isServiceId(n) || n == unknown)
            return (m, isSelf(m) ? 0 : (m.isAdmin ? 1 : 2), named, n)
        }
        return keyed.sorted { a, b in
            if a.rank != b.rank { return a.rank < b.rank }
            if a.named != b.named { return a.named }
            let c = a.name.localizedStandardCompare(b.name)
            if c != .orderedSame { return c == .orderedAscending }
            return a.m.id < b.m.id
        }.map(\.m)
    }

    /// Whether a person matches the filter text: name or detail, or (3+ digits) the phone number.
    public static func matches(_ query: String, name: String, detail: String, number: String = "") -> Bool {
        let q = query.trimmingCharacters(in: .whitespaces)
        if q.isEmpty { return true }
        if name.localizedStandardContains(q) || (!detail.isEmpty && detail.localizedCaseInsensitiveContains(q)) { return true }
        let digits = q.filter(\.isNumber)
        return digits.count >= 3 && number.filter(\.isNumber).contains(digits)
    }

    /// Member lists get a filter field from this size on.
    public static let filterThreshold = 10
}
