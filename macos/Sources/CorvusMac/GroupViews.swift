import AppKit
import CorvusCore
import SwiftUI

/// Sheets for "New group …" and "Group info …". Applied once to the main window.
struct GroupSheets: ViewModifier {
    @Environment(AppModel.self) private var model

    func body(content: Content) -> some View {
        content
            .sheet(isPresented: Binding(get: { model.newGroupShown }, set: { model.newGroupShown = $0 })) { NewGroupSheet() }
            .sheet(isPresented: Binding(get: { model.newConversationShown }, set: { model.newConversationShown = $0 })) {
                NewConversationSheet()
            }
            .sheet(isPresented: Binding(get: { model.groupInfoKey != nil }, set: { if !$0 { model.groupInfoKey = nil } })) {
                if let key = model.groupInfoKey { GroupInfoSheet(key: key) }
            }
    }
}

/// Group entries of the conversation menu.
struct GroupMenuItems: View {
    @Environment(AppModel.self) private var model
    let conversation: Conversation

    var body: some View {
        if conversation.isGroup {
            Button { model.showGroupInfo(conversation.key) } label: { Label("Group info …", systemImage: "info.circle") }
            Button(role: .destructive) { Task { await model.leaveGroup(conversation.key) } } label: {
                Label("Leave group …", systemImage: "rectangle.portrait.and.arrow.right")
            }
            .disabled(!model.connected || model.roster.groups[conversation.key]?.isMember != true)
            Divider()
        }
    }
}

// MARK: - New group

struct NewGroupSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var about = ""
    @State private var members: [String] = []
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        let title = name.trimmingCharacters(in: .whitespacesAndNewlines)
        VStack(alignment: .leading, spacing: 10) {
            Text("New group").font(.title3.weight(.semibold))
            TextField("Group name", text: $name).textFieldStyle(.roundedBorder)
            TextField("Description (optional)", text: $about, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(1...3)
            Text("Members").font(.headline)
            ContactPicker(selection: $members).frame(height: 340)
            if let error { Text(error).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true) }
            HStack {
                if busy { ProgressView().controlSize(.small) }
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Create") {
                    busy = true
                    error = nil
                    Task {
                        let err = await model.createGroup(name: title, description: about.trimmingCharacters(in: .whitespacesAndNewlines),
                                                          members: members)
                        busy = false
                        if let err { error = err } else { dismiss() }
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(title.isEmpty || busy || !model.connected)
            }
        }
        .padding(20)
        .frame(width: 420)
    }
}

// MARK: - Group info

struct GroupInfoSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let key: String
    @State private var name = ""
    @State private var about = ""
    @State private var busy = false
    @State private var error: String?
    @State private var addShown = false

    private var id: String { String(key.dropFirst(2)) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let g = model.roster.groups[key], let c = model.chats.convs[key] {
                content(g, c)
            } else {
                Text("Group information").font(.title3.weight(.semibold))
                Text(model.roster.groupsLoaded ? "signal-cli has no details for this group." : "Loading …").foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 80)
                HStack { Spacer(); Button("Close") { dismiss() }.keyboardShortcut(.cancelAction) }
            }
        }
        .padding(20)
        .frame(width: 460)
        .task {
            await model.refreshGroup(id)
            if let g = model.roster.groups[key] {
                name = g.name
                about = g.description
            }
        }
        .sheet(isPresented: $addShown) { AddMembersSheet(key: key) }
    }

    @ViewBuilder
    private func content(_ g: GroupInfo, _ c: Conversation) -> some View {
        let me = model.account
        let admin = g.canAdminister(me)
        let canEdit = g.isMember && g.canEditDetails(me)
        HStack(spacing: 12) {
            AvatarView(image: model.avatarImage(c), size: 52)
            VStack(alignment: .leading, spacing: 2) {
                Text(g.name.isEmpty ? "Group" : g.name).font(.title3.weight(.semibold)).lineLimit(1)
                Text("\(g.members.count) member\(g.members.count == 1 ? "" : "s")" + (g.isMember ? "" : " · you left"))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
        }

        if canEdit {
            TextField("Group name", text: $name).textFieldStyle(.roundedBorder)
            TextField("Description", text: $about, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(1...4)
            let newName = name.trimmingCharacters(in: .whitespacesAndNewlines)
            let newAbout = about.trimmingCharacters(in: .whitespacesAndNewlines)
            if (newName != g.name && !newName.isEmpty) || newAbout != g.description {
                HStack {
                    Spacer()
                    Button("Save") {
                        run(GroupParams.details(from: g, name: newName, description: newAbout))
                    }
                    .disabled(busy)
                }
            }
        } else if !g.description.isEmpty {
            Text(g.description).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
        }

        HStack {
            Text("Members").font(.headline)
            Spacer()
            Button { addShown = true } label: { Label("Add members …", systemImage: "person.badge.plus") }
                .disabled(busy || !g.isMember || !g.canAddMembers(me))
        }
        List {
            ForEach(g.members, id: \.self) { m in memberRow(m, g, admin: admin) }
            if !g.pending.isEmpty {
                Section("Invited") {
                    ForEach(g.pending, id: \.self) { m in
                        HStack {
                            Text(model.memberName(m.id)).lineLimit(1)
                            Spacer()
                            if admin { Button("Cancel invite") { run(GroupParams.removeMembers([m.id])) }.buttonStyle(.borderless) }
                        }
                    }
                }
            }
            if !g.requesting.isEmpty {
                Section("Join requests") {
                    ForEach(g.requesting, id: \.self) { m in
                        HStack {
                            Text(model.memberName(m.id)).lineLimit(1)
                            Spacer()
                            if admin {
                                Button("Approve") { run(GroupParams.addMembers([m.id])) }.buttonStyle(.borderless)
                                Button("Deny") { run(GroupParams.removeMembers([m.id])) }.buttonStyle(.borderless)
                            }
                        }
                    }
                }
            }
        }
        .frame(height: 220)

        inviteLink(g, admin: admin)

        if let error { Text(error).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true) }

        HStack {
            if busy { ProgressView().controlSize(.small) }
            Button { Task { await model.toggleBlocked(key) } } label: {
                Text(model.isBlocked(key) ? "Unblock group" : "Block group …")
            }
            .disabled(!model.connected)
            Button("Leave group …", role: .destructive) {
                Task {
                    await model.leaveGroup(key)
                    if model.roster.groups[key]?.isMember != true { dismiss() }
                }
            }
            .disabled(!model.connected || !g.isMember)
            Spacer()
            Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
        }
    }

    private func memberRow(_ m: GroupMember, _ g: GroupInfo, admin: Bool) -> some View {
        let isMe = model.isSelf(m.id)
        return HStack(spacing: 8) {
            Image(systemName: "person.circle").foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 0) {
                Text(model.memberName(m.id)).lineLimit(1)
                if model.memberName(m.id) != m.id, !isMe { Text(m.id).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
            }
            Spacer()
            if m.isAdmin {
                Text("Admin").font(.caption2.weight(.semibold)).padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Capsule().fill(Theme.signalBlue.opacity(0.15))).foregroundStyle(Theme.signalBlue)
            }
            if admin && !isMe {
                Menu {
                    if m.isAdmin {
                        Button("Remove admin") { run(GroupParams.demote([m.id])) }
                    } else {
                        Button("Make admin") { run(GroupParams.promote([m.id])) }
                    }
                    Button("Remove from group", role: .destructive) { run(GroupParams.removeMembers([m.id])) }
                } label: { Image(systemName: "ellipsis.circle") }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .disabled(busy)
            }
        }
    }

    @ViewBuilder
    private func inviteLink(_ g: GroupInfo, admin: Bool) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Invite link").font(.headline)
            if g.inviteLinkEnabled {
                Text(g.inviteLink).font(.caption.monospaced()).lineLimit(2).textSelection(.enabled)
                HStack {
                    Button("Copy") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(g.inviteLink, forType: .string)
                        model.showFlash("Invite link copied.", seconds: 3)
                    }
                    if admin {
                        Button("Reset link") { run(GroupParams.resetLink) }
                        Button("Turn off") { run(GroupParams.link(.disabled)) }
                    }
                }
                .disabled(busy)
            } else {
                HStack {
                    Text("The invite link is off.").foregroundStyle(.secondary)
                    Spacer()
                    if admin && g.isMember {
                        Button("Turn on") { run(GroupParams.link(.enabled)) }.disabled(busy)
                    }
                }
            }
        }
    }

    private func run(_ changes: JSON, then: @escaping () -> Void = {}) {
        guard !changes.isEmpty else {
            then()
            return
        }
        busy = true
        error = nil
        Task {
            let err = await model.updateGroup(id, changes)
            busy = false
            if let err { error = err } else { then() }
        }
    }
}

// MARK: - Add members

struct AddMembersSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let key: String
    @State private var selection: [String] = []
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        let existing = Set((model.roster.groups[key]?.members ?? []).flatMap { [$0.number, $0.uuid] }.filter { !$0.isEmpty })
        VStack(alignment: .leading, spacing: 10) {
            Text("Add members").font(.title3.weight(.semibold))
            ContactPicker(selection: $selection, exclude: existing).frame(height: 280)
            if let error { Text(error).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true) }
            HStack {
                if busy { ProgressView().controlSize(.small) }
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Add") {
                    busy = true
                    error = nil
                    Task {
                        let err = await model.updateGroup(String(key.dropFirst(2)), GroupParams.addMembers(selection))
                        busy = false
                        if let err { error = err } else { dismiss() }
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(selection.isEmpty || busy)
            }
        }
        .padding(20)
        .frame(width: 420)
    }
}
