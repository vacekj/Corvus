import AppKit
import CorvusCore
import SwiftUI

/// The menu of the menu bar icon: unread total, recent chats, a new message, muting notifications.
struct MenuBarContent: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    private let chrome = AppChrome.shared

    private static let recentLimit = 8

    var body: some View {
        let unread = model.totalUnread
        Text(unread > 0 ? "\(unread) unread message\(unread == 1 ? "" : "s")" : "No unread messages")
        if let muted = chrome.mute.label(now: Date()) { Text(muted) }
        Divider()
        if model.historyReady {
            let recent = model.chatListItems(archived: false).prefix(Self.recentLimit)
            if !recent.isEmpty {
                Section("Recent chats") {
                    ForEach(Array(recent), id: \.key) { item in
                        Button { open(item.key) } label: {
                            if let avatar = item.avatar {
                                Label { Text(Self.rowTitle(item)) } icon: { Image(nsImage: MenuAvatar.small(avatar)) }
                            } else {
                                Text(Self.rowTitle(item))
                            }
                        }
                    }
                }
                Divider()
            }
        }
        Button("New message …") {
            showMainWindow()
            KeyboardNavigation.shared.showSwitcher(newChat: true)
        }
        .disabled(!model.historyReady)
        if chrome.mute.isMuted(at: Date()) {
            Button("Unmute notifications") { chrome.unmuteNotifications() }
        } else {
            Menu("Mute notifications") {
                ForEach(NotificationMute.choices, id: \.title) { choice in
                    Button(choice.title) { chrome.muteNotifications(for: choice.seconds) }
                }
            }
        }
        Divider()
        Button("Show window") { showMainWindow() }
        Divider()
        Button("Quit Corvus") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }

    /// "Anna (3)", "Family 🔕"
    static func rowTitle(_ item: ChatListItem) -> String {
        var t = item.title
        if item.unread > 0 { t += " (\(item.unread))" } else if item.markedUnread { t += " •" }
        if item.muted { t += " 🔕" }
        return t
    }

    private func showMainWindow() {
        openWindow(id: "main")
        NSApp.activate(ignoringOtherApps: true)
        MainWindowTracker.shared.window?.makeKeyAndOrderFront(nil)
    }

    private func open(_ key: String) {
        showMainWindow()
        model.activateConversation(key)
    }
}

/// Round 16 pt avatars for menu items, drawn once per avatar image.
@MainActor
enum MenuAvatar {
    private static let cache = NSMapTable<NSImage, NSImage>.weakToStrongObjects()

    static func small(_ image: NSImage) -> NSImage {
        if let hit = cache.object(forKey: image) { return hit }
        let size = NSSize(width: 16, height: 16)
        let small = NSImage(size: size, flipped: false) { rect in
            NSBezierPath(ovalIn: rect).addClip()
            image.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1)
            return true
        }
        cache.setObject(small, forKey: image)
        return small
    }
}
