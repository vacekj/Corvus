import AppKit
import CorvusCore
import SwiftUI

/// Settings → Agents: which AI agents may read which chats through `corvus-agent`.
struct AgentSettings: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Form {
            Section {
                Toggle("Let AI agents ask to read chats", isOn: $model.agentAccess.enabled)
            }
            if model.agentAccess.enabled {
                Section("Agents") {
                    if model.agentAccess.grants.isEmpty {
                        Text("No agent has access yet.").foregroundStyle(.secondary)
                    }
                    ForEach(model.agentAccess.grants) { g in
                        AgentGrantRow(grant: g)
                    }
                }
                Section("Connect an agent") {
                    CommandRow(title: "Claude Code", command: "claude mcp add --scope user corvus -- \(Self.agentPath) mcp")
                    CommandRow(title: "Command line", command: "\(Self.agentPath) chats")
                }
            }
        }
        .formStyle(.grouped)
    }

    static var agentPath: String {
        let inBundle = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/corvus-agent").path
        if FileManager.default.fileExists(atPath: inBundle) { return inBundle }
        return Bundle.main.executableURL?.deletingLastPathComponent().appendingPathComponent("corvus-agent").path ?? "corvus-agent"
    }
}

private struct CommandRow: View {
    let title: String
    let command: String

    var body: some View {
        LabeledContent(title) {
            HStack(spacing: 6) {
                Text(command).font(.system(.caption, design: .monospaced)).textSelection(.enabled).lineLimit(2)
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(command, forType: .string)
                } label: { Image(systemName: "doc.on.doc") }
                    .buttonStyle(.borderless)
                    .iconHelp("Copy")
            }
        }
    }
}

private struct AgentGrantRow: View {
    @Environment(AppModel.self) private var model
    let grant: AgentGrant
    @State private var picking = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(grant.name).font(TypeScale.headline)
                    Text(detail).font(TypeScale.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Remove", role: .destructive) { model.agentAccess.grants.removeAll { $0.id == grant.id } }
            }
            Picker("Access", selection: binding(\.allChats)) {
                Text("Selected chats").tag(false)
                Text("All chats").tag(true)
            }
            if !grant.allChats {
                ForEach(grant.chats, id: \.self) { key in
                    HStack {
                        Label(title(key), systemImage: key.hasPrefix("g:") ? "person.3" : "person")
                        Spacer()
                        Button { update { $0.chats.removeAll { $0 == key } } } label: { Image(systemName: "minus.circle") }
                            .buttonStyle(.borderless)
                            .iconHelp("Remove access to this chat")
                    }
                }
                Button("Choose Chats …") { picking = true }
                    .popover(isPresented: $picking) { AgentChatPicker(grant: grant) }
            }
            Toggle("Look up contacts", isOn: binding(\.contacts))
        }
        .padding(.vertical, 4)
    }

    private var detail: String {
        var parts = [grant.signer.isEmpty ? "Not signed" : (AgentClient.knownTeams[grant.signer] ?? grant.signer)]
        if let d = grant.lastUsed { parts.append("used " + d.formatted(.relative(presentation: .named))) }
        return parts.joined(separator: " · ")
    }

    private func title(_ key: String) -> String {
        model.agentChatChoices().first { $0.key == key }?.title ?? model.displayName(key)
    }

    private func update(_ change: (inout AgentGrant) -> Void) {
        guard var g = model.agentAccess.grant(grant.id) else { return }
        change(&g)
        model.agentAccess.upsert(g)
    }

    private func binding<T>(_ kp: WritableKeyPath<AgentGrant, T>) -> Binding<T> {
        Binding(get: { (model.agentAccess.grant(grant.id) ?? grant)[keyPath: kp] }, set: { v in update { $0[keyPath: kp] = v } })
    }
}

private struct AgentChatPicker: View {
    @Environment(AppModel.self) private var model
    let grant: AgentGrant
    @State private var selected: Set<String> = []
    @State private var filter = ""
    @State private var choices: [(key: String, title: String, isGroup: Bool)] = []

    var body: some View {
        AgentChatChecklist(choices: choices, selected: $selected, filter: $filter)
            .padding(12)
            .frame(width: 320, height: 380)
            .onAppear {
                choices = model.agentChatChoices()
                selected = Set(model.agentAccess.grant(grant.id)?.chats ?? [])
            }
            .onChange(of: selected) { _, new in
                guard var g = model.agentAccess.grant(grant.id) else { return }
                g.chats = g.chats.filter { new.contains($0) } + choices.map(\.key).filter { new.contains($0) && !g.chats.contains($0) }
                model.agentAccess.upsert(g)
            }
    }
}
