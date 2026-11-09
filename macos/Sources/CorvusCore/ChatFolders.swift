import Foundation

// Chat folders like Signal Desktop's (All / Unread / 1:1 chats / Groups / custom). Local only: the
// definitions are app settings, the chats picked for a folder are stored with the chat in the history.

/// What a folder or the unread filter looks at for one chat.
public struct ChatFolderFacts: Equatable, Sendable {
    public var key: String
    public var isGroup: Bool
    public var unread: Bool       // unread messages or "marked as unread"
    public var muted: Bool
    public var folders: Set<String>

    public init(key: String, isGroup: Bool, unread: Bool, muted: Bool, folders: Set<String> = []) {
        self.key = key
        self.isGroup = isGroup
        self.unread = unread
        self.muted = muted
        self.folders = folders
    }

    public init(_ c: Conversation) {
        self.init(key: c.key, isGroup: c.isGroup, unread: c.unread > 0 || c.markedUnread, muted: c.muted, folders: c.folders)
    }
}

public struct ChatFolder: Codable, Equatable, Hashable, Identifiable, Sendable {
    public var id: String
    public var name: String
    public var includeDirect = false   // every 1:1 chat
    public var includeGroups = false   // every group
    public var onlyUnread = false
    public var includeMuted = true

    public init(id: String = UUID().uuidString, name: String, includeDirect: Bool = false, includeGroups: Bool = false,
                onlyUnread: Bool = false, includeMuted: Bool = true) {
        self.id = id
        self.name = name
        self.includeDirect = includeDirect
        self.includeGroups = includeGroups
        self.onlyUnread = onlyUnread
        self.includeMuted = includeMuted
    }

    /// The folders Signal suggests.
    public enum Preset: CaseIterable, Sendable {
        case unread, direct, groups

        public var name: String {
            switch self {
            case .unread: "Unread"
            case .direct: "1:1 chats"
            case .groups: "Groups"
            }
        }

        public func folder(id: String = UUID().uuidString) -> ChatFolder {
            switch self {
            case .unread: ChatFolder(id: id, name: name, includeDirect: true, includeGroups: true, onlyUnread: true)
            case .direct: ChatFolder(id: id, name: name, includeDirect: true)
            case .groups: ChatFolder(id: id, name: name, includeGroups: true)
            }
        }

        /// Whether `folder` is this preset (whatever its id).
        public func matches(_ folder: ChatFolder) -> Bool {
            let p = self.folder(id: folder.id)
            return folder.includeDirect == p.includeDirect && folder.includeGroups == p.includeGroups
                && folder.onlyUnread == p.onlyUnread && folder.includeMuted == p.includeMuted
        }
    }

    public func contains(_ f: ChatFolderFacts) -> Bool {
        if onlyUnread && !f.unread { return false }
        if !includeMuted && f.muted { return false }
        if f.folders.contains(id) { return true }
        return f.isGroup ? includeGroups : includeDirect
    }

    public static func encode(_ folders: [ChatFolder]) -> Data? { try? JSONEncoder().encode(folders) }

    public static func decode(_ data: Data?) -> [ChatFolder] {
        guard let data, let list = try? JSONDecoder().decode([ChatFolder].self, from: data) else { return [] }
        var seen = Set<String>()
        return list.filter { !$0.id.isEmpty && seen.insert($0.id).inserted }
    }
}

public enum ChatListFilter {
    /// The chats a folder and the unread filter show, in list order. `keep` stays listed although it no longer
    /// matches (the open chat, which was just read), as in Signal Desktop.
    public static func apply<T>(_ items: [T], facts: (T) -> ChatFolderFacts, folder: ChatFolder?, unreadOnly: Bool,
                                keep: String? = nil) -> [T] {
        if folder == nil && !unreadOnly { return items }
        return items.filter { item in
            let f = facts(item)
            if let keep, f.key == keep { return true }
            if unreadOnly && !f.unread { return false }
            return folder?.contains(f) ?? true
        }
    }

    /// Unread chats of a folder that are not muted (the count on the folder's tab).
    public static func unreadChats<T>(_ items: [T], facts: (T) -> ChatFolderFacts, folder: ChatFolder?) -> Int {
        items.reduce(0) { n, item in
            let f = facts(item)
            return n + (f.unread && !f.muted && (folder?.contains(f) ?? true) ? 1 : 0)
        }
    }
}

extension ChatState {
    /// Picks the chat for a folder or takes it out. Returns the record to persist, nil when nothing changed.
    public mutating func setFolder(_ key: String, folder id: String, member: Bool) -> JSON? {
        guard let c = convs[key], c.folders.contains(id) != member else { return nil }
        if member { convs[key]!.folders.insert(id) } else { convs[key]!.folders.remove(id) }
        return Records.folders(key, convs[key]!.folders)
    }

    /// A folder was deleted: it is removed from every chat that was picked for it.
    public mutating func removeFolder(_ id: String) -> [JSON] {
        let keys = convs.values.filter { $0.folders.contains(id) }.map(\.key).sorted()
        return keys.compactMap { setFolder($0, folder: id, member: false) }
    }

    /// Sets the wallpaper of one chat ("" follows the global one). Returns the record, nil when unchanged.
    public mutating func setWallpaper(_ key: String, _ id: String) -> JSON? {
        guard let c = convs[key], c.wallpaper != id else { return nil }
        convs[key]!.wallpaper = id
        return Records.wallpaper(key, id)
    }
}

/// Text size steps (Signal Desktop's zoom levels; ⌘+ / ⌘- step through them, ⌘0 resets).
public enum TextZoomLevels {
    public static let levels: [Double] = [0.75, 0.9, 1.0, 1.1, 1.25, 1.5, 1.75, 2.0]

    /// The level nearest to `z`.
    public static func nearest(_ z: Double) -> Double {
        levels.min { abs($0 - z) < abs($1 - z) } ?? 1
    }

    public static func larger(_ z: Double) -> Double { levels.first { $0 > z + 0.001 } ?? levels.last! }
    public static func smaller(_ z: Double) -> Double { levels.last { $0 < z - 0.001 } ?? levels.first! }

    public static func label(_ z: Double) -> String { "\(Int((z * 100).rounded())) %" }
}
