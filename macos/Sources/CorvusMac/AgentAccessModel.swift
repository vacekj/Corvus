import AppKit
import CorvusCore
import SwiftUI

// Agent requests (AgentServer.swift) answered from the chats in memory, after the user allowed the agent
// in a prompt like 1Password's: which chats, and whether it may look up contacts.

extension AppPaths {
    static var agentSocketPath: String { dataDir.appendingPathComponent("agent.sock").path }
}

/// Prompts one at a time; a request waits for the prompts before it.
@MainActor
final class AgentPromptQueue {
    private var tail: Task<Void, Never>?

    func run<T: Sendable>(_ body: @escaping @MainActor () async -> T) async -> T {
        let previous = tail
        let task = Task { @MainActor in
            _ = await previous?.value
            return await body()
        }
        tail = Task { _ = await task.value }
        return await task.value
    }
}

private struct Unchecked<T>: @unchecked Sendable { let value: T }

extension AppModel {
    func agentAccessChanged(_ old: AgentAccessSettings) {
        agentAccess.save()
        if old.enabled != agentAccess.enabled { updateAgentServer() }
    }

    func updateAgentServer() {
        if agentAccess.enabled {
            guard agentServer == nil else { return }
            let server = AgentServer(path: AppPaths.agentSocketPath) { [weak self] session, request in
                guard let self else { return ["error": ["code": "unavailable", "message": "Corvus is quitting."]] }
                return await self.handleAgent(session, request)
            }
            if server.start() { agentServer = server } else { showFlash("Agent access could not start: the socket could not be created.") }
        } else {
            agentServer?.stop()
            agentServer = nil
        }
    }

    func handleAgent(_ session: AgentSession, _ request: JSON) async -> JSON {
        let id = request["id"] ?? NSNull()
        func failure(_ e: AgentError) -> JSON { ["id": id, "error": ["code": e.code, "message": e.message] as JSON] }
        guard agentAccess.enabled else { return failure(AgentError("disabled", "Agent access is turned off in Corvus Settings → Agents.")) }
        guard historyLoaded else { return failure(AgentError("locked", "Corvus has not unlocked the chat history yet.")) }
        let client = session.client
        if agentAccess.grant(client.id) == nil {
            if session.deniedAgent { return failure(AgentError("denied", "The user did not allow \(client.name) to read Corvus chats.")) }
            let granted = await agentPrompts.run { await self.askAgentAccess(client) }
            guard let granted else {
                session.deniedAgent = true
                return failure(AgentError("denied", "The user did not allow \(client.name) to read Corvus chats."))
            }
            if agentAccess.grant(client.id) == nil { agentAccess.upsert(granted) }
        }
        guard var grant = agentAccess.grant(client.id) else { return failure(AgentError("denied", "Access was removed.")) }
        if (grant.lastUsed?.timeIntervalSinceNow ?? -3600) < -60 {
            grant.lastUsed = Date()
            agentAccess.upsert(grant)
        }
        do {
            let result = try await agentCall(session, jsonString(request["method"]), jsonObject(request["params"]))
            return ["id": id, "result": result]
        } catch let e as AgentError {
            return failure(e)
        } catch {
            return failure(AgentError("failed", error.localizedDescription))
        }
    }

    private func query(_ client: AgentClient) throws -> AgentQuery {
        guard let g = agentAccess.grant(client.id) else { throw AgentError("denied", "Access was removed.") }
        return AgentQuery(state: chats, roster: roster, grant: g)
    }

    private func agentCall(_ session: AgentSession, _ method: String, _ p: JSON) async throws -> Any {
        let client = session.client
        let limit = p["limit"] == nil ? nil : jsonInt(p["limit"])
        switch method {
        case "hello":
            let q = try query(client)
            return ["agent": client.name, "access": q.grant.allChats ? "all chats" : "selected chats",
                    "chats": q.listChats(limit: 10_000).count, "contacts": q.grant.contacts] as JSON
        case "listChats":
            return try query(client).listChats(query: jsonString(p["query"]), limit: limit ?? 50,
                                                includeArchived: p["includeArchived"].map(jsonBool) ?? true)
        case "readChat":
            let key = try await agentChat(session, jsonString(p["chat"]))
            return try query(client).readChat(key, limit: limit ?? 50, before: AgentQuery.parseTime(p["before"]),
                                              after: AgentQuery.parseTime(p["after"]))
        case "searchMessages":
            let text = jsonString(p["query"])
            guard text.trimmingCharacters(in: .whitespaces).count >= 2 else { throw AgentError("invalid", "The query needs at least 2 characters.") }
            let chat = jsonString(p["chat"])
            let key: String? = chat.isEmpty ? nil : try await agentChat(session, chat)
            let q = Unchecked(value: try query(client))
            return await Task.detached { Unchecked(value: q.value.searchMessages(text, chat: key, limit: limit ?? 30)) }.value.value
        case "searchContacts":
            return try query(client).searchContacts(jsonString(p["query"]), limit: limit ?? 20)
        default:
            throw AgentError("unknown_method", "Unknown method \(method).")
        }
    }

    /// A chat the agent names: allowed, or allowed now by the user.
    private func agentChat(_ session: AgentSession, _ name: String) async throws -> String {
        let client = session.client
        switch try query(client).resolveChat(name) {
        case .allowed(let key): return key
        case .ambiguous(let names):
            throw AgentError("ambiguous", "Several chats match: \(names.joined(separator: ", ")). Use the chat id from list_chats.")
        case .none: throw AgentError.notFound
        case .needsPermission(let key):
            let denied = AgentError("denied", "The user did not allow \(client.name) to read that chat.")
            if session.deniedChats.contains(key) { throw denied }
            let title = try query(client).chatTitle(chats.convs[key] ?? Conversation(key: key))
            let ok = await agentPrompts.run { await self.askChatAccess(client, title: title) }
            guard ok, var g = agentAccess.grant(client.id) else {
                session.deniedChats.insert(key)
                throw denied
            }
            if !g.allows(key) { g.chats.append(key) }
            agentAccess.upsert(g)
            return key
        }
    }

    // MARK: Prompts

    /// Chats for the pickers: newest first, with their names as the agent would see them.
    func agentChatChoices() -> [(key: String, title: String, isGroup: Bool)] {
        let q = AgentQuery(state: chats, roster: roster, grant: AgentGrant(id: "", name: ""))
        return chats.convs.values.filter { !$0.msgs.isEmpty }.sorted { $0.lastTs > $1.lastTs }
            .map { ($0.key, q.chatTitle($0), $0.isGroup) }
    }

    func askAgentAccess(_ client: AgentClient) async -> AgentGrant? {
        let state = AgentRequestState(client: client, choices: agentChatChoices())
        await AgentPanel.present(AgentAccessPrompt(state: state), size: NSSize(width: 440, height: 560), state: state)
        guard state.decision == true else { return nil }
        return AgentGrant(id: client.id, name: client.name, signer: client.signer, allChats: state.allChats,
                          chats: state.allChats ? [] : state.order.filter { state.selected.contains($0) },
                          contacts: state.contacts)
    }

    func askChatAccess(_ client: AgentClient, title: String) async -> Bool {
        let state = AgentRequestState(client: client, choices: [])
        state.chatTitle = title
        await AgentPanel.present(AgentChatPrompt(state: state), size: NSSize(width: 400, height: 150), state: state)
        return state.decision == true
    }
}

@MainActor
@Observable
final class AgentRequestState {
    let client: AgentClient
    let choices: [(key: String, title: String, isGroup: Bool)]
    var order: [String] { choices.map(\.key) }
    var allChats = false
    var selected: Set<String> = []
    var contacts = true
    var filter = ""
    var chatTitle = ""
    var decision: Bool?
    @ObservationIgnored var finish: () -> Void = {}

    init(client: AgentClient, choices: [(key: String, title: String, isGroup: Bool)]) {
        self.client = client
        self.choices = choices
    }

    func decide(_ allow: Bool) {
        decision = allow
        finish()
    }
}

/// A floating panel that does not activate Corvus (no focus is taken from the app in front).
@MainActor
final class AgentPanel: NSObject, NSWindowDelegate {
    static var current: AgentPanel?
    let panel: NSPanel
    private var continuation: CheckedContinuation<Void, Never>?
    let state: AgentRequestState

    private init(_ view: some View, size: NSSize, state: AgentRequestState) {
        self.state = state
        panel = NSPanel(contentRect: NSRect(origin: .zero, size: size),
                        styleMask: [.titled, .closable, .nonactivatingPanel, .fullSizeContentView],
                        backing: .buffered, defer: false)
        super.init()
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = true
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = NSHostingView(rootView: view.font(TypeScale.body))
        panel.delegate = self
        panel.center()
        if HiddenMode.on {
            panel.alphaValue = 0
            panel.ignoresMouseEvents = true
        }
    }

    static func present(_ view: some View, size: NSSize, state: AgentRequestState, timeout: TimeInterval = 180) async {
        let p = AgentPanel(view, size: size, state: state)
        current = p
        state.finish = { [weak p] in p?.done() }
        // Shown on top but not key: keystrokes meant for the app in front can never answer it.
        p.panel.orderFrontRegardless()
        Task { @MainActor [weak p] in
            try? await Task.sleep(for: .seconds(timeout))
            p?.done()
        }
        await withCheckedContinuation { c in p.continuation = c }
        p.panel.orderOut(nil)
        if current === p { current = nil }
    }

    private func done() {
        continuation?.resume()
        continuation = nil
    }

    func windowWillClose(_ notification: Notification) { done() }
}

// MARK: - Prompt views

private struct AgentHeader: View {
    let client: AgentClient
    let title: String

    var body: some View {
        HStack(spacing: 12) {
            Image(nsImage: client.icon).resizable().frame(width: 44, height: 44)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(TypeScale.headline).fixedSize(horizontal: false, vertical: true)
                Label(client.signerText, systemImage: client.signer.isEmpty ? "exclamationmark.triangle" : "checkmark.seal")
                    .font(TypeScale.caption)
                    .foregroundStyle(client.signer.isEmpty ? .orange : .secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
    }
}

struct AgentAccessPrompt: View {
    @Bindable var state: AgentRequestState

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            AgentHeader(client: state.client, title: "\(state.client.name) wants to read your Corvus chats")
            Picker("", selection: $state.allChats) {
                Text("Selected chats").tag(false)
                Text("All chats").tag(true)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            if !state.allChats {
                AgentChatChecklist(choices: state.choices, selected: $state.selected, filter: $state.filter)
            } else {
                Spacer(minLength: 0)
            }
            Toggle("Look up contacts", isOn: $state.contacts)
            HStack {
                Spacer()
                Button("Deny") { state.decide(false) }.keyboardShortcut(.cancelAction)
                Button(allowTitle) { state.decide(true) }
                    .buttonStyle(.borderedProminent)
                    .disabled(!state.allChats && state.selected.isEmpty && !state.contacts)
            }
        }
        .padding(20)
        .padding(.top, 8)
        .frame(width: 440, height: 560)
    }

    private var allowTitle: String {
        if state.allChats { return "Allow All Chats" }
        let n = state.selected.count
        return n == 0 ? "Allow" : "Allow \(n) Chat\(n == 1 ? "" : "s")"
    }
}

struct AgentChatChecklist: View {
    let choices: [(key: String, title: String, isGroup: Bool)]
    @Binding var selected: Set<String>
    @Binding var filter: String

    private var shown: [(key: String, title: String, isGroup: Bool)] {
        let q = filter.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return choices }
        return choices.filter { FuzzyMatch.score(q, $0.title).map { $0 >= 600 } ?? false }
    }

    var body: some View {
        VStack(spacing: 6) {
            TextField("Search chats", text: $filter).textFieldStyle(.roundedBorder)
            List {
                ForEach(shown, id: \.key) { c in
                    Toggle(isOn: Binding(get: { selected.contains(c.key) },
                                         set: { if $0 { selected.insert(c.key) } else { selected.remove(c.key) } })) {
                        Label(c.title, systemImage: c.isGroup ? "person.3" : "person")
                    }
                    .toggleStyle(.checkbox)
                }
            }
            .listStyle(.bordered(alternatesRowBackgrounds: false))
        }
    }
}

struct AgentChatPrompt: View {
    let state: AgentRequestState

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            AgentHeader(client: state.client, title: "\(state.client.name) wants to read “\(state.chatTitle)”")
            Spacer(minLength: 0)
            HStack {
                Spacer()
                Button("Deny") { state.decide(false) }.keyboardShortcut(.cancelAction)
                Button("Allow") { state.decide(true) }.buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
        .padding(.top, 8)
        .frame(width: 400, height: 150)
    }
}
