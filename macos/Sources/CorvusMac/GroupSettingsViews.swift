import AppKit
import CorvusCore
import SwiftUI

// MARK: - Group photo

/// "Change photo …" for members who may edit the group details. signal-cli can set a group picture but has
/// no option to remove one, so there is no "Remove".
struct GroupPhotoButton: View {
    @Environment(AppModel.self) private var model
    let key: String
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Button { choose() } label: { Label("Change group photo …", systemImage: "camera") }
                    .buttonStyle(.borderless)
                    .disabled(busy || !model.connected)
                if busy { ProgressView().controlSize(.small) }
            }
            if let error { InlineError(text: error) }
        }
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png, .jpeg, .gif, .webP, .heic]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        busy = true
        error = nil
        Task {
            error = await model.setGroupAvatar(key, file: url).map { "Could not change the group photo: \($0)" }
            busy = false
        }
    }
}

// MARK: - Permissions

/// Who may add members, edit the group info and send messages (admins only), as in Signal's group settings.
struct GroupPermissionsSection: View {
    @Environment(AppModel.self) private var model
    let group: GroupInfo
    @State private var error: String?

    private static let rows: [(GroupPermissionKind, String)] = [
        (.addMembers, "Add members"),
        (.editDetails, "Edit group info"),
        (.sendMessages, "Send messages"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Permissions").font(.headline)
            ForEach(Self.rows, id: \.1) { kind, title in
                Picker(title, selection: Binding(get: { kind.value(in: group) }, set: { set(kind, $0) })) {
                    Text("All members").tag(GroupPermission.everyMember)
                    Text("Only admins").tag(GroupPermission.onlyAdmins)
                }
                .pickerStyle(.menu)
                .disabled(!model.connected)
            }
            if let error { InlineError(text: error) }
        }
    }

    private func set(_ kind: GroupPermissionKind, _ value: GroupPermission) {
        guard kind.value(in: group) != value else { return }
        error = nil
        Task {
            if let e = await model.setGroupPermission(group.key, kind, value) { error = "Could not change the permission: \(e)" }
        }
    }
}

// MARK: - Group link

/// The group link: on/off, admin approval, copy and reset (admins), or just copy for everyone else.
struct GroupLinkSection: View {
    @Environment(AppModel.self) private var model
    let group: GroupInfo
    let admin: Bool
    @State private var busy = false
    @State private var error: String?
    /// Shown while a change is on its way (the toggle answers at once).
    @State private var pendingOn: Bool?
    @State private var pendingApproval: Bool?

    var body: some View {
        let g = group
        let on = pendingOn ?? g.inviteLinkEnabled
        let approval = pendingApproval ?? model.linkNeedsApproval(g)
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Group link").font(.headline)
                Spacer()
                if busy { ProgressView().controlSize(.small) }
                if admin && g.isMember {
                    Toggle("Group link", isOn: Binding(get: { on }, set: { turn($0, approval: approval) }))
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .controlSize(.small)
                        .disabled(busy || !model.connected)
                }
            }
            if on && !g.inviteLink.isEmpty {
                Text(g.inviteLink).font(.caption.monospaced()).lineLimit(2).truncationMode(.middle).textSelection(.enabled)
                HStack(spacing: 12) {
                    Button { copy(g.inviteLink) } label: { Label("Copy link", systemImage: "doc.on.doc") }
                    if admin {
                        Button { reset() } label: { Label("Reset link …", systemImage: "arrow.clockwise") }
                            .disabled(busy || !model.connected)
                    }
                }
                .buttonStyle(.borderless)
            } else if !on && !admin {
                Text("The group link is off.").font(.callout).foregroundStyle(.secondary)
            }
            if admin && on {
                Toggle("Require admin approval", isOn: Binding(get: { approval }, set: { setApproval($0) }))
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .disabled(busy || !model.connected)
            }
            if let error { InlineError(text: error) }
        }
    }

    private func copy(_ link: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(link, forType: .string)
        model.showFlash("Group link copied.", seconds: 3)
    }

    private func turn(_ on: Bool, approval: Bool) {
        change(on ? (approval ? .enabledWithApproval : .enabled) : .disabled, on: on)
    }

    private func setApproval(_ value: Bool) {
        pendingApproval = value
        change(value ? .enabledWithApproval : .enabled, on: true)
    }

    private func change(_ state: GroupLinkState, on: Bool) {
        pendingOn = on
        busy = true
        error = nil
        Task {
            if let e = await model.setGroupLink(group.key, state) { error = "Could not change the group link: \(e)" }
            busy = false
            pendingOn = nil
            pendingApproval = nil
        }
    }

    private func reset() {
        Task {
            guard await Dialogs.confirm("Reset group link?",
                                        "The current link will stop working. People can join with the new link.",
                                        ok: "Reset", destructive: true) else { return }
            busy = true
            error = nil
            let e = await model.updateGroup(String(group.key.dropFirst(2)), GroupParams.resetLink)
            busy = false
            if let e { error = "Could not reset the group link: \(e)" } else { model.showFlash("Group link reset.", seconds: 3) }
        }
    }
}

// MARK: - Banned

/// People who may not rejoin through the link; admins can lift the ban.
struct BannedMembersSection: View {
    @Environment(AppModel.self) private var model
    let group: GroupInfo
    let admin: Bool
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Banned").font(.headline)
            ForEach(group.banned, id: \.self) { m in
                HStack(spacing: 4) {
                    PickerRow(person: model.memberPerson(m))
                    if admin {
                        Button("Unban") { unban(m) }.buttonStyle(.borderless).disabled(!model.connected)
                    }
                }
            }
            if let error { InlineError(text: error) }
        }
    }

    private func unban(_ m: GroupMember) {
        error = nil
        Task {
            let key = group.key
            let e = await model.updateGroupOptimistically(key, GroupParams.unban([m.id])) { g in g.banned.removeAll { $0 == m } }
            if let e { error = "Could not unban: \(e)" }
        }
    }
}

// MARK: - Member labels

/// A member label in the member list.
struct MemberLabelBadge: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.caption2)
            .lineLimit(1)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(Color.secondary.opacity(0.15)))
            .foregroundStyle(.secondary)
            .help("Member label")
    }
}

/// Our own label in a group: shown on our row, edited in a popover (emoji and text).
struct OwnMemberLabelButton: View {
    @Environment(AppModel.self) private var model
    let key: String
    let member: GroupMember
    @State private var shown = false

    var body: some View {
        Button { shown = true } label: {
            if member.labelText.isEmpty {
                Image(systemName: "tag")
            } else {
                MemberLabelBadge(text: member.labelText)
            }
        }
        .buttonStyle(.borderless)
        .help(member.labelText.isEmpty ? "Add a member label" : "Edit your member label")
        .disabled(!model.connected)
        .popover(isPresented: $shown, arrowEdge: .bottom) {
            MemberLabelEditor(key: key, member: member) { shown = false }
        }
    }
}

private struct MemberLabelEditor: View {
    @Environment(AppModel.self) private var model
    let key: String
    let member: GroupMember
    let done: () -> Void
    @State private var text = ""
    @State private var emoji = ""
    @State private var emojiShown = false
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Member label").font(.headline)
            HStack(spacing: 6) {
                Button { emojiShown = true } label: {
                    Group {
                        if emoji.isEmpty { Image(systemName: "face.smiling") } else { Text(emoji) }
                    }
                    .frame(width: 22, height: 22)
                }
                .help("Choose an emoji")
                .popover(isPresented: $emojiShown) {
                    EmojiPicker { e in
                        emoji = e
                        emojiShown = false
                    }
                    .padding(8)
                    .frame(width: 340)
                }
                TextField("Label", text: $text, prompt: Text("e.g. Organiser"))
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(save)
            }
            if let error { InlineError(text: error) }
            HStack {
                if !member.labelText.isEmpty {
                    Button("Remove", role: .destructive) {
                        text = ""
                        emoji = ""
                        save()
                    }
                }
                if busy { ProgressView().controlSize(.small) }
                Spacer()
                Button("Cancel", action: done).keyboardShortcut(.cancelAction)
                Button("Save", action: save)
                    .keyboardShortcut(.defaultAction)
                    .disabled(busy || (text == member.label && emoji == member.labelEmoji))
            }
        }
        .padding(14)
        .frame(width: 300)
        .onAppear {
            text = member.label
            emoji = member.labelEmoji
        }
    }

    private func save() {
        busy = true
        error = nil
        Task {
            let e = await model.setOwnMemberLabel(key, text: text, emoji: emoji)
            busy = false
            if let e { error = "Could not set the label: \(e)" } else { done() }
        }
    }
}

/// Labels of the open group's members, for the sender names above bubbles.
private struct GroupMemberLabelsKey: EnvironmentKey {
    static let defaultValue: [String: String] = [:]
}

extension EnvironmentValues {
    var groupMemberLabels: [String: String] {
        get { self[GroupMemberLabelsKey.self] }
        set { self[GroupMemberLabelsKey.self] = newValue }
    }
}

/// Sender name above an incoming group message, followed by the sender's member label.
struct SenderNameLabel: View {
    @Environment(AppModel.self) private var model
    @Environment(\.groupMemberLabels) private var labels
    let message: Message

    var body: some View {
        let name = message.sender.isEmpty ? model.displayName(message.authorKey) : message.sender
        let label = labels[message.authorKey] ?? labels[model.chats.resolveKey(message.authorKey)]
        HStack(spacing: 5) {
            Text(name)
                .font(.caption.weight(.semibold))
                .foregroundStyle(Theme.senderColor(message.authorKey))
            if let label {
                Text(label).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
        }
    }
}

// MARK: - Join by link

/// "Join group via link …" and clicks on signal.group links: the link (pasted or clicked) and a Join button.
/// Nothing about the group can be looked up before joining with signal-cli, so the link itself is shown.
struct JoinGroupSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let request: JoinRequest
    @State private var text = ""
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        let link = GroupInviteLink.find(in: text)
        VStack(alignment: .leading, spacing: 12) {
            Text("Join group").font(.title3.weight(.semibold))
            if request.link == nil {
                TextField("Group link", text: $text, prompt: Text("https://signal.group/#…"))
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { if let link { join(link) } }
                if !text.isEmpty && link == nil {
                    Text("This is not a Signal group link.").font(.caption).foregroundStyle(.secondary)
                }
            } else {
                Text("Join this group? Its members will see your name and photo.")
                    .fixedSize(horizontal: false, vertical: true)
                Text(text).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(2).truncationMode(.middle)
                    .textSelection(.enabled)
            }
            if let error { InlineError(text: error) }
            HStack {
                if busy { ProgressView().controlSize(.small) }
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Join") { if let link { join(link) } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(link == nil || busy || !model.connected)
            }
        }
        .padding(20)
        .frame(width: 440)
        .onAppear {
            if let l = request.link {
                text = l.url
            } else if let s = NSPasteboard.general.string(forType: .string), let l = GroupInviteLink.find(in: s) {
                text = l.url
            }
        }
    }

    private func join(_ link: GroupInviteLink) {
        busy = true
        error = nil
        Task {
            let e = await model.joinGroup(link)
            busy = false
            if let e { error = "Could not join the group: \(e)" } else { dismiss() }
        }
    }
}

/// Red error text under a control.
struct InlineError: View {
    let text: String

    var body: some View {
        Text(text).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
    }
}
