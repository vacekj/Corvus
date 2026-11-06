import AppKit
import CorvusCore
import SwiftUI

/// Scroll state of one chat's message list: whether its end is in view, how many messages arrived while
/// older ones were read, and where the "Unread messages" divider goes. One object per chat; the list body
/// reads only `divider` (set when a chat is opened), the "↓ N new" button reads `follow`.
@MainActor @Observable
final class ChatScrollState {
    struct Divider: Equatable {
        let ts: Int64
        let authorKey: String
    }

    private static var all: [String: ChatScrollState] = [:]

    static func of(_ key: String) -> ChatScrollState {
        if let s = all[key] { return s }
        let s = ChatScrollState()
        all[key] = s
        return s
    }

    var follow = ScrollFollow()
    private(set) var divider: Divider?

    /// Called by `openConversation` before it resets the unread counter.
    func chatOpened(_ c: Conversation) {
        let d = unreadDividerIndex(c.msgs, unread: c.unread).map { Divider(ts: c.msgs[$0].ts, authorKey: c.msgs[$0].authorKey) }
        if d != divider { divider = d }
    }

    func scrolled(nearBottom: Bool) {
        var f = follow
        if f.scrolled(nearBottom: nearBottom) { follow = f }
    }

    func lastMessageChanged(from old: LastMessageMark?, to new: LastMessageMark?) -> ScrollFollow.Reaction {
        var f = follow
        let r = f.lastMessageChanged(from: old, to: new)
        if f != follow { follow = f }
        return r
    }
}

/// Watches the scroll position of the list it is placed in (a background of the list content) without
/// SwiftUI scroll geometry (macOS 15+) and without updating the list itself.
struct ScrollPositionObserver: NSViewRepresentable {
    let key: String

    func makeNSView(context: Context) -> ObserverView {
        let v = ObserverView()
        v.key = key
        return v
    }

    func updateNSView(_ v: ObserverView, context: Context) { v.key = key }

    final class ObserverView: NSView {
        var key = ""
        private var observer: NSObjectProtocol?

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let observer { NotificationCenter.default.removeObserver(observer) }
            observer = nil
            guard window != nil, let clip = enclosingScrollView?.contentView else { return }
            clip.postsBoundsChangedNotifications = true
            observer = NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: clip,
                                                              queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.update() }
            }
        }

        /// Only scrolling is looked at: when content is added at the end, the list was at the bottom if it was
        /// there before (the new message decides with the state from before it arrived).
        private func update() {
            guard let sv = enclosingScrollView, let doc = sv.documentView, !key.isEmpty else { return }
            let clip = sv.contentView.bounds
            let height = doc.frame.height
            let visibleMaxY = doc.isFlipped ? clip.maxY : height - clip.minY
            ChatScrollState.of(key).scrolled(nearBottom: ScrollFollow.isNearBottom(contentHeight: height, visibleMaxY: visibleMaxY))
        }

        deinit {
            if let observer { NotificationCenter.default.removeObserver(observer) }
        }
    }
}

/// "↓ 3 new": shown while the end of the list is out of view.
struct JumpToBottomButton: View {
    let state: ChatScrollState
    let jump: () -> Void

    var body: some View {
        let f = state.follow
        if !f.nearBottom {
            Button {
                state.follow.jumped()
                jump()
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "arrow.down").font(.system(size: 12, weight: .bold))
                    if f.unseen > 0 { Text(f.unseen == 1 ? "1 new" : "\(f.unseen) new").font(.callout.weight(.semibold)) }
                }
                .foregroundStyle(f.unseen > 0 ? Color.white : Color.primary)
                .padding(.horizontal, f.unseen > 0 ? 12 : 9)
                .padding(.vertical, 8)
                .background(Capsule().fill(f.unseen > 0 ? AnyShapeStyle(Theme.signalBlue) : AnyShapeStyle(.regularMaterial)))
                .overlay(Capsule().strokeBorder(.separator))
                .shadow(color: .black.opacity(0.15), radius: 6, y: 2)
            }
            .buttonStyle(.plain)
            .help("Jump to the newest message")
            .padding(16)
            .transition(.opacity)
        }
    }
}

/// Above the first message that was unread when the chat was opened.
struct UnreadDivider: View {
    var body: some View {
        HStack(spacing: 10) {
            Rectangle().fill(Theme.signalBlue.opacity(0.5)).frame(height: 1)
            Text("Unread messages").font(.caption.weight(.semibold)).foregroundStyle(Theme.signalBlue).fixedSize()
            Rectangle().fill(Theme.signalBlue.opacity(0.5)).frame(height: 1)
        }
        .padding(.top, 14)
        .padding(.bottom, 4)
    }
}
