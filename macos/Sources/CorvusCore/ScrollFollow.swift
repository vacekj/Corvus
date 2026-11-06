import Foundation

// Message list: following new messages only when the newest one is in view, and the "Unread messages" divider.

/// The newest message of a list, compared to see what changed at the end.
public struct LastMessageMark: Equatable {
    public var ts: Int64
    public var authorKey: String
    public var outgoing: Bool

    public init(ts: Int64, authorKey: String, outgoing: Bool) {
        self.ts = ts
        self.authorKey = authorKey
        self.outgoing = outgoing
    }

    public init?(_ m: Message?) {
        guard let m else { return nil }
        self.init(ts: m.ts, authorKey: m.authorKey, outgoing: m.outgoing)
    }
}

public struct ScrollFollow: Equatable {
    /// Distance from the end of the list within which the list counts as "at the bottom".
    public static let nearBottomDistance: Double = 150

    public enum Reaction: Equatable {
        case none
        case scrollToBottom
        case countNew           // show / increase "↓ N new"
    }

    public var nearBottom = true
    public var unseen = 0       // messages that arrived while reading older ones

    public init() {}

    /// `contentHeight` of the list, `visibleMaxY`: bottom edge of the visible part, in content coordinates.
    public static func isNearBottom(contentHeight: Double, visibleMaxY: Double) -> Bool {
        contentHeight - visibleMaxY <= nearBottomDistance
    }

    /// The list was scrolled. Returns true when the state changed.
    @discardableResult
    public mutating func scrolled(nearBottom near: Bool) -> Bool {
        let old = self
        nearBottom = near
        if near { unseen = 0 }
        return old != self
    }

    /// The newest message changed from `old` to `new`.
    public mutating func lastMessageChanged(from old: LastMessageMark?, to new: LastMessageMark?) -> Reaction {
        guard let new, new != old else { return .none }
        if new.outgoing { // own messages always scroll into view
            unseen = 0
            return .scrollToBottom
        }
        if nearBottom { return .scrollToBottom }
        // An older message becoming the last one (a deletion, history loading) is not news.
        if let old, new.ts <= old.ts { return .none }
        unseen += 1
        return .countNew
    }

    /// "↓" was clicked.
    public mutating func jumped() {
        unseen = 0
        nearBottom = true
    }
}

/// Where the "Unread messages" divider goes when a chat with `unread` unread messages is opened: above the
/// oldest of the last `unread` incoming messages. Nil without unread messages.
public func unreadDividerIndex(_ msgs: [Message], unread: Int) -> Int? {
    guard unread > 0, !msgs.isEmpty else { return nil }
    var left = unread
    var i = msgs.count - 1
    var found: Int?
    while i >= 0 && left > 0 {
        if !msgs[i].outgoing {
            found = i
            left -= 1
        }
        i -= 1
    }
    return found
}
