import AppKit
import CorvusCore
import SwiftUI

/// Sheets for "New group …", "New conversation …" and the new admin when leaving. Applied once to the main window.
struct GroupSheets: ViewModifier {
    @Environment(AppModel.self) private var model

    func body(content: Content) -> some View {
        content
            .sheet(isPresented: Binding(get: { model.newGroupShown }, set: { model.newGroupShown = $0 })) { NewGroupSheet() }
            .sheet(item: Binding(get: { model.successorPick }, set: { if $0 == nil { model.finishSuccessorPick(nil) } })) { pick in
                SuccessorSheet(pick: pick)
            }
            .sheet(item: Binding(get: { GroupExtras.shared.joinRequest }, set: { GroupExtras.shared.joinRequest = $0 })) { request in
                JoinGroupSheet(request: request)
            }
            .sheet(isPresented: Binding(get: { GroupExtras.shared.stickerCreatorShown },
                                        set: { GroupExtras.shared.stickerCreatorShown = $0 })) {
                StickerPackCreatorSheet()
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

/// The group part of the info panel: name and description, members, invite link, leaving.
struct GroupInfoPanel: View {
    @Environment(AppModel.self) private var model
    let key: String
    @State private var name = ""
    @State private var about = ""
    @State private var busy = false
    @State private var error: String?
    @State private var addShown = false
    @State private var filter = ""

    private var id: String { String(key.dropFirst(2)) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let g = model.roster.groups[key] {
                content(g)
            } else {
                Text(model.roster.groupsLoaded ? "signal-cli has no details for this group." : "Loading …")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 60)
            }
        }
        .task(id: key) {
            filter = ""
            error = nil
            if let g = model.roster.groups[key] { name = g.name; about = g.description }
            await model.refreshGroup(id)
            if let g = model.roster.groups[key] { name = g.name; about = g.description }
        }
        .sheet(isPresented: $addShown) { AddMembersSheet(key: key) }
    }

    @ViewBuilder
    private func content(_ g: GroupInfo) -> some View {
        let me = model.account
        let admin = g.canAdminister(me)
        let canEdit = g.isMember && g.canEditDetails(me)

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
            GroupPhotoButton(key: key)
        } else if !g.description.isEmpty {
            Text(g.description).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
        }

        Divider()
        HStack {
            Text("\(g.members.count) member\(g.members.count == 1 ? "" : "s")").font(.headline)
            Spacer()
            Button { addShown = true } label: { Label("Add members …", systemImage: "person.badge.plus") }
                .buttonStyle(.borderless)
                .disabled(busy || !g.isMember || !g.canAddMembers(me))
        }
        if g.members.count > People.filterThreshold {
            SearchField(text: $filter, prompt: "Search members", autofocus: false)
        }
        let members = People.sortedMembers(g.members, isSelf: { model.isSelf($0.id) }, name: { model.memberName($0.id) })
            .map { (member: $0, person: model.memberPerson($0)) }
            .filter { People.matches(filter, name: $0.person.title, detail: $0.person.detail, number: $0.member.number) }
        LazyVStack(alignment: .leading, spacing: 0) {
            ForEach(members, id: \.member) { m in memberRow(m.member, m.person, admin: admin) }
        }
        .overlay {
            if members.isEmpty && !filter.isEmpty { Text("No one matches “\(filter)”").foregroundStyle(.secondary) }
        }

        if !g.pending.isEmpty {
            Text("Invited").font(.headline).padding(.top, 4)
            ForEach(g.pending, id: \.self) { m in
                HStack(spacing: 4) {
                    PickerRow(person: model.memberPerson(m))
                    if admin { Button("Cancel invite") { run(GroupParams.removeMembers([m.id])) }.buttonStyle(.borderless) }
                }
            }
        }
        if !g.requesting.isEmpty {
            Text("Join requests").font(.headline).padding(.top, 4)
            ForEach(g.requesting, id: \.self) { m in
                HStack(spacing: 4) {
                    PickerRow(person: model.memberPerson(m))
                    if admin {
                        Button("Approve") { run(GroupParams.addMembers([m.id])) }.buttonStyle(.borderless)
                        Button("Deny") { run(GroupParams.removeMembers([m.id])) }.buttonStyle(.borderless)
                    }
                }
            }
        }

        if !g.banned.isEmpty { BannedMembersSection(group: g, admin: admin).padding(.top, 4) }

        Divider()
        GroupLinkSection(group: g, admin: admin)
        if admin && g.isMember {
            Divider()
            GroupPermissionsSection(group: g)
        }

        if let error { Text(error).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true) }
        if busy { ProgressView().controlSize(.small) }
    }

    /// A member; a click opens the 1:1 chat with them.
    private func memberRow(_ m: GroupMember, _ p: PickerPerson, admin: Bool) -> some View {
        let isMe = model.isSelf(m.id)
        return HStack(spacing: 4) {
            PickerRow(person: p)
                .onTapGesture { if !isMe { model.startConversation(p.key) } }
                .help(isMe ? "" : "Message \(p.title)")
            if isMe {
                OwnMemberLabelButton(key: key, member: m)
            } else if !m.labelText.isEmpty {
                MemberLabelBadge(text: m.labelText)
            }
            if m.isAdmin {
                Text("Admin").font(.caption2.weight(.semibold)).padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Capsule().fill(Theme.signalBlue.opacity(0.15))).foregroundStyle(Theme.signalBlue)
            }
            if admin && !isMe {
                Menu {
                    Button("Message \(p.title)") { model.startConversation(p.key) }
                    Divider()
                    if m.isAdmin {
                        Button("Remove admin") { run(GroupParams.demote([m.id])) }
                    } else {
                        Button("Make admin") { run(GroupParams.promote([m.id])) }
                    }
                    Button("Remove from group", role: .destructive) { run(GroupParams.removeMembers([m.id])) }
                    Button("Remove and ban", role: .destructive) {
                        run(GroupParams.removeMembers([m.id]).merging(GroupParams.ban([m.id])) { a, _ in a })
                    }
                } label: { Image(systemName: "ellipsis.circle") }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .disabled(busy)
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
