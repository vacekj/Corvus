import Foundation

// Read access to the chats for AI agents (Claude Code and the like) through `corvus-agent`.
// The app keeps the decrypted history in memory; agents get it only through the app, only after the
// user allowed that agent, and only the chats the user picked. Nothing here marks chats read or sends
// anything to Signal.

/// What one agent may read. Agents are told apart by their code signature (team + identifier), or by
/// their executable path when they are not signed.
public struct AgentGrant: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var name: String
    public var signer: String
    public var allChats: Bool
    public var chats: [String]
    public var contacts: Bool
    public var added: Date
    public var lastUsed: Date?

    public init(id: String, name: String, signer: String = "", allChats: Bool = false, chats: [String] = [],
                contacts: Bool = true, added: Date = Date(), lastUsed: Date? = nil) {
        self.id = id
        self.name = name
        self.signer = signer
        self.allChats = allChats
        self.chats = chats
        self.contacts = contacts
        self.added = added
        self.lastUsed = lastUsed
    }

    public func allows(_ key: String) -> Bool { allChats || chats.contains(key) }
}

/// The "Agents" settings: off by default; while off, Corvus does not listen for agents at all.
public struct AgentAccessSettings: Codable, Equatable, Sendable {
    public var enabled = false
    public var grants: [AgentGrant] = []

    public init(enabled: Bool = false, grants: [AgentGrant] = []) {
        self.enabled = enabled
        self.grants = grants
    }

    public static let defaultsKey = "agentAccess"

    public static func load(_ defaults: UserDefaults = .standard) -> AgentAccessSettings {
        guard let d = defaults.data(forKey: defaultsKey),
              let s = try? JSONDecoder().decode(AgentAccessSettings.self, from: d) else { return AgentAccessSettings() }
        return s
    }

    public func save(_ defaults: UserDefaults = .standard) {
        if let d = try? JSONEncoder().encode(self) { defaults.set(d, forKey: Self.defaultsKey) }
    }

    public func grant(_ id: String) -> AgentGrant? { grants.first { $0.id == id } }

    public mutating func upsert(_ g: AgentGrant) {
        if let i = grants.firstIndex(where: { $0.id == g.id }) { grants[i] = g } else { grants.append(g) }
    }
}

public struct AgentError: Error, Equatable {
    public var code: String
    public var message: String
    public init(_ code: String, _ message: String) {
        self.code = code
        self.message = message
    }

    public static let notFound = AgentError("not_found", "No chat you may read matches that.")
    public static let contactsDenied = AgentError("denied", "Corvus does not let this agent look up contacts.")
}

/// How a chat name or id given by an agent resolves.
public enum AgentChatMatch: Equatable {
    case allowed(String)
    case needsPermission(String)
    case ambiguous([String])
    case none
}

/// The agent requests, answered from a copy of the chats. Pure, so it runs off the main thread and in tests.
public struct AgentQuery {
    public var state: ChatState
    public var roster: Roster
    public var grant: AgentGrant

    public init(state: ChatState, roster: Roster, grant: AgentGrant) {
        self.state = state
        self.roster = roster
        self.grant = grant
    }

    private var account: String { state.account }

    // MARK: Names

    /// A person's name as the user sees it (never a UUID).
    public func personName(_ key: String) -> String {
        let r = state.resolveKey(key)
        if !account.isEmpty && (key == account || r == account) { return "You" }
        if let c = roster.contact(key) ?? roster.contact(r) {
            let nick = c.nickname
            return People.displayName(names: [nick, c.name, c.profileName, state.convs[r]?.title ?? ""], number: c.number)
        }
        return People.displayName(names: [state.convs[r]?.title ?? ""], number: People.isPhoneNumber(r) ? r : "")
    }

    public func chatTitle(_ c: Conversation) -> String {
        if c.isGroup { return c.title.isEmpty ? "Group" : c.title }
        return personName(c.key)
    }

    // MARK: Chats

    var visibleChats: [Conversation] {
        state.convs.values.filter { grant.allows($0.key) && (!$0.msgs.isEmpty || grant.chats.contains($0.key)) }
    }

    public func listChats(query: String = "", limit: Int = 50, includeArchived: Bool = true) -> [JSON] {
        var list = visibleChats.filter { includeArchived || !$0.archived }
        let q = query.trimmingCharacters(in: .whitespaces)
        if !q.isEmpty {
            let scored = list.compactMap { c in FuzzyMatch.score(q, chatTitle(c)).map { (c, $0) } }
            list = scored.sorted { $0.1 != $1.1 ? $0.1 > $1.1 : $0.0.lastTs > $1.0.lastTs }.map(\.0)
        } else {
            list.sort { $0.lastTs > $1.lastTs }
        }
        return list.prefix(max(1, limit)).map(chatSummary)
    }

    func chatSummary(_ c: Conversation) -> JSON {
        var o: JSON = ["id": c.key, "name": chatTitle(c), "type": c.isGroup ? "group" : "direct", "messages": c.msgs.count]
        if let m = c.msgs.last(where: { !$0.isNotice }) {
            o["lastMessageAt"] = Self.iso(m.ts)
            o["lastMessage"] = String(preview(m).prefix(120))
            o["lastFrom"] = sender(c, m)
        }
        if c.unread > 0 { o["unread"] = c.unread }
        if c.archived { o["archived"] = true }
        if c.isGroup, let g = roster.groups[c.key] { o["members"] = g.members.count }
        else if !c.isGroup, People.isPhoneNumber(c.key) { o["number"] = c.key }
        return o
    }

    /// A chat by id or name. Names match like ⌘K does; a clearly best match wins.
    public func resolveChat(_ s: String) -> AgentChatMatch {
        let s = s.trimmingCharacters(in: .whitespaces)
        guard !s.isEmpty else { return .none }
        let exact = state.convs[s] != nil ? s : (state.convs[state.resolveKey(s)] != nil ? state.resolveKey(s) : nil)
        if let k = exact { return grant.allows(k) ? .allowed(k) : .needsPermission(k) }
        let scored = state.convs.values.compactMap { c -> (Conversation, Int)? in
            guard !c.msgs.isEmpty || grant.allows(c.key) else { return nil }
            return Self.nameScore(s, chatTitle(c)).map { (c, $0) }
        }.sorted { $0.1 != $1.1 ? $0.1 > $1.1 : $0.0.lastTs > $1.0.lastTs }
        // Allowed chats first: names of other chats never reach the agent, only a permission request.
        let allowed = scored.filter { grant.allows($0.0.key) }
        // A name match of an allowed chat wins; a loose one only when no other chat has that name.
        if let best = pick(allowed, min: 600) { return .allowed(best.key) }
        if allowed.count > 1, allowed[0].1 >= 600 { return .ambiguous(allowed.prefix(5).map { "\(chatTitle($0.0)) (\($0.0.key))" }) }
        if let best = pick(scored.filter { !grant.allows($0.0.key) }, min: 600) { return .needsPermission(best.key) }
        if let best = pick(allowed, min: 0) { return .allowed(best.key) }
        if allowed.count > 1 { return .ambiguous(allowed.prefix(5).map { "\(chatTitle($0.0)) (\($0.0.key))" }) }
        return .none
    }

    static func fold(_ s: String) -> String {
        s.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
    }

    /// ⌘K-style score, or else every word of the query close to a word of the name ("eko lab" finds
    /// "ECO (Lab) Team": one letter off per word of 3+ letters).
    static func nameScore(_ query: String, _ name: String) -> Int? {
        let fq = fold(query.trimmingCharacters(in: .whitespaces)), fn = fold(name)
        if !fq.isEmpty, let r = fn.range(of: fq) { return (r.lowerBound == fn.startIndex ? 1000 : 800) - fn.count }
        let words = { (x: String) in fold(x).split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init) }
        let q = words(query), n = words(name)
        guard !q.isEmpty else { return FuzzyMatch.score(query, name).map { min($0, 599) } }
        for w in q {
            let ok = n.contains { t in t.hasPrefix(w) || (w.count >= 3 && editDistance(w, String(t.prefix(w.count))) <= 1) }
            if !ok { return FuzzyMatch.score(query, name).map { min($0, 599) } }
        }
        return 650
    }

    static func editDistance(_ a: String, _ b: String) -> Int {
        let a = Array(a), b = Array(b)
        var row = Array(0...b.count)
        for i in 1...max(a.count, 1) where !a.isEmpty {
            var prev = row[0]
            row[0] = i
            for j in 1...max(b.count, 1) where !b.isEmpty {
                let cur = row[j]
                row[j] = min(row[j] + 1, row[j - 1] + 1, prev + (a[i - 1] == b[j - 1] ? 0 : 1))
                prev = cur
            }
        }
        return a.isEmpty ? b.count : row[b.count]
    }

    /// The clear best match; a name found twice (one person under number and UUID) is the chat used last.
    private func pick(_ list: [(Conversation, Int)], min: Int) -> Conversation? {
        if let best = Self.clearBest(list, min: min) { return best }
        guard let first = list.first, first.1 >= min else { return nil }
        let name = Self.fold(chatTitle(first.0))
        let rivals = list.dropFirst().filter { $0.1 >= first.1 - 50 }
        return rivals.allSatisfy({ Self.fold(chatTitle($0.0)) == name }) ? first.0 : nil
    }

    /// The top match when it scores at least `min` and is clearly ahead of the next one.
    private static func clearBest(_ list: [(Conversation, Int)], min: Int) -> Conversation? {
        guard let first = list.first, first.1 >= min else { return nil }
        if list.count > 1, list[1].1 >= first.1 - 50 { return nil }
        return first.0
    }

    /// Messages of an allowed chat, oldest first: the newest `limit` before `before` (or after `after`).
    public func readChat(_ key: String, limit: Int = 50, before: Int64? = nil, after: Int64? = nil) -> JSON {
        guard let c = state.convs[key], grant.allows(key) else { return [:] }
        var msgs = c.msgs.filter { !Self.hidden($0) }
        if let before { msgs = msgs.filter { $0.ts < before } }
        let page: ArraySlice<Message>
        let n = max(1, min(limit, 500))
        if let after {
            msgs = msgs.filter { $0.ts > after }
            page = msgs.prefix(n)
        } else {
            page = msgs.suffix(n)
        }
        var o = chatSummary(c)
        o["returned"] = page.count
        o["hasOlder"] = page.first.map { f in c.msgs.contains { $0.ts < f.ts && !Self.hidden($0) } } ?? false
        o["messageList"] = page.map { message(c, $0) }
        if c.isGroup, let g = roster.groups[key] {
            o["memberNames"] = g.members.map { personName($0.uuid.isEmpty ? $0.number : $0.uuid) }
            if !g.description.isEmpty { o["description"] = g.description }
        }
        return o
    }

    public func searchMessages(_ query: String, chat: String? = nil, limit: Int = 30) -> [JSON] {
        let scope = state.convs.filter { grant.allows($0.key) && (chat == nil || $0.key == chat) }
        return CorvusCore.searchMessages(scope, query: query, limit: max(1, min(limit, 200))).compactMap { h in
            guard let c = scope[h.key], let i = c.msgs.lastIndex(where: { $0.ts == h.ts && $0.authorKey == h.authorKey }) else { return nil }
            var o = message(c, c.msgs[i])
            o["chatId"] = c.key
            o["chat"] = chatTitle(c)
            return o
        }
    }

    public func searchContacts(_ query: String, limit: Int = 20) throws -> [JSON] {
        guard grant.contacts else { throw AgentError.contactsDenied }
        let q = query.trimmingCharacters(in: .whitespaces)
        var out: [(JSON, Int)] = []
        for c in roster.contacts where !c.isHidden && c.number != account && c.uuid != account {
            let name = personName(c.key)
            let score = q.isEmpty ? 0 : (FuzzyMatch.score(q, name) ?? (c.number.contains(q) ? 500 : nil))
            guard q.isEmpty || score != nil else { continue }
            var o: JSON = ["name": name]
            if !c.number.isEmpty { o["number"] = c.number }
            if !c.nickname.isEmpty, c.nickname != name { o["nickname"] = c.nickname }
            if !c.profileName.isEmpty, c.profileName != name { o["profileName"] = c.profileName }
            let key = state.convs[c.number] != nil ? c.number : (state.convs[c.uuid] != nil ? c.uuid : "")
            if !key.isEmpty, grant.allows(key) { o["chatId"] = key }
            out.append((o, score ?? 0))
        }
        out.sort { $0.1 != $1.1 ? $0.1 > $1.1 : jsonString($0.0["name"]) < jsonString($1.0["name"]) }
        return out.prefix(max(1, min(limit, 200))).map(\.0)
    }

    // MARK: Messages

    static func hidden(_ m: Message) -> Bool { m.viewOnce && !m.outgoing }

    func sender(_ c: Conversation, _ m: Message) -> String {
        if m.outgoing { return "You" }
        let key = state.effectiveAuthor(c, m)
        let n = personName(key)
        return n == People.unknown && !m.sender.isEmpty ? m.sender : n
    }

    func preview(_ m: Message) -> String {
        if m.deleted { return "(deleted)" }
        if !m.text.isEmpty { return m.text }
        if let a = m.attachments.first { return "[\(Self.kind(a))]" }
        return ""
    }

    static func kind(_ a: Attachment) -> String {
        if a.isSticker { return "sticker" }
        if a.isGif { return "gif" }
        if a.isImage { return "image" }
        if a.isVideo { return "video" }
        if a.isAudio { return "audio" }
        return "file"
    }

    func message(_ c: Conversation, _ m: Message) -> JSON {
        var o: JSON = ["time": Self.iso(m.ts), "ts": m.ts, "from": sender(c, m)]
        if m.deleted {
            o["deleted"] = true
            return o
        }
        if !m.text.isEmpty { o["text"] = m.text }
        if !m.attachments.isEmpty {
            o["attachments"] = m.attachments.map { a -> JSON in
                var x: JSON = ["type": Self.kind(a)]
                if !a.filename.isEmpty, !a.isSticker { x["name"] = a.filename }
                return x
            }
        }
        if m.quote.valid {
            o["replyTo"] = ["from": personName(m.quote.authorKey), "text": String(m.quote.text.prefix(200)), "ts": m.quote.id] as JSON
        }
        if !m.reactions.isEmpty {
            o["reactions"] = m.reactions.map { ["from": personName($0.key), "emoji": $0.value] as JSON }
        }
        if m.isEdited { o["edited"] = true }
        if !m.poll.question.isEmpty {
            o["poll"] = ["question": m.poll.question, "options": m.poll.options] as JSON
        }
        return o
    }

    public static func iso(_ ms: Int64) -> String {
        let f = ISO8601DateFormatter()
        f.timeZone = .current
        f.formatOptions = [.withInternetDateTime]
        return f.string(from: Date(timeIntervalSince1970: TimeInterval(ms) / 1000))
    }

    /// Accepts ms since 1970, seconds, or an ISO 8601 date / date-time.
    public static func parseTime(_ v: Any?) -> Int64? {
        if let n = v as? NSNumber { let x = n.int64Value; return x > 100_000_000_000 ? x : x * 1000 }
        guard let s = (v as? String)?.trimmingCharacters(in: .whitespaces), !s.isEmpty else { return nil }
        if let x = Int64(s) { return x > 100_000_000_000 ? x : x * 1000 }
        let f = ISO8601DateFormatter()
        f.timeZone = .current
        for opts: ISO8601DateFormatter.Options in [[.withInternetDateTime], [.withInternetDateTime, .withFractionalSeconds], [.withFullDate]] {
            f.formatOptions = opts
            if let d = f.date(from: s) { return Int64(d.timeIntervalSince1970 * 1000) }
        }
        return nil
    }
}
