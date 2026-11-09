import CorvusCore
import SwiftUI

extension AppModel {
    /// Chat title for the header and the info panel: never a raw UUID.
    func visibleTitle(_ c: Conversation) -> String {
        let t = title(c)
        if c.isGroup { return t.isEmpty || People.isServiceId(t) ? "Group" : t }
        return People.displayName(names: [t], number: People.isPhoneNumber(c.key) ? c.key : "")
    }

    /// Number or username under the title of a 1:1 chat; empty when the title shows it or it is a UUID.
    func chatDetail(_ c: Conversation) -> String {
        c.isGroup || c.key == account ? "" : People.detail(title: visibleTitle(c), address: c.key)
    }
}

/// The info panel (inspector) of the open chat: ⌘I or a click on the chat header.
struct ConversationInfoPanel: View {
    @Environment(AppModel.self) private var model
    let conversation: Conversation

    var body: some View {
        let c = conversation
        let isSelf = c.key == model.account
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                header(c)
                if c.isGroup {
                    GroupInfoPanel(key: c.key)
                } else if !isSelf {
                    NicknameField(conversation: c)
                    Button { model.safetyNumberKey = c.key } label: { Label("View safety number …", systemImage: "checkmark.shield") }
                        .buttonStyle(.borderless)
                        .disabled(!model.connected)
                }
                Divider()
                settings(c)
                Divider()
                SharedMediaSection(conversation: c)
                if !isSelf {
                    Divider()
                    actions(c)
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func header(_ c: Conversation) -> some View {
        let detail = c.isGroup ? groupLine(c) : model.chatDetail(c)
        return VStack(spacing: 6) {
            AvatarView(image: model.avatarImage(c), size: 72)
            Text(model.visibleTitle(c)).font(.title3.weight(.semibold)).multilineTextAlignment(.center).textSelection(.enabled)
            if !detail.isEmpty {
                Text(detail).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func groupLine(_ c: Conversation) -> String {
        guard let g = model.roster.groups[c.key] else { return "Group" }
        return "Group" + (g.isMember ? "" : " · you left")
    }

    @ViewBuilder
    private func settings(_ c: Conversation) -> some View {
        let choices = AppModel.expirationChoices.contains { $0.1 == c.expirationSeconds }
            ? AppModel.expirationChoices : AppModel.expirationChoices + [("\(c.expirationSeconds) s", c.expirationSeconds)]
        Picker(selection: Binding(get: { c.expirationSeconds }, set: { model.setExpiration(c.key, $0) })) {
            ForEach(choices, id: \.1) { label, seconds in Text(label).tag(seconds) }
        } label: {
            Label("Disappearing messages", systemImage: "timer")
        }
        .disabled(!model.connected)
        MuteInfoRow(conversation: c)
        ChatWallpaperRow(conversation: c)
    }

    @ViewBuilder
    private func actions(_ c: Conversation) -> some View {
        let blocked = model.isBlocked(c.key)
        Button(role: blocked ? nil : .destructive) { Task { await model.toggleBlocked(c.key) } } label: {
            Label(blocked ? (c.isGroup ? "Unblock group" : "Unblock contact") : (c.isGroup ? "Block group …" : "Block contact …"),
                  systemImage: blocked ? "checkmark.circle" : "nosign")
        }
        .buttonStyle(.borderless)
        .disabled(!model.connected)
        if c.isGroup {
            Button(role: .destructive) { Task { await model.leaveGroup(c.key) } } label: {
                Label("Leave group …", systemImage: "rectangle.portrait.and.arrow.right")
            }
            .buttonStyle(.borderless)
            .disabled(!model.connected || model.roster.groups[c.key]?.isMember != true)
        }
    }
}

/// The local nickname of a contact, edited in place; saved on Return or when the field loses focus.
private struct NicknameField: View {
    @Environment(AppModel.self) private var model
    let conversation: Conversation
    @State private var text = ""
    @State private var editingKey = ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Nickname").font(.headline)
            TextField("Nickname", text: $text, prompt: Text("Add a nickname"))
                .textFieldStyle(.roundedBorder)
                .focused($focused)
                .onSubmit(save)
        }
        .onChange(of: conversation.key, initial: true) { load() }
        .onChange(of: conversation.localNickname) { if !focused { load() } }
        .onChange(of: focused) { if !focused { save() } }
        .onChange(of: model.nicknameFocusPending, initial: true) { focusIfRequested() }
    }

    private func load() {
        if focused && !editingKey.isEmpty && editingKey != conversation.key { save() }
        editingKey = conversation.key
        text = conversation.localNickname
    }

    private func save() {
        let n = text.trimmingCharacters(in: .whitespaces)
        guard !editingKey.isEmpty, model.chats.convs[editingKey]?.localNickname != n else { return }
        model.setNickname(editingKey, n)
    }

    private func focusIfRequested() {
        guard model.nicknameFocusPending else { return }
        model.nicknameFocusPending = false
        DispatchQueue.main.async { focused = true }
    }
}

/// The latest photos and videos of the chat; the full gallery opens from here.
private struct SharedMediaSection: View {
    @Environment(AppModel.self) private var model
    let conversation: Conversation

    private struct Item: Identifiable {
        let message: Message
        let index: Int
        var id: String { "\(message.id)#\(index)" }
    }

    var body: some View {
        let items = recent(6)
        VStack(alignment: .leading, spacing: 8) {
            Text("Shared media").font(.headline)
            if !items.isEmpty {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 3), spacing: 6) {
                    ForEach(items) { it in
                        Button { model.openAttachment(it.message, it.index) } label: {
                            GalleryTile(message: it.message, index: it.index, size: 80)
                        }
                        .buttonStyle(.plain)
                        .help(it.message.time.formatted())
                    }
                }
            }
            Button("All media, files and links …") { model.galleryShown = true }
                .buttonStyle(.borderless)
        }
    }

    private func recent(_ limit: Int) -> [Item] {
        var out: [Item] = []
        for m in conversation.msgs.reversed() where !m.deleted && !m.viewOnce {
            for (i, a) in m.attachments.enumerated() where !a.isSticker && (a.isImage || a.isVideo) {
                out.append(Item(message: m, index: i))
                if out.count == limit { return out }
            }
        }
        return out
    }
}
