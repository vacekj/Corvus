import Foundation

/// The keyboard shortcuts Corvus really has (menu items in App.swift, the key monitors in KeyboardNavigation,
/// CallBar, StoriesView, AttachmentViews and the composer's key handling), shown by Help → Keyboard shortcuts (⌘/).
/// Keep it in step when a shortcut is added or changed.
public struct ShortcutEntry: Equatable, Hashable, Sendable {
    /// Key caps, e.g. ["⌘", "K"]; one combination per element of `alternatives`.
    public let alternatives: [[String]]
    public let action: String

    public init(_ action: String, _ alternatives: [String]...) {
        self.action = action
        self.alternatives = alternatives
    }
}

public struct ShortcutSection: Equatable, Sendable {
    public let title: String
    public let entries: [ShortcutEntry]
}

public enum ShortcutCatalog {
    public static let sections: [ShortcutSection] = [
        ShortcutSection(title: "Navigation", entries: [
            ShortcutEntry("Go to conversation", ["⌘", "K"]),
            ShortcutEntry("New conversation", ["⌘", "N"]),
            ShortcutEntry("New group", ["⇧", "⌘", "N"]),
            ShortcutEntry("Previous chat", ["⌥", "↑"], ["⌃", "⇧", "Tab"]),
            ShortcutEntry("Next chat", ["⌥", "↓"], ["⌃", "Tab"]),
            ShortcutEntry("Open chat 1 to 9 of the list", ["⌘", "1…9"]),
            ShortcutEntry("Search chats", ["⌥", "⌘", "F"]),
            ShortcutEntry("Stories", ["⇧", "⌘", "S"]),
            ShortcutEntry("Settings", ["⌘", ","]),
            ShortcutEntry("Keyboard shortcuts", ["⌘", "/"]),
        ]),
        ShortcutSection(title: "Conversation", entries: [
            ShortcutEntry("Search this conversation", ["⌘", "F"]),
            ShortcutEntry("Next search result", ["Return"]),
            ShortcutEntry("Close search", ["Esc"]),
            ShortcutEntry("Conversation info (outside the message field)", ["⌘", "I"]),
            ShortcutEntry("Media, files and links", ["⇧", "⌘", "M"]),
        ]),
        ShortcutSection(title: "Message field", entries: [
            ShortcutEntry("Send", ["Return"]),
            ShortcutEntry("New line", ["⇧", "Return"], ["⌥", "Return"]),
            ShortcutEntry("Edit your last message (empty field)", ["↑"]),
            ShortcutEntry("Select the whole draft", ["⇧", "↑"]),
            ShortcutEntry("Cancel editing or replying", ["Esc"]),
            ShortcutEntry("Bold", ["⌘", "B"]),
            ShortcutEntry("Italic", ["⌘", "I"]),
        ]),
        ShortcutSection(title: "Go to conversation", entries: [
            ShortcutEntry("Move through the results", ["↑"], ["↓"]),
            ShortcutEntry("Open the selected chat", ["Return"]),
            ShortcutEntry("Close", ["Esc"]),
        ]),
        ShortcutSection(title: "Calls", entries: [
            ShortcutEntry("Accept an incoming call", ["Return"]),
            ShortcutEntry("Decline an incoming call", ["Esc"]),
            ShortcutEntry("Mute or unmute during a call", ["⇧", "⌘", "M"]),
        ]),
        ShortcutSection(title: "Media and stories", entries: [
            ShortcutEntry("Previous or next story", ["←"], ["→"]),
            ShortcutEntry("Close the image viewer", ["Esc"]),
        ]),
    ]

    /// The text of a combination as the menus write it ("⇧⌘N", "⌃ Tab").
    public static func text(_ keys: [String]) -> String {
        var s = ""
        for k in keys {
            if !s.isEmpty, k.count > 1, !s.hasSuffix(" ") { s += " " }
            s += k
        }
        return s
    }
}
