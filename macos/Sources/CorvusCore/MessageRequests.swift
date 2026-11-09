import Foundation

/// Response to a message request (`sendMessageRequestResponse --type`). signal-cli 0.14 accepts the
/// lowercase names (`accept`, `delete`), see `signal-cli sendMessageRequestResponse --help`.
public enum MessageRequestResponse: String {
    case accept
    case delete
}

/// Parameters of the commands behind blocking and message requests (signal-cli JSON-RPC, camelCase).
public enum RequestParams {
    /// `block` / `unblock`: `recipient` for people, `groupId` for groups (both take lists).
    public static func block(key: String) -> JSON {
        key.hasPrefix("g:") ? ["groupId": [String(key.dropFirst(2))]] : ["recipient": [key]]
    }

    /// `sendMessageRequestResponse` for a person (`recipient`) or a group (`groupId`).
    public static func response(_ type: MessageRequestResponse, key: String) -> JSON {
        var p: JSON = ["type": type.rawValue]
        if key.hasPrefix("g:") { p["groupId"] = String(key.dropFirst(2)) } else { p["recipient"] = [key] }
        return p
    }
}

/// A contact as listed by signal-cli `listContacts`.
public struct ContactEntry: Equatable, Identifiable {
    public var number = ""
    public var uuid = ""
    public var name = ""
    public var profileName = ""
    public var isBlocked = false
    public var isHidden = false
    /// Signal nickname and note (set by us on any device; synced through the storage service).
    public var nickGivenName = ""
    public var nickFamilyName = ""
    public var note = ""

    public init(number: String = "", uuid: String = "", name: String = "", profileName: String = "",
                isBlocked: Bool = false, isHidden: Bool = false,
                nickGivenName: String = "", nickFamilyName: String = "", note: String = "") {
        self.number = number
        self.uuid = uuid
        self.name = name
        self.profileName = profileName
        self.isBlocked = isBlocked
        self.isHidden = isHidden
        self.nickGivenName = nickGivenName
        self.nickFamilyName = nickFamilyName
        self.note = note
    }

    public init(json c: JSON) {
        self.init(number: jsonString(c["number"]), uuid: jsonString(c["uuid"]), name: jsonString(c["name"]),
                  profileName: jsonString(c["profileName"]), isBlocked: jsonBool(c["isBlocked"]),
                  isHidden: jsonBool(c["isHidden"]), nickGivenName: jsonString(c["nickGivenName"]),
                  nickFamilyName: jsonString(c["nickFamilyName"]), note: jsonString(c["note"]))
    }

    /// The Signal nickname as shown ("given family"); empty when none is set.
    public var nickname: String { ContactParams.join(given: nickGivenName, family: nickFamilyName) }

    public var key: String { number.isEmpty ? uuid : number }
    public var id: String { key }
    public var title: String { !name.isEmpty ? name : (!profileName.isEmpty ? profileName : key) }
}

/// What signal-cli knows about contacts, groups and blocking, plus which message requests the user
/// accepted. The accepted set, the blocked set and the "existing chats were grandfathered in" flags are
/// persisted per account in UserDefaults; the encrypted history only knows the record types of the
/// Rust store, so none is added for this.
public struct Roster {
    public var account = ""
    public var contacts: [ContactEntry] = []
    public var contactsLoaded = false
    public var groups: [String: GroupInfo] = [:]       // by conversation key ("g:<id>")
    public var groupsLoaded = false
    public var accepted: Set<String> = []              // conversation keys
    public var blocked: Set<String> = []               // person keys (number and UUID) and group keys
    public var contactsBaselined = false
    public var groupsBaselined = false

    private var contactIndex: [String: ContactEntry] = [:]

    public init() {}

    // MARK: Persistence

    private func defaultsKey(_ what: String) -> String { "requests.\(what).\(account)" }

    /// Reads the persisted state of `account` (the live lists stay empty until signal-cli answers).
    public mutating func load(account: String, defaults: UserDefaults = .standard) {
        self.account = account
        accepted = Set(defaults.stringArray(forKey: defaultsKey("accepted")) ?? [])
        blocked = Set(defaults.stringArray(forKey: defaultsKey("blocked")) ?? [])
        contactsBaselined = defaults.bool(forKey: defaultsKey("contactsBaselined"))
        groupsBaselined = defaults.bool(forKey: defaultsKey("groupsBaselined"))
    }

    public func save(defaults: UserDefaults = .standard) {
        guard !account.isEmpty else { return }
        defaults.set(accepted.sorted(), forKey: defaultsKey("accepted"))
        defaults.set(blocked.sorted(), forKey: defaultsKey("blocked"))
        defaults.set(contactsBaselined, forKey: defaultsKey("contactsBaselined"))
        defaults.set(groupsBaselined, forKey: defaultsKey("groupsBaselined"))
    }

    // MARK: Contacts

    public func contact(_ id: String) -> ContactEntry? { contactIndex[id] }

    /// Replaces the contact list with a `listContacts` result. Hidden contacts are not "known": they are
    /// what the phone shows as message requests.
    public mutating func update(contacts result: Any?) {
        contacts = jsonArray(result).map(jsonObject).map(ContactEntry.init(json:)).filter { !$0.key.isEmpty }
        contactIndex = [:]
        for c in contacts {
            if !c.number.isEmpty { contactIndex[c.number] = c }
            if !c.uuid.isEmpty { contactIndex[c.uuid] = c }
        }
        contactsLoaded = true
        for c in contacts {
            for k in [c.number, c.uuid] where !k.isEmpty {
                if c.isBlocked { blocked.insert(k) } else { blocked.remove(k) }
            }
        }
    }

    /// Records a nickname or note change that was sent to signal-cli (nil: unchanged). Only contacts signal-cli
    /// already listed are updated; returns false if there is none for `key`.
    @discardableResult
    public mutating func setContactDetails(_ key: String, nickGivenName: String? = nil, nickFamilyName: String? = nil,
                                           note: String? = nil) -> Bool {
        guard let found = contactIndex[key], let i = contacts.firstIndex(where: { $0.key == found.key }) else { return false }
        var c = contacts[i]
        if let nickGivenName { c.nickGivenName = nickGivenName }
        if let nickFamilyName { c.nickFamilyName = nickFamilyName }
        if let note { c.note = note }
        guard c != contacts[i] else { return true }
        contacts[i] = c
        if !c.number.isEmpty { contactIndex[c.number] = c }
        if !c.uuid.isEmpty { contactIndex[c.uuid] = c }
        return true
    }

    /// People we can pick for a group: not hidden, not ourselves, sorted by name.
    public var pickableContacts: [ContactEntry] {
        contacts.filter { !$0.isHidden && $0.number != account && $0.uuid != account }
            .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    public func isKnownContact(_ key: String) -> Bool {
        guard let c = contactIndex[key] else { return false }
        return !c.isHidden
    }

    // MARK: Groups

    /// Replaces the group list with a `listGroups` result.
    public mutating func update(groups result: Any?) {
        groups = [:]
        for g in GroupInfo.parseList(result) {
            groups[g.key] = g
            if g.isBlocked { blocked.insert(g.key) } else { blocked.remove(g.key) }
        }
        groupsLoaded = true
    }

    /// A single group changed (after `updateGroup`): keeps the rest of the list.
    public mutating func set(group g: GroupInfo) {
        groups[g.key] = g
        if g.isBlocked { blocked.insert(g.key) } else { blocked.remove(g.key) }
    }

    // MARK: Blocking

    public func isBlocked(_ key: String, resolve: (String) -> String = { $0 }) -> Bool {
        blocked.contains(key) || blocked.contains(resolve(key))
    }

    /// Records a block / unblock that signal-cli confirmed. People are stored under number and UUID.
    public mutating func setBlocked(_ key: String, _ on: Bool, resolve: (String) -> String = { $0 }) {
        var keys: Set<String> = [key, resolve(key)]
        if let c = contactIndex[key] ?? contactIndex[resolve(key)] { keys.formUnion([c.number, c.uuid]) }
        keys.remove("")
        if on { blocked.formUnion(keys) } else { blocked.subtract(keys) }
    }

    // MARK: Message requests

    public func isAccepted(_ key: String, resolve: (String) -> String = { $0 }) -> Bool {
        accepted.contains(key) || accepted.contains(resolve(key))
    }

    public mutating func accept(_ key: String, resolve: (String) -> String = { $0 }) {
        accepted.insert(resolve(key))
    }

    /// A message request is
    /// - a 1:1 chat with someone who is not one of our contacts, who wrote to us, and whom we never wrote to,
    /// - a group we are invited to but did not join, or one we were added to (it appeared after the first run
    ///   and we never accepted it nor wrote in it).
    /// Chats the user accepted, blocked chats and Note to Self are never requests. Nothing is a request before
    /// signal-cli reported the contacts / groups (an unknown list would flag every chat).
    public func isRequest(_ c: Conversation, resolve: (String) -> String = { $0 }) -> Bool {
        if isBlocked(c.key, resolve: resolve) { return false }
        let wroteHere = c.msgs.contains { $0.outgoing }
        if c.isGroup {
            guard groupsLoaded, let g = groups[c.key] else { return false }
            if g.isInvitation(for: account) { return true }
            guard g.isMember, groupsBaselined else { return false }
            return !isAccepted(c.key, resolve: resolve) && !wroteHere
        }
        let key = resolve(c.key)
        if key == account || c.key == account { return false } // Note to Self
        guard contactsLoaded, contactsBaselined else { return false }
        if isAccepted(c.key, resolve: resolve) || isKnownContact(c.key) || isKnownContact(key) { return false }
        return !wroteHere && c.msgs.contains { !$0.outgoing }
    }

    /// First run after the upgrade: chats that already exist are the user's chats, not requests.
    /// Returns true if the persisted state changed.
    @discardableResult
    public mutating func baselineContacts(existing keys: [String], resolve: (String) -> String = { $0 }) -> Bool {
        guard contactsLoaded, !contactsBaselined else { return false }
        for k in keys where !k.hasPrefix("g:") { accepted.insert(resolve(k)) }
        contactsBaselined = true
        return true
    }

    /// Same for groups: every group we are a member of right now is grandfathered in; invitations stay requests.
    @discardableResult
    public mutating func baselineGroups() -> Bool {
        guard groupsLoaded, !groupsBaselined else { return false }
        for g in groups.values where g.isMember { accepted.insert(g.key) }
        groupsBaselined = true
        return true
    }

    // MARK: Rules used by the app

    /// Nothing can be sent to a request, a blocked chat, a group we are no longer in, or a group where only
    /// admins may send and we are not one.
    public func isSendLocked(_ c: Conversation, resolve: (String) -> String = { $0 }) -> Bool {
        if isBlocked(c.key, resolve: resolve) || isRequest(c, resolve: resolve) { return true }
        if c.isGroup, let g = groups[c.key], !g.isMember || isAdminOnlyForUs(g) { return true }
        return false
    }

    /// The group is announcement-only and we are a member but not an admin.
    public func isAdminOnlyForUs(_ g: GroupInfo) -> Bool {
        g.isMember && g.isAnnouncementOnly && g.member(account) != nil && !g.canSendMessages(account)
    }

    /// Notifications, sounds, the unread counter and the dock bounce are only for chats the user accepted and
    /// people who are not blocked. `author` is the sender of the message (differs from the chat in groups).
    public func isQuiet(_ c: Conversation, author: String = "", resolve: (String) -> String = { $0 }) -> Bool {
        if isBlocked(c.key, resolve: resolve) || isRequest(c, resolve: resolve) { return true }
        return !author.isEmpty && c.isGroup && isBlocked(author, resolve: resolve)
    }

    /// Read receipts and typing indicators reveal that the chat was seen: not before the request is accepted
    /// and never to blocked people.
    public func mayAcknowledge(_ c: Conversation, resolve: (String) -> String = { $0 }) -> Bool {
        !(isBlocked(c.key, resolve: resolve) || isRequest(c, resolve: resolve))
    }
}
