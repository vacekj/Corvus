import Foundation

/// Group data as reported by signal-cli `listGroups` (always detailed in JSON-RPC mode) and the
/// parameters of the commands that change a group (`updateGroup`, `quitGroup`, …).
/// Field names follow signal-cli's JsonGroup; the same shapes are handled by src/GroupInfo.cpp.

public struct GroupMember: Equatable, Hashable {
    public var number = ""
    public var uuid = ""
    public var isAdmin = false
    /// Member label (signal-cli 0.14.10+): a short text the member shows next to their name in this group.
    public var label = ""
    public var labelEmoji = ""

    public init(number: String = "", uuid: String = "", isAdmin: Bool = false, label: String = "", labelEmoji: String = "") {
        self.number = number
        self.uuid = uuid
        self.isAdmin = isAdmin
        self.label = label
        self.labelEmoji = labelEmoji
    }

    /// "🎸 Guitar", "Guitar", "🎸" or "" (no label).
    public var labelText: String {
        [labelEmoji, label].map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.joined(separator: " ")
    }

    /// The identifier signal-cli accepts as `member` (number if known, else UUID).
    public var id: String { number.isEmpty ? uuid : number }

    public func matches(_ who: String) -> Bool { !who.isEmpty && (number == who || uuid == who) }

    /// Members arrive as `{"number", "uuid", "isAdmin"}` objects (0.14) or as plain strings (older versions).
    static func parse(_ v: Any) -> GroupMember? {
        if let s = v as? String {
            if s.isEmpty { return nil }
            return s.hasPrefix("+") ? GroupMember(number: s) : GroupMember(uuid: s)
        }
        guard let o = v as? JSON else { return nil }
        let m = GroupMember(number: jsonString(o["number"]), uuid: jsonString(o["uuid"]), isAdmin: jsonBool(o["isAdmin"]),
                            label: jsonString(o["label"]), labelEmoji: jsonString(o["labelEmoji"]))
        return m.id.isEmpty ? nil : m
    }
}

public enum GroupPermission: String {
    case everyMember = "EVERY_MEMBER"
    case onlyAdmins = "ONLY_ADMINS"

    /// "ONLY_ADMINS", "only-admins" and "onlyAdmins" all mean the same.
    static func parse(_ v: Any?) -> GroupPermission {
        let s = jsonString(v).replacingOccurrences(of: "-", with: "_").uppercased()
        return s == "ONLY_ADMINS" || s == "ONLYADMINS" ? .onlyAdmins : .everyMember
    }

    /// The value `updateGroup --set-permission-…` takes.
    public var cliValue: String { self == .onlyAdmins ? "only-admins" : "every-member" }
}

/// The three group permissions an admin can change (`updateGroup --set-permission-…`).
public enum GroupPermissionKind: CaseIterable {
    case addMembers
    case editDetails
    case sendMessages

    /// JSON-RPC parameter (camelCase of the long option).
    public var param: String {
        switch self {
        case .addMembers: "setPermissionAddMember"
        case .editDetails: "setPermissionEditDetails"
        case .sendMessages: "setPermissionSendMessages"
        }
    }

    public func value(in g: GroupInfo) -> GroupPermission {
        switch self {
        case .addMembers: g.permAddMember
        case .editDetails: g.permEditDetails
        case .sendMessages: g.permSendMessage
        }
    }

    public func set(_ p: GroupPermission, in g: inout GroupInfo) {
        switch self {
        case .addMembers: g.permAddMember = p
        case .editDetails: g.permEditDetails = p
        case .sendMessages: g.permSendMessage = p
        }
    }
}

/// `link` parameter of `updateGroup`.
public enum GroupLinkState: String {
    case disabled
    case enabled
    case enabledWithApproval = "enabled-with-approval"
}

public struct GroupInfo: Equatable, Identifiable {
    public var id = ""                  // base64, as used in `groupId`
    public var name = ""
    public var description = ""
    public var isMember = true
    public var isBlocked = false
    public var isTerminated = false
    public var expiration = 0
    public var members: [GroupMember] = []
    public var pending: [GroupMember] = []      // invited, not joined yet
    public var requesting: [GroupMember] = []   // asked to join through the invite link
    public var banned: [GroupMember] = []
    public var permAddMember = GroupPermission.everyMember
    public var permEditDetails = GroupPermission.everyMember
    public var permSendMessage = GroupPermission.everyMember
    public var inviteLink = ""                  // empty: the link is disabled

    public init() {}

    /// The conversation key of this group.
    public var key: String { Self.key(forId: id) }
    public static func key(forId id: String) -> String { "g:" + id }

    public init(json g: JSON) {
        id = jsonString(g["id"])
        name = jsonString(g["name"])
        description = jsonString(g["description"])
        isMember = g["isMember"] == nil || jsonBool(g["isMember"])
        isBlocked = jsonBool(g["isBlocked"])
        isTerminated = jsonBool(g["isTerminated"])
        expiration = jsonInt(g["messageExpirationTime"])
        members = jsonArray(g["members"]).compactMap(GroupMember.parse)
        pending = jsonArray(g["pendingMembers"]).compactMap(GroupMember.parse).map { var m = $0; m.isAdmin = false; return m }
        requesting = jsonArray(g["requestingMembers"]).compactMap(GroupMember.parse).map { var m = $0; m.isAdmin = false; return m }
        banned = jsonArray(g["banned"]).compactMap(GroupMember.parse).map { var m = $0; m.isAdmin = false; return m }
        // Older signal-cli versions only list the admins separately.
        if members.allSatisfy({ !$0.isAdmin }) {
            for a in jsonArray(g["admins"]).compactMap(GroupMember.parse) {
                for i in members.indices where members[i].matches(a.number) || members[i].matches(a.uuid) { members[i].isAdmin = true }
            }
        }
        permAddMember = GroupPermission.parse(g["permissionAddMember"])
        permEditDetails = GroupPermission.parse(g["permissionEditDetails"])
        permSendMessage = GroupPermission.parse(g["permissionSendMessage"])
        inviteLink = jsonString(g["groupInviteLink"])
    }

    /// The groups of a `listGroups` result (entries without an id are dropped).
    public static func parseList(_ result: Any?) -> [GroupInfo] {
        jsonArray(result).map(jsonObject).map(GroupInfo.init(json:)).filter { !$0.id.isEmpty }
    }

    public func member(_ who: String) -> GroupMember? { members.first { $0.matches(who) } }
    public func isAdmin(_ who: String) -> Bool { member(who)?.isAdmin ?? false }
    public var adminCount: Int { members.filter(\.isAdmin).count }
    public var inviteLinkEnabled: Bool { !inviteLink.isEmpty }

    /// We were invited but have not joined (a group "message request").
    public func isInvitation(for who: String) -> Bool {
        !isMember && !isTerminated && pending.contains { $0.matches(who) }
    }

    /// Admins always may; everybody else only if the group allows it.
    public func canEditDetails(_ who: String) -> Bool {
        member(who) != nil && (isAdmin(who) || permEditDetails != .onlyAdmins)
    }

    public func canAddMembers(_ who: String) -> Bool {
        member(who) != nil && (isAdmin(who) || permAddMember != .onlyAdmins)
    }

    /// "Only admins can send messages" (announcement group): members who are not admins can only read.
    public var isAnnouncementOnly: Bool { permSendMessage == .onlyAdmins }

    public func canSendMessages(_ who: String) -> Bool {
        member(who) != nil && (isAdmin(who) || permSendMessage != .onlyAdmins)
    }

    /// Member labels by number and UUID (members without a label are left out).
    public var memberLabels: [String: String] {
        var out: [String: String] = [:]
        for m in members {
            let t = m.labelText
            if t.isEmpty { continue }
            if !m.number.isEmpty { out[m.number] = t }
            if !m.uuid.isEmpty { out[m.uuid] = t }
        }
        return out
    }

    /// Removing members, changing admins and the invite link need an admin.
    public func canAdminister(_ who: String) -> Bool { isAdmin(who) }

    /// signal-cli refuses to let the only admin leave a group that still has other members.
    public func needsSuccessor(leaving who: String) -> Bool {
        isAdmin(who) && adminCount == 1 && members.contains { !$0.matches(who) }
    }

    /// People who could take over when `who` leaves.
    public func successors(leaving who: String) -> [GroupMember] { members.filter { !$0.matches(who) } }
}

/// Parameters (camelCase, as signal-cli's JSON-RPC expects them) of the group commands.
/// Verified against signal-cli(1) of 0.14: `updateGroup` takes `groupId`, `name`, `description`, `avatar`, `member`,
/// `removeMember`, `admin`, `removeAdmin`, `ban`, `unban`, `link`, `resetLink`, `setPermissionAddMember`,
/// `setPermissionEditDetails`, `setPermissionSendMessages`, `memberLabel`, `memberLabelEmoji`;
/// `quitGroup` takes `groupId`, `delete`, `admin`; `joinGroup` takes `uri`.
public enum GroupParams {
    /// `updateGroup` without `groupId` creates a group; the caller is added automatically.
    public static func create(name: String, description: String = "", members: [String]) -> JSON {
        var p: JSON = ["name": name]
        if !description.isEmpty { p["description"] = description }
        if !members.isEmpty { p["member"] = members }
        return p
    }

    /// Name and description, only what differs from `before` (empty if nothing does).
    public static func details(from before: GroupInfo, name: String? = nil, description: String? = nil) -> JSON {
        var p: JSON = [:]
        if let name, name != before.name, !name.isEmpty { p["name"] = name }
        if let description, description != before.description { p["description"] = description }
        return p
    }

    public static func addMembers(_ ids: [String]) -> JSON { ["member": ids] }
    public static func removeMembers(_ ids: [String]) -> JSON { ["removeMember": ids] }
    public static func promote(_ ids: [String]) -> JSON { ["admin": ids] }
    public static func demote(_ ids: [String]) -> JSON { ["removeAdmin": ids] }
    public static func ban(_ ids: [String]) -> JSON { ["ban": ids] }
    public static func unban(_ ids: [String]) -> JSON { ["unban": ids] }
    public static func link(_ state: GroupLinkState) -> JSON { ["link": state.rawValue] }
    public static let resetLink: JSON = ["resetLink": true]

    /// A new group picture (path of an image file signal-cli can read). signal-cli has no option to remove it.
    public static func avatar(_ path: String) -> JSON { ["avatar": path] }

    /// One permission; empty if it already has that value.
    public static func permission(_ kind: GroupPermissionKind, _ value: GroupPermission, in g: GroupInfo) -> JSON {
        kind.value(in: g) == value ? [:] : [kind.param: value.cliValue]
    }

    /// Our own member label in the group. Empty text and emoji clear it.
    public static func memberLabel(_ text: String, emoji: String) -> JSON {
        ["memberLabel": text.trimmingCharacters(in: .whitespacesAndNewlines),
         "memberLabelEmoji": emoji.trimmingCharacters(in: .whitespacesAndNewlines)]
    }

    /// `joinGroup` for an invite link.
    public static func join(_ link: GroupInviteLink) -> JSON { ["uri": link.url] }

    /// `quitGroup`: `successor` is required when the only admin leaves. `delete` also drops the local group data.
    public static func quit(groupId: String, successor: String? = nil, delete: Bool = false) -> JSON {
        var p: JSON = ["groupId": groupId]
        if let successor, !successor.isEmpty { p["admin"] = [successor] }
        if delete { p["delete"] = true }
        return p
    }

    /// Adds the group id to a set of changes.
    public static func update(groupId: String, _ changes: JSON) -> JSON {
        var p = changes
        p["groupId"] = groupId
        return p
    }
}
