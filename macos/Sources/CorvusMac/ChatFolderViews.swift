import CorvusCore
import SwiftUI

/// Chat folders and the unread filter of the chat list (local only). The definitions are settings; the chats
/// picked for a folder are stored with the chat in the encrypted history (`Conversation.folders`).
@MainActor @Observable
final class ChatFolderStore {
    static let shared = ChatFolderStore()

    private static let foldersKey = "chatList.folders"
    private static let selectedKey = "chatList.folder"
    @ObservationIgnored private let defaults: UserDefaults

    private(set) var folders: [ChatFolder]
    /// The folder tab shown; nil = all chats.
    var selectedId: String? {
        didSet { if selectedId != oldValue { defaults.set(selectedId, forKey: Self.selectedKey) } }
    }
    /// The unread filter button in the search field.
    var unreadOnly = false
    /// While an unread filter is on, the open chat stays listed after it was read (as in Signal Desktop).
    var keepKey: String?
    /// The folder editor sheet of the main window.
    var editing: ChatFolderEditRequest?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        folders = ChatFolder.decode(defaults.data(forKey: Self.foldersKey))
        let selected = defaults.string(forKey: Self.selectedKey)
        selectedId = folders.contains { $0.id == selected } ? selected : nil
    }

    var selected: ChatFolder? { selectedId.flatMap { id in folders.first { $0.id == id } } }
    var filtersUnread: Bool { unreadOnly || selected?.onlyUnread == true }
    var isFiltering: Bool { unreadOnly || selected != nil }

    /// The rows the chat list shows with the selected folder and the unread filter (archived chats: all).
    func visible(_ items: [ChatListItem], archived: Bool, keep: String? = nil) -> [ChatListItem] {
        guard !archived else { return items }
        return ChatListFilter.apply(items, facts: \.folderFacts, folder: selected, unreadOnly: unreadOnly,
                                    keep: filtersUnread ? (keep ?? keepKey) : nil)
    }

    func save(_ folder: ChatFolder) {
        var list = folders
        if let i = list.firstIndex(where: { $0.id == folder.id }) { list[i] = folder } else { list.append(folder) }
        store(list)
    }

    func remove(_ id: String) {
        store(folders.filter { $0.id != id })
        if selectedId == id { selectedId = nil }
    }

    func move(from source: IndexSet, to destination: Int) {
        var list = folders
        list.move(fromOffsets: source, toOffset: destination)
        store(list)
    }

    private func store(_ list: [ChatFolder]) {
        guard list != folders else { return }
        folders = list
        defaults.set(ChatFolder.encode(list), forKey: Self.foldersKey)
    }
}

/// An open folder editor: a copy of the folder and the chats picked for it.
struct ChatFolderEditRequest: Identifiable {
    let id = UUID()
    var folder: ChatFolder
    var isNew: Bool
    /// A chat picked from the start (a new folder made from a chat's context menu).
    var pick: String?
}

extension ChatListItem {
    var folderFacts: ChatFolderFacts {
        ChatFolderFacts(key: key, isGroup: isGroup, unread: unread > 0 || markedUnread, muted: muted, folders: folders)
    }
}

extension AppModel {
    /// Picks a chat for a folder or takes it out.
    func setFolder(_ key: String, _ folderId: String, _ member: Bool) {
        guard let c = chats.convs[key], c.folders.contains(folderId) != member else { return }
        if let rec = chats.setFolder(key, folder: folderId, member: member) { persist(rec) }
    }

    func deleteFolder(_ folder: ChatFolder) async {
        guard await Dialogs.confirm("Delete folder", "Delete the folder “\(folder.name)”? Its chats are not deleted.",
                                    ok: "Delete", destructive: true) else { return }
        ChatFolderStore.shared.remove(folder.id)
        guard chats.convs.values.contains(where: { $0.folders.contains(folder.id) }) else { return }
        persist(chats.removeFolder(folder.id))
    }

    /// Chats picked for a folder.
    func folderMembers(_ folderId: String) -> Set<String> {
        Set(chats.convs.values.filter { $0.folders.contains(folderId) }.map(\.key))
    }
}

// MARK: - Chat list

/// Folder tabs above the chat list (only when there are folders besides "All").
struct ChatFolderTabs: View {
    @Environment(AppModel.self) private var model
    let items: [ChatListItem]

    var body: some View {
        let store = ChatFolderStore.shared
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                tab(nil, "All")
                ForEach(store.folders) { f in
                    tab(f, f.name)
                        .contextMenu {
                            Button("Edit folder …") { store.editing = ChatFolderEditRequest(folder: f, isNew: false) }
                            Button("Delete folder …", role: .destructive) { Task { await model.deleteFolder(f) } }
                        }
                }
            }
            .padding(.horizontal, 12)
        }
        .padding(.bottom, 6)
    }

    private func tab(_ folder: ChatFolder?, _ title: String) -> some View {
        let store = ChatFolderStore.shared
        let selected = store.selectedId == folder?.id
        let unread = ChatListFilter.unreadChats(items, facts: \.folderFacts, folder: folder)
        return Button {
            if store.selectedId != folder?.id { store.selectedId = folder?.id }
        } label: {
            HStack(spacing: 4) {
                Text(title).lineLimit(1)
                if unread > 0 {
                    Text("\(unread)")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 5)
                        .frame(minWidth: 16, minHeight: 16)
                        .background(Capsule().fill(Theme.signalBlue))
                }
            }
            .font(.system(size: 12, weight: selected ? .semibold : .regular))
            .foregroundStyle(selected ? Color.primary : Color.secondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(Capsule().fill(selected ? Theme.selection : Color.clear))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// The unread filter button inside the chat search field.
struct ChatListUnreadFilterButton: View {
    var body: some View {
        let store = ChatFolderStore.shared
        Button { store.unreadOnly.toggle() } label: {
            Image(systemName: store.unreadOnly ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
                .foregroundStyle(store.unreadOnly ? Theme.signalBlue : Color.secondary)
        }
        .buttonStyle(.borderless)
        .help(store.unreadOnly ? "Show all chats" : "Show unread chats only")
        .accessibilityLabel("Unread chats only")
        .accessibilityAddTraits(store.unreadOnly ? .isSelected : [])
    }
}

/// Keeps the open chat listed while an unread filter is on; observes the open chat on its own, so the chat
/// list does not depend on it.
struct KeepOpenChatListed: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let store = ChatFolderStore.shared
        Color.clear
            .onChange(of: model.current) { _, key in if store.filtersUnread { update(key) } }
            .onChange(of: store.filtersUnread) { _, on in if on { update(model.current) } }
    }

    private func update(_ key: String?) {
        let store = ChatFolderStore.shared
        if store.keepKey != key { store.keepKey = key }
    }
}

/// The empty chat list text while a folder or the unread filter is on.
@MainActor
func chatListEmptyText(query: String) -> String {
    let store = ChatFolderStore.shared
    if !query.isEmpty { return "No chats match “\(query)”" }
    if store.unreadOnly { return "No unread chats" }
    if store.selected != nil { return "No chats in this folder" }
    return "No chats yet"
}

/// "Add to folder" submenu of a chat.
struct FolderMenu: View {
    @Environment(AppModel.self) private var model
    let conversation: Conversation

    var body: some View {
        let c = conversation
        let store = ChatFolderStore.shared
        Menu {
            ForEach(store.folders) { f in
                Toggle(f.name, isOn: Binding(get: { c.folders.contains(f.id) }, set: { model.setFolder(c.key, f.id, $0) }))
            }
            if !store.folders.isEmpty { Divider() }
            Button("New folder …") {
                store.editing = ChatFolderEditRequest(folder: ChatFolder(name: ""), isNew: true, pick: c.key)
            }
        } label: { Label("Add to folder", systemImage: "folder.badge.plus") }
    }
}

/// The folder editor sheet of the main window.
struct ChatFolderSheets: ViewModifier {
    func body(content: Content) -> some View {
        @Bindable var store = ChatFolderStore.shared
        content.sheet(item: $store.editing) { request in
            ChatFolderEditor(request: request)
        }
    }
}

// MARK: - Editor

struct ChatFolderEditor: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let request: ChatFolderEditRequest

    @State private var folder = ChatFolder(name: "")
    @State private var picked: Set<String> = []
    @State private var initial: Set<String> = []
    @State private var search = ""
    @State private var loaded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(request.isNew ? "New folder" : "Edit folder").font(.title3.weight(.semibold))
            TextField("Folder name", text: $folder.name).textFieldStyle(.roundedBorder)
            VStack(alignment: .leading, spacing: 6) {
                Toggle("All 1:1 chats", isOn: $folder.includeDirect)
                Toggle("All groups", isOn: $folder.includeGroups)
                Toggle("Only unread chats", isOn: $folder.onlyUnread)
                Toggle("Include muted chats", isOn: $folder.includeMuted)
            }
            HStack {
                Text("Chats").font(.headline)
                Spacer()
                Text("\(picked.count) picked").foregroundStyle(.secondary).font(.caption)
            }
            TextField("Search", text: $search).textFieldStyle(.roundedBorder)
            List {
                ForEach(candidates, id: \.key) { c in
                    Toggle(isOn: Binding(get: { picked.contains(c.key) },
                                         set: { if $0 { picked.insert(c.key) } else { picked.remove(c.key) } })) {
                        HStack(spacing: 8) {
                            AvatarView(image: model.avatarImage(c), size: 22)
                            Text(model.visibleTitle(c)).lineLimit(1)
                        }
                    }
                    .toggleStyle(.checkbox)
                }
            }
            .listStyle(.bordered)
            .frame(minHeight: 220)
            HStack {
                if !request.isNew {
                    Button("Delete folder …", role: .destructive) {
                        let f = request.folder
                        close()
                        Task { await model.deleteFolder(f) }
                    }
                }
                Spacer()
                Button("Cancel") { close() }.keyboardShortcut(.cancelAction)
                Button("Save") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(folder.name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 420, height: 560)
        .onAppear(perform: load)
    }

    /// All chats, the picked ones first, matching the search.
    private var candidates: [Conversation] {
        let all = model.chats.sortedConversations(archived: false) + model.chats.sortedConversations(archived: true)
        let q = search.trimmingCharacters(in: .whitespaces)
        let shown = q.isEmpty ? all : all.filter { model.visibleTitle($0).localizedCaseInsensitiveContains(q) }
        return shown.filter { initial.contains($0.key) } + shown.filter { !initial.contains($0.key) }
    }

    private func load() {
        guard !loaded else { return }
        loaded = true
        folder = request.folder
        initial = request.isNew ? [] : model.folderMembers(request.folder.id)
        picked = initial
        if let pick = request.pick { picked.insert(pick); initial.insert(pick) }
    }

    private func save() {
        folder.name = folder.name.trimmingCharacters(in: .whitespaces)
        ChatFolderStore.shared.save(folder)
        let before = request.isNew ? Set<String>() : model.folderMembers(folder.id)
        for key in picked.subtracting(before) { model.setFolder(key, folder.id, true) }
        for key in before.subtracting(picked) { model.setFolder(key, folder.id, false) }
        close()
    }

    private func close() { dismiss() }
}

// MARK: - Settings

/// Settings → Chats: the chat folders.
struct ChatFolderSettings: View {
    @Environment(AppModel.self) private var model
    @State private var editing: ChatFolderEditRequest?

    var body: some View {
        let store = ChatFolderStore.shared
        let missing = ChatFolder.Preset.allCases.filter { p in !store.folders.contains(where: p.matches) }
        Form {
            Section("Chat folders") {
                ForEach(store.folders) { f in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(f.name)
                            Text(summary(f)).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Edit …") { editing = ChatFolderEditRequest(folder: f, isNew: false) }
                        Button { Task { await model.deleteFolder(f) } } label: { Image(systemName: "trash") }
                            .buttonStyle(.borderless)
                            .iconHelp("Delete folder")
                    }
                }
                .onMove { store.move(from: $0, to: $1) }
                Button("New folder …") { editing = ChatFolderEditRequest(folder: ChatFolder(name: ""), isNew: true) }
            }
            if !missing.isEmpty {
                Section("Suggested folders") {
                    ForEach(missing, id: \.self) { p in
                        HStack {
                            Text(p.name)
                            Spacer()
                            Button("Add") { store.save(p.folder()) }
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .sheet(item: $editing) { ChatFolderEditor(request: $0) }
    }

    private func summary(_ f: ChatFolder) -> String {
        var parts: [String] = []
        if f.includeDirect && f.includeGroups { parts.append("All chats") }
        else if f.includeDirect { parts.append("1:1 chats") }
        else if f.includeGroups { parts.append("Groups") }
        let n = model.folderMembers(f.id).count
        if n > 0 { parts.append(n == 1 ? "1 picked chat" : "\(n) picked chats") }
        if f.onlyUnread { parts.append("unread only") }
        if !f.includeMuted { parts.append("without muted") }
        return parts.isEmpty ? "Empty" : parts.joined(separator: " · ")
    }
}
