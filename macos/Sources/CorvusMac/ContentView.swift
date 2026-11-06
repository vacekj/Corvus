import AppKit
import CorvusCore
import SwiftUI

struct ContentView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        @Bindable var model = model
        NavigationSplitView {
            Sidebar()
                .navigationSplitViewColumnWidth(min: 240, ideal: 290, max: 420)
        } detail: {
            ZStack(alignment: .top) {
                if let c = model.currentConversation {
                    ChatPane(conversation: c)
                } else {
                    Welcome()
                }
                if let flash = model.flash { Toast(text: flash).padding(.top, 10) }
            }
            .animation(.easeOut(duration: 0.2), value: model.flash)
            .toolbar {
                ToolbarItem(placement: .navigation) {
                    if let c = model.currentConversation { ChatHeader(conversation: c) }
                }
                ToolbarItem(placement: .automatic) {
                    if let c = model.currentConversation, !c.isGroup {
                        Button { Task { await model.startCall(c.key) } } label: { Label("Voice call", systemImage: "phone") }
                            .help("Voice call")
                            .disabled(!model.connected || model.call?.isActive == true)
                    }
                }
                ToolbarItem(placement: .automatic) {
                    if let c = model.currentConversation, c.isGroup {
                        Button { model.showGroupInfo(c.key) } label: { Label("Group info", systemImage: "info.circle") }
                            .help("Group info: members, admins, invite link")
                    }
                }
                ToolbarItem(placement: .automatic) {
                    Button { model.galleryShown = true } label: { Label("Media", systemImage: "photo.on.rectangle") }
                        .help("Media, files and links of this chat")
                        .disabled(model.current == nil)
                }
                ToolbarItem(placement: .automatic) {
                    Button { model.searchVisible ? model.closeSearch() : model.openSearch() } label: {
                        Label("Search", systemImage: "magnifyingglass")
                    }
                    .help("Search this conversation (⌘F)")
                    .disabled(model.current == nil)
                }
            }
        }
        .navigationTitle(model.totalUnread > 0 ? "(\(model.totalUnread)) Corvus" : "Corvus")
        .hidingWindowTitle()
        .tint(Theme.signalBlue)
        .background(WindowAccessor())
        .sheet(isPresented: $model.linkSheetShown) {
            LinkView(executable: model.cli.executable) { model.finishLinking($0) }
        }
        .sheet(isPresented: Binding(get: { model.giphyApiKey != nil }, set: { if !$0 { model.giphyApiKey = nil } })) {
            if let key = model.giphyApiKey {
                GiphyPicker(apiKey: key) { url, analytics in model.sendGif(url: url, analytics: analytics) }
            }
        }
        .sheet(isPresented: Binding(get: { model.safetyNumberKey != nil }, set: { if !$0 { model.safetyNumberKey = nil } })) {
            if let key = model.safetyNumberKey { SafetyNumberSheet(key: key) }
        }
        .sheet(isPresented: Binding(get: { model.forwardMessageId != nil }, set: { if !$0 { model.forwardMessageId = nil } })) {
            if let id = model.forwardMessageId { ForwardSheet(messageId: id) }
        }
        .sheet(isPresented: $model.galleryShown) { MediaGallerySheet() }
        .sheet(isPresented: $model.storiesShown) { StoriesSheet() }
        .modifier(GroupSheets())
        .onAppear {
            model.openMainWindow = {
                openWindow(id: "main")
                MainWindowTracker.shared.window?.makeKeyAndOrderFront(nil)
            }
        }
    }
}

/// Avatar, name and state of the open chat in the window's toolbar.
private struct ChatHeader: View {
    @Environment(AppModel.self) private var model
    let conversation: Conversation

    var body: some View {
        let c = conversation
        HStack(spacing: 10) {
            AvatarView(image: model.avatarImage(c), size: 30)
            VStack(alignment: .leading, spacing: 0) {
                Text(model.title(c)).font(.headline).lineLimit(1)
                HStack(spacing: 6) {
                    if c.isGroup { Text("Group") } else if c.title != c.key { Text(c.key) }
                    if c.expirationSeconds > 0 {
                        Label(AppModel.expirationChoices.first { $0.1 == c.expirationSeconds }?.0 ?? "\(c.expirationSeconds) s",
                              systemImage: "timer")
                    }
                    if c.muted { Label("Muted", systemImage: "bell.slash") }
                    if model.isBlocked(c.key) { Label("Blocked", systemImage: "nosign") }
                }
                .labelStyle(.titleAndIcon)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
        }
        .padding(.horizontal, 4)
    }
}

private struct Welcome: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 14) {
            ZStack {
                Circle().fill(Theme.signalBlue.opacity(0.12)).frame(width: 110, height: 110)
                Image(systemName: "bubble.left.and.bubble.right.fill")
                    .font(.system(size: 44))
                    .foregroundStyle(Theme.signalBlue)
            }
            Text("Welcome to Corvus").font(.title2.weight(.semibold))
            Text(model.historyReady
                    ? (model.connected ? "Choose a chat on the left, or start a new one." : model.statusText)
                    : "Unlocking your chat history …")
                .foregroundStyle(.secondary)
            if model.historyReady {
                Button { Task { await model.newConversation() } } label: {
                    Label("New conversation", systemImage: "square.and.pencil").padding(.horizontal, 6)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(!model.connected)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(model.appearance.backgroundColor)
    }
}

/// Transient status messages ("Sending …", errors) float above the chat.
private struct Toast: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.callout)
            .lineLimit(3)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(Capsule().fill(.regularMaterial))
            .overlay(Capsule().strokeBorder(.separator))
            .shadow(color: .black.opacity(0.15), radius: 8, y: 3)
            .padding(.horizontal, 30)
            .transition(.move(edge: .top).combined(with: .opacity))
    }
}

/// Finds the NSWindow that hosts the SwiftUI view (for sheets, activation and "user is looking").
private struct WindowAccessor: NSViewRepresentable {
    @Environment(AppModel.self) private var model

    func makeNSView(context: Context) -> NSView {
        let v = TrackingView()
        v.model = model
        return v
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    final class TrackingView: NSView {
        weak var model: AppModel?
        private var observer: NSObjectProtocol?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window else { return }
            MainWindowTracker.shared.window = window
            window.setFrameAutosaveName("MainWindow")
            if let observer { NotificationCenter.default.removeObserver(observer) }
            observer = NotificationCenter.default.addObserver(forName: NSWindow.didBecomeKeyNotification, object: window,
                                                              queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.model?.windowActivated() }
            }
        }
    }
}

// MARK: - Sidebar

private struct Sidebar: View {
    @Environment(AppModel.self) private var model
    @State private var filter = ""

    var body: some View {
        let selection = Binding<String?>(get: { model.current }, set: { key in
            guard let key else { return }
            switch key {
            case "::archived": model.showArchived = true
            case "::back": model.showArchived = false
            default: model.openConversation(key)
            }
        })
        let archived = model.chatListItems(archived: true)
        let archivedUnread = archived.reduce(0) { $0 + $1.unread }
        let q = filter.trimmingCharacters(in: .whitespaces)
        let all = model.chatListItems(archived: model.showArchived)
        let list = q.isEmpty ? all : all.filter {
            $0.title.localizedCaseInsensitiveContains(q) || $0.key.localizedCaseInsensitiveContains(q)
        }

        VStack(spacing: 0) {
            HStack(spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Search chats", text: $filter).textFieldStyle(.plain)
                    if !filter.isEmpty {
                        Button { filter = "" } label: { Image(systemName: "xmark.circle.fill") }
                            .buttonStyle(.borderless)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Capsule().fill(Theme.field))
                Button { model.storiesShown = true } label: {
                    Image(systemName: "circle.dashed.inset.filled").font(.system(size: 15))
                        .overlay(alignment: .topTrailing) {
                            if model.unviewedStories > 0 { Circle().fill(Theme.signalBlue).frame(width: 7, height: 7).offset(x: 3, y: -2) }
                        }
                }
                .buttonStyle(.borderless)
                .help("Stories")
                .disabled(!model.historyReady)
                Button { Task { await model.newConversation() } } label: {
                    Image(systemName: "square.and.pencil").font(.system(size: 15))
                }
                .buttonStyle(.borderless)
                .help("New conversation (⌘N)")
                .disabled(!model.historyReady)
            }
            .padding(.horizontal, 12)
            .padding(.top, 6)
            .padding(.bottom, 8)

            List(selection: selection) {
                if model.showArchived {
                    Label("Back to chats", systemImage: "chevron.left")
                        .foregroundStyle(Theme.signalBlue)
                        .padding(.vertical, 4)
                        .tag("::back")
                    Text("Archived chats")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .selectionDisabled()
                } else if !archived.isEmpty && q.isEmpty {
                    HStack(spacing: 10) {
                        Image(systemName: "archivebox")
                            .font(.system(size: 15))
                            .frame(width: 40, height: 40)
                            .background(Circle().fill(Theme.field))
                        Text("Archived chats").fontWeight(archivedUnread > 0 ? .semibold : .regular)
                        Spacer()
                        Text("\(archived.count)").foregroundStyle(.secondary)
                        if archivedUnread > 0 { Circle().fill(Theme.signalBlue).frame(width: 8, height: 8) }
                    }
                    .padding(.vertical, 2)
                    .tag("::archived")
                }
                ChatListRows(items: list)
                if list.isEmpty && model.historyReady {
                    Text(q.isEmpty ? "No chats yet" : "No chats match “\(q)”")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                        .padding(.top, 20)
                        .selectionDisabled()
                }
            }
            .listStyle(.sidebar)

            ConnectionFooter()
        }
    }
}

/// What a chat list row shows, compared by value: a row is rebuilt only when this changes, not whenever
/// any chat changes (a `Conversation` carries all its messages).
struct ChatListItem: Equatable {
    var key: String
    var title: String
    var isGroup: Bool
    var unread: Int
    var muted: Bool
    var blocked: Bool
    var time: String
    var preview: String
    var avatar: NSImage?

    @MainActor init(_ c: Conversation, _ model: AppModel) {
        key = c.key
        title = model.title(c)
        isGroup = c.isGroup
        unread = c.unread
        muted = c.muted
        blocked = model.isBlocked(c.key)
        time = c.msgs.last.map { ChatListItem.shortTime($0.time) } ?? ""
        preview = model.isMessageRequest(c.key) ? "Message request"
            : c.msgs.last.map { ChatListItem.preview($0, isGroup: c.isGroup) } ?? (c.isGroup ? "Group" : " ")
        avatar = model.appearance.showAvatars ? model.avatarImage(c) : nil
    }

    static func == (a: ChatListItem, b: ChatListItem) -> Bool {
        a.key == b.key && a.title == b.title && a.isGroup == b.isGroup && a.unread == b.unread && a.muted == b.muted
            && a.blocked == b.blocked && a.time == b.time && a.preview == b.preview && a.avatar === b.avatar
    }

    private static func preview(_ m: Message, isGroup: Bool) -> String {
        if m.deleted { return m.deletedText }
        var t = m.text.prefix(200).replacingOccurrences(of: "\n", with: " ")
        if m.viewOnce { t = "1️⃣ View once media" }
        if t.isEmpty, let a = m.attachments.first {
            t = a.isSticker ? "Sticker" : a.isGif ? "GIF" : a.isImage ? "📷 Photo" : a.isVideo ? "🎬 Video"
                : a.isAudio ? "🎤 Voice message" : "📎 " + a.filename
        }
        return (m.outgoing ? "You: " : (isGroup && !m.sender.isEmpty ? m.sender + ": " : "")) + t
    }

    /// Time for today, weekday within a week, else the date.
    static func shortTime(_ d: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(d) { return d.formatted(date: .omitted, time: .shortened) }
        if cal.isDateInYesterday(d) { return "Yesterday" }
        if let days = cal.dateComponents([.day], from: d, to: Date()).day, days < 7 { return d.formatted(.dateTime.weekday(.abbreviated)) }
        return d.formatted(.dateTime.day().month(.abbreviated))
    }
}

private struct ConversationRow: View, Equatable {
    let item: ChatListItem

    var body: some View {
        let c = item
        HStack(spacing: 10) {
            if let avatar = c.avatar {
                AvatarView(image: avatar, size: 40)
            }
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 4) {
                    Text(c.title)
                        .font(.system(size: 13, weight: c.unread > 0 ? .bold : .semibold))
                        .lineLimit(1)
                    if c.muted { Image(systemName: "bell.slash.fill").font(.system(size: 9)).foregroundStyle(.secondary) }
                    if c.blocked { Image(systemName: "nosign").font(.system(size: 9)).foregroundStyle(.red) }
                    Spacer(minLength: 4)
                    Text(c.time)
                        .font(.caption2)
                        .foregroundStyle(c.unread > 0 ? Theme.signalBlue : .secondary)
                }
                HStack(spacing: 4) {
                    Text(c.preview)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    if c.unread > 0 {
                        Text(c.unread > 99 ? "99+" : "\(c.unread)")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 6)
                            .frame(minWidth: 18, minHeight: 18)
                            .background(Capsule().fill(c.muted ? Color.secondary : Theme.signalBlue))
                    }
                }
            }
        }
        .padding(.vertical, 4)
    }
}

/// The chat rows; skipped entirely while the rows are unchanged (e.g. when only the selection moves).
private struct ChatListRows: View, Equatable {
    let items: [ChatListItem]

    var body: some View {
        ForEach(items, id: \.key) { c in
            ConversationRow(item: c)
                .tag(c.key)
                .contextMenu { ConversationMenuFor(key: c.key) }
        }
    }
}

/// Context menu of a chat list row, looked up when it opens.
private struct ConversationMenuFor: View {
    @Environment(AppModel.self) private var model
    let key: String

    var body: some View {
        if let c = model.chats.convs[key] { ConversationMenu(conversation: c) }
    }
}

private struct ConversationMenu: View {
    @Environment(AppModel.self) private var model
    let conversation: Conversation

    var body: some View {
        let c = conversation
        GroupMenuItems(conversation: c)
        if !c.isGroup {
            Button { Task { await model.startCall(c.key) } } label: { Label("Voice call", systemImage: "phone") }
                .disabled(!model.connected || model.call?.isActive == true)
            Button { model.openConversation(c.key); model.safetyNumberKey = c.key } label: {
                Label("View safety number …", systemImage: "checkmark.shield")
            }
            .disabled(!model.connected)
            Divider()
            Button { Task { await model.editNickname(c.key) } } label: {
                Label(c.localNickname.isEmpty ? "Set nickname …" : "Change nickname …", systemImage: "person.text.rectangle")
            }
            if !c.localNickname.isEmpty { Button("Remove nickname") { model.setNickname(c.key, "") } }
            Divider()
        }
        Button { model.setArchived(c.key, !c.archived) } label: {
            Label(c.archived ? "Unarchive" : "Archive", systemImage: c.archived ? "tray.and.arrow.up" : "archivebox")
        }
        Button { model.setMuted(c.key, !c.muted) } label: {
            Label(c.muted ? "Unmute notifications" : "Mute notifications", systemImage: c.muted ? "bell" : "bell.slash")
        }
        Menu {
            ForEach(AppModel.expirationChoices, id: \.1) { label, seconds in
                Button {
                    model.setExpiration(c.key, seconds)
                } label: {
                    if c.expirationSeconds == seconds { Label(label, systemImage: "checkmark") } else { Text(label) }
                }
            }
        } label: { Label("Disappearing messages", systemImage: "timer") }
        .disabled(!model.connected)
        BlockMenuItem(conversation: c)
        Divider()
        Button(role: .destructive) { Task { await model.deleteConversation(c.key) } } label: {
            Label("Delete conversation …", systemImage: "trash")
        }
    }
}

/// Connection state and the signal-cli update hint at the bottom of the chat list.
private struct ConnectionFooter: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Divider()
            HStack(spacing: 6) {
                Circle()
                    .fill(model.connected ? Color.green : Color.orange)
                    .frame(width: 7, height: 7)
                Text(model.statusText).lineLimit(1).truncationMode(.tail)
                Spacer()
                if !model.connected && model.historyReady {
                    Button("Reconnect") { model.reconnect() }.buttonStyle(.link)
                }
            }
            .padding(.horizontal, 12)
            if let hint = model.updateHint {
                Link(destination: hint.url) {
                    Label("signal-cli \(hint.version) available", systemImage: "arrow.down.circle")
                }
                .padding(.horizontal, 12)
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.bottom, 8)
    }
}

private extension View {
    /// The chat header replaces the window title (macOS 15+; macOS 14 keeps the title).
    @ViewBuilder
    func hidingWindowTitle() -> some View {
        if #available(macOS 15.0, *) { toolbar(removing: .title) } else { self }
    }
}
