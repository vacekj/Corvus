import AppKit
import CorvusCore
import SwiftUI
import UniformTypeIdentifiers

/// Search bar, message list and composer of the selected conversation.
struct ChatPane: View {
    @Environment(AppModel.self) private var model
    let conversation: Conversation
    @State private var dropTargeted = false

    var body: some View {
        VStack(spacing: 0) {
            if model.searchVisible { SearchBar() }
            if !conversation.pins.isEmpty { PinnedMessagesBar(conversation: conversation) }
            // In an overlay the list's changing content size never re-runs the layout of the window around it
            // (composer, toolbar): a VStack measures its children, and a scroll view measures its content.
            // Recently used chats keep their message list alive, hidden, each in its own hosting view: building
            // a list is the slow part of opening a chat, and in one shared view graph every switch would make
            // SwiftUI revisit all kept lists. Switching to a kept chat only flips which list is visible.
            Color.clear.overlay {
                if WarmListsContainer.hosted {
                    // The chat background (not the window's) shows while a list is being built.
                    WarmMessageLists(model: model, keys: model.warmChats, current: conversation.key)
                        .background(ChatBackground(key: conversation.key))
                } else {
                    ZStack {
                        ForEach(model.warmChats, id: \.self) { key in
                            let on = key == conversation.key
                            MessageListHost(key: key)
                                .opacity(on ? 1 : 0)
                                .allowsHitTesting(on)
                                .accessibilityHidden(!on)
                        }
                    }
                }
            }
                .overlay {
                    if dropTargeted {
                        ZStack {
                            RoundedRectangle(cornerRadius: 16).fill(Theme.signalBlue.opacity(0.08))
                            RoundedRectangle(cornerRadius: 16)
                                .strokeBorder(Theme.signalBlue, style: StrokeStyle(lineWidth: 2, dash: [8, 6]))
                            Label("Drop to attach", systemImage: "paperclip")
                                .font(.title3.weight(.medium))
                                .foregroundStyle(Theme.signalBlue)
                        }
                        .padding(12)
                    }
                }
            RequestBanner(conversation: conversation)
            ComposerOrSelectionBar(conversation: conversation) { ComposerArea().disabled(model.isSendLocked(conversation.key)) }
        }
        .onDrop(of: [.fileURL, .image], isTargeted: $dropTargeted) { providers in
            handleDrop(providers)
        }
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        var handled = false
        for p in providers {
            if p.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                handled = true
                _ = p.loadObject(ofClass: URL.self) { url, _ in
                    guard let url else { return }
                    Task { @MainActor in model.addPendingFiles([url.path]) }
                }
            } else if p.canLoadObject(ofClass: NSImage.self) {
                handled = true
                _ = p.loadObject(ofClass: NSImage.self) { obj, _ in
                    guard let image = obj as? NSImage, let png = Media.pngData(image) else { return }
                    Task { @MainActor in
                        if let url = try? Media.writeTemp(png, name: "dropped.png") { model.addPendingFiles([url.path]) }
                    }
                }
            }
        }
        return handled
    }
}

private struct SearchBar: View {
    @Environment(AppModel.self) private var model
    @FocusState private var focused: Bool

    var body: some View {
        @Bindable var model = model
        HStack(spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search this conversation", text: $model.searchText)
                    .textFieldStyle(.plain)
                    .focused($focused)
                    .onSubmit { model.navigateSearch(backwards: false) }
                    .onKeyPress(.escape) {
                        model.closeSearch()
                        return .handled
                    }
                if model.searchBusy {
                    Text("Searching …")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if !model.searchText.isEmpty {
                    Text(model.searchResults.isEmpty ? "No results" : "\(model.searchPosition + 1) of \(model.searchResults.count)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Capsule().fill(Theme.field))
            Button { model.navigateSearch(backwards: true) } label: { Image(systemName: "chevron.up") }
                .help("Previous match")
                .disabled(model.searchResults.isEmpty)
            Button { model.navigateSearch(backwards: false) } label: { Image(systemName: "chevron.down") }
                .help("Next match")
                .disabled(model.searchResults.isEmpty)
            Button("Done") { model.closeSearch() }
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Theme.chrome)
        .overlay(alignment: .bottom) { Divider() }
        .onAppear { focused = true }
    }
}

// MARK: - Messages

/// Position of a message inside a run of messages from the same author.
struct MessageGrouping {
    var joinedAbove = false
    var joinedBelow = false
}

private struct WarmMessageLists: NSViewRepresentable {
    let model: AppModel
    let keys: [String]
    let current: String

    func makeNSView(context: Context) -> WarmListsContainer { WarmListsContainer() }
    func updateNSView(_ view: WarmListsContainer, context: Context) { view.update(model: model, keys: keys, current: current) }
}

final class WarmListsContainer: NSView {
    static let hosted = ProcessInfo.processInfo.environment["CORVUS_WARM_HOSTS"] != "0"
    // SwiftUI's hover tracking in the hosted lists expects flipped coordinates; unflipped, the row mirrored
    // vertically from the pointer was treated as hovered.
    override var isFlipped: Bool { true }
    private var hosts: [String: NSHostingView<AnyView>] = [:]
    private var model: AppModel?
    private var keys: [String] = []
    private var current = ""

    func update(model: AppModel, keys: [String], current: String) {
        self.model = model
        self.keys = keys
        self.current = current
        reconcile()
    }

    /// Lists are created only at the final size: one laid out at zero size first would not open at the
    /// newest message. Building a list is the slow part of opening a chat, so it never happens in the pass
    /// that switches chats: that pass only shows the new header, composer and selection (on screen in the
    /// next frame), and the list is built in a following run loop pass, one list per pass.
    private func reconcile() {
        guard let model, bounds.width > 0, bounds.height > 0 else { return }
        for k in hosts.keys where !keys.contains(k) {
            hosts[k]?.removeFromSuperview()
            hosts[k] = nil
        }
        for (k, h) in hosts {
            let on = k == current
            if on && h.frame != bounds { h.frame = bounds } // hidden lists follow window resizes when shown
            if h.isHidden == on { h.isHidden = !on }
        }
        if keys.contains(where: { hosts[$0] == nil }) { scheduleBuild() }
    }

    private var buildScheduled = false

    private func scheduleBuild() {
        guard !buildScheduled else { return }
        buildScheduled = true
        DispatchQueue.main.async { [weak self] in self?.buildNext() }
    }

    /// When the last list build started: the frame that switched chats was committed by then (benchmark).
    static var lastBuildStart: CFTimeInterval = 0

    private func buildNext() {
        buildScheduled = false
        Self.lastBuildStart = CACurrentMediaTime()
        guard let model, bounds.width > 0, bounds.height > 0 else { return }
        // The open chat first, then chats being prepared ahead (newest wish first).
        guard let k = ([current] + keys).first(where: { keys.contains($0) && hosts[$0] == nil }) else { return }
        let h = NSHostingView(rootView: AnyView(MessageListHost(key: k).environment(model)))
        h.sizingOptions = [] // the container decides the size; no constraints from the content
        h.frame = bounds
        h.autoresizingMask = []
        // Laid out and scrolled to the newest message while hidden, and only then shown: never a frame of
        // the list at its top, half laid out or jumping down (until then the chat background shows).
        h.isHidden = true
        addSubview(h)
        hosts[k] = h
        settleAtBottom(h)
        h.isHidden = k != current
        scrollToBottom(h, passes: 2) // rows measured after this pass can still move the end
        if keys.contains(where: { hosts[$0] == nil }) { scheduleBuild() }
    }

    override func layout() {
        super.layout()
        reconcile()
    }

    /// A new list opens at the newest message. The lazy stack only estimates the height of rows it has
    /// not built, so the end moves while the last rows are built: repeat for a few run loop passes.
    /// The lazy stack only estimates the height of rows it has not built, so reaching the end takes a few
    /// rounds of layout and scrolling; done synchronously here, before the list is first shown.
    private func settleAtBottom(_ h: NSView) {
        for _ in 0..<5 {
            h.layoutSubtreeIfNeeded()
            guard let sv = Self.scrollView(in: h), let doc = sv.documentView else { return }
            let clip = sv.contentView
            let maxY = max(0, doc.frame.height - clip.bounds.height)
            let y = doc.isFlipped ? maxY : 0
            guard abs(clip.bounds.origin.y - y) > 0.5 else { return }
            clip.scroll(to: NSPoint(x: clip.bounds.origin.x, y: y))
            sv.reflectScrolledClipView(clip)
        }
    }

    private func scrollToBottom(_ h: NSView, passes: Int) {
        DispatchQueue.main.async { [weak self, weak h] in
            guard let h, let sv = Self.scrollView(in: h), let doc = sv.documentView else { return }
            let clip = sv.contentView
            let maxY = max(0, doc.frame.height - clip.bounds.height)
            let y = doc.isFlipped ? maxY : 0
            if abs(clip.bounds.origin.y - y) > 0.5 {
                clip.scroll(to: NSPoint(x: clip.bounds.origin.x, y: y))
                sv.reflectScrolledClipView(clip)
            }
            if passes > 1 { self?.scrollToBottom(h, passes: passes - 1) }
        }
    }

    private static func scrollView(in v: NSView) -> NSScrollView? {
        if let s = v as? NSScrollView { return s }
        for c in v.subviews { if let s = scrollView(in: c) { return s } }
        return nil
    }
}

/// Root of a kept list's own view graph.
private struct MessageListHost: View {
    @Environment(AppModel.self) private var model
    let key: String

    var body: some View {
        if let c = model.chats.convs[key] {
            MessageList(conversation: c, pendingTs: model.chats.pendingTimestamps(key))
                .equatable()
                // `searchVisible` first: while no search is open, switching chats does not touch this view
                .environment(\.searchHighlightId, model.searchVisible && model.current == key ? model.searchMatchId : nil)
                .environment(\.searchHighlightQuery, model.searchVisible && model.current == key ? model.searchHighlightQuery : nil)
                .tint(Theme.signalBlue)
        }
    }
}

private struct MessageList: View, Equatable {
    @Environment(AppModel.self) private var model
    let conversation: Conversation
    /// Messages still being sent (shown dimmed).
    let pendingTs: Set<Int64>

    /// A hidden list must not be rebuilt when another chat changes. The message array is compared by
    /// identity: the model changes it copy-on-write while this view holds the previous value.
    static func == (a: MessageList, b: MessageList) -> Bool {
        let ca = a.conversation, cb = b.conversation
        return a.pendingTs == b.pendingTs && ca.key == cb.key && ca.isGroup == cb.isGroup
            && ca.title == cb.title && ca.msgs.count == cb.msgs.count
            && ca.msgs.withUnsafeBufferPointer { pa in cb.msgs.withUnsafeBufferPointer { pa.baseAddress == $0.baseAddress } }
    }

    private func sameRun(_ a: Message, _ b: Message) -> Bool {
        !a.isNotice && !b.isNotice && a.outgoing == b.outgoing && a.authorKey == b.authorKey && abs(a.ts - b.ts) <= Theme.groupGapMs
            && LocalDay.of(a.ts) == LocalDay.of(b.ts)
    }

    var body: some View {
        let msgs = conversation.msgs
        let scrollState = ChatScrollState.of(conversation.key)
        let divider = scrollState.divider
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    if msgs.isEmpty {
                        EmptyChat(conversation: conversation).padding(.top, 60)
                    }
                    // The whole history: the lazy stack builds only what is on screen. (Adding older messages in
                    // pages made every page stall scrolling while the stack re-measured to keep the position.)
                    ForEach(IndexedMessages(base: msgs)) { row in
                        let i = row.index, m = row.message
                        let newDay = i == 0 || LocalDay.of(msgs[i - 1].ts) != LocalDay.of(m.ts)
                        let g = MessageGrouping(joinedAbove: i > 0 && sameRun(msgs[i - 1], m),
                                                joinedBelow: i + 1 < msgs.count && sameRun(m, msgs[i + 1]))
                        VStack(spacing: 0) {
                            if newDay { DateSeparator(date: m.time) }
                            if let divider, m.ts == divider.ts && m.authorKey == divider.authorKey { UnreadDivider() }
                            if m.isNotice {
                                ChatNoticeRow(message: m).padding(.top, newDay ? 2 : 10)
                            } else {
                                MessageRow(message: m, isGroup: conversation.isGroup, grouping: g,
                                           pending: pendingTs.contains(m.ts),
                                           avatar: conversation.isGroup && !m.outgoing && !g.joinedBelow ? authorAvatar(m) : nil)
                                    .padding(.top, g.joinedAbove ? 2 : (newDay ? 2 : 10))
                            }
                        }
                        .id(m.id)
                    }
                    TypingBubbleRow(key: conversation.key, isGroup: conversation.isGroup)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .background(ScrollPositionObserver(key: conversation.key))
            }
            .defaultScrollAnchor(.bottom)
            .overlay(alignment: .bottomTrailing) {
                JumpToBottomButton(state: scrollState) {
                    guard let id = conversation.msgs.last?.id else { return }
                    withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(id, anchor: .bottom) }
                }
            }
            .environment(\.conversationKey, conversation.key)
            .background(ChatBackground(key: conversation.key))
            // New messages scroll into view only while the end of the list is in view (own messages always);
            // otherwise "↓ N new" counts them.
            .onChange(of: LastMessageMark(msgs.last)) { old, new in
                guard scrollState.lastMessageChanged(from: old, to: new) == .scrollToBottom,
                      let id = conversation.msgs.last?.id else { return }
                withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(id, anchor: .bottom) }
            }
            .onChange(of: model.scrollRequest?.serial) { _, _ in
                // only the visible one of the kept lists (read here, not in `body`, so switching chats does
                // not rebuild the lists)
                guard model.current == conversation.key, let id = model.scrollRequest?.id else { return }
                withAnimation(.easeInOut(duration: 0.25)) { proxy.scrollTo(id, anchor: .center) }
            }
        }
    }

    /// Not via `model.chats`: a list reading it is rebuilt whenever any chat changes.
    private func authorAvatar(_ m: Message) -> NSImage {
        model.avatars[m.authorKey] ?? Media.placeholderAvatar(key: m.authorKey, title: m.sender.isEmpty ? m.authorKey : m.sender)
    }
}

/// Calendar day of a timestamp in the local time zone, as a number. `Calendar.isDate(_:inSameDayAs:)`
/// is slow, and the list compares neighbouring messages for every row it lays out.
@MainActor
enum LocalDay {
    private static var offsets: [Int64: Int64] = [:] // hour -> seconds from GMT (changes only with DST)
    private static var observer: NSObjectProtocol?

    static func of(_ ms: Int64) -> Int64 {
        if observer == nil {
            observer = NotificationCenter.default.addObserver(forName: .NSSystemTimeZoneDidChange, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { offsets.removeAll() }
            }
        }
        let s = ms / 1000
        let hour = s / 3600
        let off: Int64
        if let o = offsets[hour] { off = o } else {
            off = Int64(TimeZone.current.secondsFromGMT(for: Date(timeIntervalSince1970: TimeInterval(s))))
            if offsets.count > 50_000 { offsets.removeAll() }
            offsets[hour] = off
        }
        return (s + off).floorDiv(86_400)
    }
}

private extension Int64 {
    func floorDiv(_ d: Int64) -> Int64 { self >= 0 ? self / d : (self - d + 1) / d }
}

/// Messages with their positions, without building an array of pairs on every update.
private struct IndexedMessages: RandomAccessCollection {
    /// Same identity as `Message.id`, without formatting a string for each of thousands of messages.
    struct Key: Hashable {
        let ts: Int64
        let author: String
        let outgoing: Bool
    }
    struct Row: Identifiable {
        let index: Int
        let message: Message
        var id: Key { Key(ts: message.ts, author: message.authorKey, outgoing: message.outgoing) }
    }
    let base: [Message]
    var startIndex: Int { 0 }
    var endIndex: Int { base.count }
    subscript(i: Int) -> Row { Row(index: i, message: base[i]) }
}

private struct EmptyChat: View {
    @Environment(AppModel.self) private var model
    let conversation: Conversation

    var body: some View {
        VStack(spacing: 10) {
            AvatarView(image: model.avatarImage(conversation), size: 72)
            Text(model.visibleTitle(conversation)).font(.title2.weight(.semibold))
            let detail = conversation.isGroup ? "Group" : model.chatDetail(conversation)
            if !detail.isEmpty { Text(detail).foregroundStyle(.secondary) }
            Text("Messages are end-to-end encrypted by Signal.\nThis Mac keeps its own encrypted copy of the history.")
                .font(.caption)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .padding(.top, 6)
        }
        .frame(maxWidth: .infinity)
    }
}

private struct DateSeparator: View {
    let date: Date

    var body: some View {
        Text(label)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 4)
            .background(Capsule().fill(.ultraThinMaterial))
            .padding(.top, 14)
            .padding(.bottom, 8)
            .frame(maxWidth: .infinity)
    }

    private var label: String {
        if Calendar.current.isDateInToday(date) { return "Today" }
        if Calendar.current.isDateInYesterday(date) { return "Yesterday" }
        if let days = Calendar.current.dateComponents([.day], from: date, to: Date()).day, days < 7 {
            return date.formatted(.dateTime.weekday(.wide))
        }
        return date.formatted(date: .abbreviated, time: .omitted)
    }
}

private struct MessageRow: View {
    @Environment(AppModel.self) private var model
    let message: Message
    let isGroup: Bool
    let grouping: MessageGrouping
    let pending: Bool
    let avatar: NSImage?
    @State private var hovering = false
    @State private var reactionsShown = false
    @Environment(\.conversationKey) private var conversationKey

    private var showAvatarColumn: Bool { isGroup && !message.outgoing }

    var body: some View {
        let m = message
        MessageRowLayout(outgoing: m.outgoing, hasAvatar: showAvatarColumn) {
            if showAvatarColumn {
                // One avatar per run of messages, next to its last bubble.
                Group {
                    if let avatar {
                        AvatarView(image: avatar, size: 28)
                    } else {
                        Color.clear
                    }
                }
                .frame(width: 28, height: 28)
                .padding(.bottom, m.reactions.isEmpty ? 0 : 14)
            }
            Bubble(message: m, isGroup: isGroup, grouping: grouping, pending: pending)
                .environment(\.messageHovered, hovering)
                .padding(.bottom, m.reactions.isEmpty ? 0 : 14)
                .overlay(alignment: m.outgoing ? .bottomTrailing : .bottomLeading) {
                    if !m.reactions.isEmpty {
                        ReactionsView(message: m).padding(.horizontal, 10)
                    }
                }
            hoverActions
        }
        .modifier(SelectableRow(id: m.id))
        .onHover { hovering = $0 }
    }

    /// Quick actions that appear next to the bubble under the pointer (like the Signal desktop client).
    /// Built only under the pointer: a `Menu` is an AppKit pop-up button, and one in every row made
    /// scrolling through long chats drop frames.
    private var hoverActions: some View {
        ZStack {
            if (hovering || reactionsShown) && model.connected && !message.deleted
                && !MessageSelection.shared.isActive(conversationKey) { hoverButtons.transition(.opacity) }
        }
        .frame(width: 70, height: 22)
        .padding(.bottom, 6)
        .animation(.easeOut(duration: 0.12), value: hovering)
    }

    private var hoverButtons: some View {
        HStack(spacing: 2) {
            if MessageSelectionRules.canInteract(message) {
                // A plain button with a popover: a `Menu` is an AppKit pop-up button and costly to build.
                Button { reactionsShown = true } label: { Image(systemName: "face.smiling") }
                    .buttonStyle(.borderless)
                    .help("React")
                    .popover(isPresented: $reactionsShown, arrowEdge: .top) {
                        ReactionPicker(message: message) { reactionsShown = false }
                    }
                Button { model.startReply(message.id) } label: { Image(systemName: "arrowshape.turn.up.left") }
                    .buttonStyle(.borderless)
                    .help("Reply")
            }
            // The same items as the context menu; built only while the pointer is over this message.
            Menu {
                MessageMenu(message: message)
            } label: { Image(systemName: "ellipsis") }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("More")
        }
        .foregroundStyle(.secondary)
    }
}

extension EnvironmentValues {
    /// The pointer is over this message (its text is selectable only then: a selectable text is backed by an
    /// AppKit text field, too costly to create for every message scrolling into view).
    @Entry var messageHovered = false
    /// The current search hit, outlined (passed down instead of read from the model in every bubble:
    /// a bubble reading model state updates whenever that state is written).
    @Entry var searchHighlightId: String? = nil
    /// The text searched for in the open chat: its occurrences are highlighted inside the bubbles.
    @Entry var searchHighlightQuery: String? = nil
    /// The chat a message list shows (the kept hidden lists are not the current chat).
    @Entry var conversationKey = ""
}

/// One message row, laid out in a single pass: [avatar] bubble [actions] for incoming messages,
/// [actions] bubble for outgoing ones, bottom aligned, with 80 pt kept free on the far side.
/// An HStack with spacers measures the bubble (its text) several times with different widths.
private struct MessageRowLayout: Layout {
    let outgoing: Bool
    let hasAvatar: Bool
    private let spacing: CGFloat = 8
    private let freeSide: CGFloat = 80

    struct Cache { var width: CGFloat = -1; var sizes: [CGSize] = [] }
    func makeCache(subviews: Subviews) -> Cache { Cache() }
    func updateCache(_ cache: inout Cache, subviews: Subviews) { cache.width = -1 }

    /// Subviews: [avatar], bubble, actions.
    private func measure(_ width: CGFloat, _ subviews: Subviews, _ cache: inout Cache) -> [CGSize] {
        if cache.width == width { return cache.sizes }
        var sizes = Array(repeating: CGSize.zero, count: subviews.count)
        let bubble = hasAvatar ? 1 : 0, actions = subviews.count - 1
        var used = freeSide
        if hasAvatar {
            sizes[0] = subviews[0].sizeThatFits(.unspecified)
            used += sizes[0].width + spacing
        }
        sizes[actions] = subviews[actions].sizeThatFits(.unspecified)
        used += sizes[actions].width + spacing
        sizes[bubble] = subviews[bubble].sizeThatFits(ProposedViewSize(width: max(0, width - used), height: nil))
        cache.width = width
        cache.sizes = sizes
        return sizes
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) -> CGSize {
        let width = proposal.width ?? 600
        let sizes = measure(width, subviews, &cache)
        return CGSize(width: width, height: sizes.map(\.height).max() ?? 0)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) {
        let sizes = measure(bounds.width, subviews, &cache)
        let bubble = hasAvatar ? 1 : 0, actions = subviews.count - 1
        func place(_ i: Int, _ x: CGFloat) {
            subviews[i].place(at: CGPoint(x: x, y: bounds.maxY - sizes[i].height),
                              proposal: ProposedViewSize(width: sizes[i].width, height: sizes[i].height))
        }
        if outgoing {
            let x = bounds.maxX - sizes[bubble].width
            place(bubble, x)
            place(actions, x - spacing - sizes[actions].width)
        } else {
            var x = bounds.minX
            if hasAvatar { place(0, x); x += sizes[0].width + spacing }
            place(bubble, x)
            place(actions, x + sizes[bubble].width + spacing)
        }
    }
}

/// The bubble itself: sender, quote, attachments, text and the time row.
private struct Bubble: View {
    @Environment(AppModel.self) private var model
    let message: Message
    let isGroup: Bool
    let grouping: MessageGrouping
    let pending: Bool
    @Environment(\.searchHighlightId) private var searchHighlightId

    var body: some View {
        let m = message
        let a = model.appearance
        let fg = m.outgoing ? a.outTextColor : a.inTextColor
        let bg = m.outgoing ? a.outBgColor : a.inBgColor
        let shape = bubbleShape(radius: CGFloat(a.radius))
        let mediaOnly = m.text.isEmpty && !m.quote.valid && !m.attachments.isEmpty && !m.viewOnce
            && (m.attachments.allSatisfy { $0.isImage && !$0.isSticker }
                || (m.attachments.count > 1 && m.attachments.allSatisfy(\.isAlbumMedia)))
        let stickerOnly = m.text.isEmpty && !m.viewOnce && m.attachments.count == 1 && m.attachments[0].isSticker
        let showSender = isGroup && !m.outgoing && !grouping.joinedAbove

        Group {
            if m.deleted {
                // "This message was deleted." / "You deleted this message." in a muted italic style
                BubbleContentLayout(spacing: 3) {
                    VStack(alignment: .leading, spacing: 6) {
                        if showSender { senderLabel }
                        Text(m.deletedText)
                            .font(.system(size: DisplaySettings.shared.size(NSFont.systemFontSize + 1)).italic())
                            .foregroundStyle(fg.opacity(0.7))
                    }
                    MetaRow(message: m, pending: pending, color: fg.opacity(0.7), readColor: fg, isGroup: isGroup)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(shape.fill(bg))
            } else if stickerOnly {
                VStack(alignment: m.outgoing ? .trailing : .leading, spacing: 2) {
                    if showSender { senderLabel }
                    if m.quote.valid { QuoteView(quote: m.quote, foreground: .primary, outgoing: m.outgoing) }
                    StickerView(attachment: m.attachments[0])
                    MetaRow(message: m, pending: pending, color: .secondary, readColor: .primary, isGroup: isGroup)
                }
            } else if m.viewOnce {
                BubbleContentLayout(spacing: 3) {
                    VStack(alignment: .leading, spacing: 6) {
                        if showSender { senderLabel }
                        ViewOnceBubbleContent(message: m, foreground: fg)
                    }
                    MetaRow(message: m, pending: pending, color: fg.opacity(0.7), readColor: fg, isGroup: isGroup)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(shape.fill(bg))
            } else if m.isPoll {
                BubbleContentLayout(spacing: 3) {
                    VStack(alignment: .leading, spacing: 6) {
                        if showSender { senderLabel }
                        PollView(message: m, foreground: fg)
                    }
                    MetaRow(message: m, pending: pending, color: fg.opacity(0.7), readColor: fg, isGroup: isGroup)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(shape.fill(bg))
            } else if mediaOnly {
                VStack(spacing: 2) {
                    AttachmentStack(message: m, foreground: fg, edgeToEdge: true)
                }
                .overlay(alignment: .bottomTrailing) {
                    MetaRow(message: m, pending: pending, color: .white.opacity(0.8), readColor: .white, isGroup: isGroup)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(.black.opacity(0.45)))
                        .padding(6)
                }
                .overlay(alignment: .topLeading) {
                    if showSender { senderLabel.padding(.horizontal, 8).padding(.vertical, 3)
                        .background(Capsule().fill(.black.opacity(0.45))).padding(6) }
                }
                .clipShape(shape)
            } else if Bubble.isEmojiOnly(m.text) && !m.quote.valid && m.attachments.isEmpty {
                VStack(alignment: m.outgoing ? .trailing : .leading, spacing: 2) {
                    if showSender { senderLabel }
                    Text(m.text).font(.system(size: DisplaySettings.shared.size(44)))
                    MetaRow(message: m, pending: pending, color: .secondary, readColor: .primary, isGroup: isGroup)
                }
            } else {
                BubbleContentLayout(spacing: 3) {
                    VStack(alignment: .leading, spacing: 6) {
                        if showSender { senderLabel }
                        if m.quote.valid { QuoteView(quote: m.quote, foreground: fg, outgoing: m.outgoing) }
                        AttachmentStack(message: m, foreground: fg)
                        if m.hasExtraContent { MessageExtraContent(message: m, foreground: fg) }
                        if !m.text.isEmpty && !m.extraReplacesText {
                            FormattedMessageText(message: m, foreground: fg) {
                                Bubble.linkified($0, emojiOnly: Bubble.isEmojiOnly(m.text))
                            }
                        }
                        if m.linkPreview.isValid { LinkPreviewCard(preview: m.linkPreview, foreground: fg) }
                    }
                    MetaRow(message: m, pending: pending, color: fg.opacity(0.7), readColor: fg, isGroup: isGroup)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(shape.fill(bg))
            }
        }
        .overlay {
            if searchHighlightId == m.id {
                shape.strokeBorder(Color.yellow, lineWidth: 2.5)
            }
        }
        .modifier(MaxWidth(480))
        .contentShape(shape)
        .contextMenu { MessageMenu(message: m) }
        .opacity(pending ? 0.7 : 1)
    }

    private var senderLabel: some View {
        Text(message.sender.isEmpty ? model.displayName(message.authorKey) : message.sender)
            .font(.caption.weight(.semibold))
            .foregroundStyle(Theme.senderColor(message.authorKey))
    }

    /// Joined sides of a run get small corners, like the official clients.
    private func bubbleShape(radius r: CGFloat) -> UnevenRoundedRectangle {
        let small = min(r, 4)
        let top = grouping.joinedAbove ? small : r
        let bottom = grouping.joinedBelow ? small : r
        if message.outgoing {
            return UnevenRoundedRectangle(topLeadingRadius: r, bottomLeadingRadius: r, bottomTrailingRadius: bottom,
                                          topTrailingRadius: top, style: .continuous)
        }
        return UnevenRoundedRectangle(topLeadingRadius: top, bottomLeadingRadius: bottom, bottomTrailingRadius: r,
                                      topTrailingRadius: r, style: .continuous)
    }

    /// Up to three emoji and nothing else are shown large.
    static func isEmojiOnly(_ text: String) -> Bool {
        let t = text.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty, t.count <= 3 else { return false }
        return t.allSatisfy { $0.unicodeScalars.first?.properties.isEmojiPresentation == true || ($0.unicodeScalars.count > 1 && $0.unicodeScalars.first?.properties.isEmoji == true) }
    }

    /// Created once: building a detector is expensive and `linkified` runs on every redraw of a bubble.
    private static let linkDetector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)

    private static let linkCache: NSCache<NSString, LinkifiedBox> = { let c = NSCache<NSString, LinkifiedBox>(); c.countLimit = 4000; return c }()

    /// Link detection is slow; rows are rebuilt on every scroll into view, so results are kept.
    static func linkified(_ text: String, emojiOnly: Bool = false) -> AttributedString {
        let zoom = DisplaySettings.shared.textZoom // Settings → Appearance → Text size
        let key = ((emojiOnly ? "1" : "0") + "\(zoom)|" + text) as NSString
        if let hit = linkCache.object(forKey: key) { return hit.value }
        let s = makeLinkified(text, emojiOnly: emojiOnly)
        linkCache.setObject(LinkifiedBox(s), forKey: key)
        return s
    }

    private static func makeLinkified(_ text: String, emojiOnly: Bool) -> AttributedString {
        var s = AttributedString(text)
        let d = DisplaySettings.shared
        s.font = emojiOnly ? .system(size: d.size(40)) : .system(size: d.size(NSFont.systemFontSize + 1))
        guard !emojiOnly, let detector = linkDetector else { return s }
        let ns = text as NSString
        for match in detector.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            guard let url = match.url, ["http", "https", "mailto"].contains(url.scheme?.lowercased() ?? ""),
                  let r = Range(match.range, in: text), let ar = Range(r, in: s) else { continue }
            s[ar].link = url
            s[ar].underlineStyle = .single
        }
        return s
    }
}

final class LinkifiedBox {
    let value: AttributedString
    init(_ v: AttributedString) { value = v }
}

extension Message {
    /// Placeholder shown instead of a message that was deleted for everyone (wording as in Signal Desktop).
    var deletedText: String { outgoing ? "You deleted this message." : "This message was deleted." }
}

/// Timer, "edited", time and delivery state.
private struct MetaRow: View {
    let message: Message
    let pending: Bool
    let color: Color
    let readColor: Color
    let isGroup: Bool
    @Environment(\.messageHovered) private var hovered

    var body: some View {
        HStack(spacing: 3) {
            if message.expiresInSeconds > 0 {
                ExpiryCountdownIcon(seconds: message.expiresInSeconds, startMs: message.expirationStartMs)
            }
            if message.isEdited { Text("Edited") }
            // The full date as a tooltip, installed only under the pointer (a tooltip per row costs scrolling).
            if hovered {
                Text(message.time.formatted(date: .omitted, time: .shortened))
                    .help(message.time.formatted(date: .complete, time: .standard))
            } else {
                Text(message.time.formatted(date: .omitted, time: .shortened))
            }
            if message.sendFailed {
                FailedSendBadge(message: message)
            } else if message.outgoing {
                DeliveryTicks(message: message, pending: pending, isGroup: isGroup,
                              muted: color, read: readColor)
            }
        }
        .font(.system(size: 10, weight: .medium))
        .foregroundStyle(color)
    }
}

private struct QuoteView: View {
    @Environment(AppModel.self) private var model
    let quote: Quote
    let foreground: Color
    let outgoing: Bool

    var body: some View {
        let author = model.displayName(quote.authorKey)
        let accent = outgoing ? foreground : Theme.senderColor(quote.authorKey)
        Button { model.jumpToQuote(quote) } label: {
            HStack(spacing: 8) {
                RoundedRectangle(cornerRadius: 2).fill(accent).frame(width: 3)
                VStack(alignment: .leading, spacing: 2) {
                    Text(author).font(.caption.weight(.semibold)).foregroundStyle(accent)
                    Text(quote.attachmentNote == "story" ? "📖 " + quote.text
                         : quote.text.isEmpty ? (quote.attachmentNote.hasPrefix("image/") ? "📷 Photo" : "📎 Attachment") : quote.text)
                        .font(.callout)
                        .lineLimit(3)
                        .foregroundStyle(foreground.opacity(0.9))
                }
            }
            .padding(.vertical, 6)
            .padding(.leading, 6)
            .padding(.trailing, 10)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(foreground.opacity(0.12)))
        }
        .buttonStyle(.plain)
        .help("Jump to the quoted message")
    }
}

private struct ReactionsView: View {
    @Environment(AppModel.self) private var model
    let message: Message
    @State private var whoShown = false

    var body: some View {
        let counts = Dictionary(grouping: message.reactions, by: \.value).map { ($0.key, $0.value.map(\.key)) }
            .sorted { $0.1.count != $1.1.count ? $0.1.count > $1.1.count : $0.0 < $1.0 }
        HStack(spacing: 4) {
            ForEach(counts, id: \.0) { emoji, who in
                let mine = who.contains(model.account)
                Button { whoShown = true } label: {
                    HStack(spacing: 3) {
                        Text(emoji).font(.system(size: 14))
                        if who.count > 1 { Text("\(who.count)").font(.caption.weight(.semibold)).foregroundStyle(.secondary) }
                    }
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(mine ? Color.secondary.opacity(0.35) : Theme.field))
                    .overlay(Capsule().strokeBorder(model.appearance.backgroundColor, lineWidth: 2))
                }
                .buttonStyle(.plain)
                .help(who.map(model.displayName).joined(separator: ", "))
            }
        }
        .popover(isPresented: $whoShown, arrowEdge: .bottom) {
            ReactorsList(message: message, counts: counts) { whoShown = false }
        }
    }
}

/// Who reacted with what; an own reaction can be taken back here.
private struct ReactorsList: View {
    @Environment(AppModel.self) private var model
    let message: Message
    let counts: [(String, [String])]
    let close: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(counts, id: \.0) { emoji, who in
                    ForEach(who.sorted { model.displayName($0) < model.displayName($1) }, id: \.self) { key in
                        let mine = key == model.account
                        HStack(spacing: 8) {
                            Text(emoji).font(.system(size: 18)).frame(width: 26)
                            AvatarView(image: model.avatars[key] ?? Media.placeholderAvatar(key: key, title: model.displayName(key)), size: 22)
                            Text(mine ? "You" : model.displayName(key)).lineLimit(1)
                            Spacer(minLength: 12)
                            if mine && model.connected {
                                Button("Remove") {
                                    close()
                                    model.sendReaction(message.id, emoji)
                                }
                                .buttonStyle(.link)
                                .font(.caption)
                            }
                        }
                        .padding(.vertical, 3)
                    }
                }
            }
            .padding(10)
        }
        .frame(minWidth: 220, maxHeight: 300)
        .fixedSize(horizontal: true, vertical: false)
    }
}

private struct MessageMenu: View {
    @Environment(AppModel.self) private var model
    let message: Message

    var body: some View {
        let m = message
        if m.sendFailed {
            Button { model.retrySend(m.id) } label: { Label("Retry", systemImage: "arrow.clockwise") }
                .disabled(!model.connected)
            Divider()
        } else if !m.deleted {
            Button { model.startReply(m.id) } label: { Label("Reply", systemImage: "arrowshape.turn.up.left") }
            if m.outgoing && m.authorKey == model.account && m.canEdit(nowMs: nowMs()) {
                Button { model.startEdit(m.id) } label: { Label("Edit", systemImage: "pencil") }
            }
            if !m.viewOnce && !m.isPoll && !(m.text.isEmpty && m.attachments.isEmpty) {
                Button { model.forwardMessageId = m.id } label: { Label("Forward …", systemImage: "arrowshape.turn.up.right") }
                    .disabled(!model.connected)
            }
            if m.isPoll && m.outgoing && !m.poll.ended {
                Button { model.endPoll(m.id) } label: { Label("End poll", systemImage: "stop.circle") }
            }
            Menu { ReactionMenuItems(message: m) } label: { Label("React", systemImage: "face.smiling") }
            PinMenuItems(message: m)
            Divider()
        }
        if !m.text.isEmpty && !m.isPoll {
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(m.text, forType: .string)
            } label: { Label("Copy text", systemImage: "doc.on.doc") }
        }
        ForEach(Array(m.attachments.enumerated()).filter { !$0.element.isSticker && !$0.element.isLongText && !m.viewOnce }, id: \.offset) { i, a in
            Button { model.saveAttachment(m, i) } label: {
                Label("Save “\(a.filename.isEmpty ? "attachment" : a.filename)” …", systemImage: "square.and.arrow.down")
            }
        }
        if !m.deleted {
            Button { model.messageInfoId = m.id } label: { Label("Info …", systemImage: "info.circle") }
        }
        if let key = model.current {
            Button { MessageSelection.shared.begin(key, m.id) } label: { Label("Select", systemImage: "checkmark.circle") }
        }
        Divider()
        Button(role: .destructive) { Task { await model.deleteMessage(m.id) } } label: { Label("Delete …", systemImage: "trash") }
    }
}

/// Limits the width offered to a view without making it wider than its content
/// (`.frame(maxWidth:)` would stretch wrapping text to the maximum).
private struct MaxWidth: ViewModifier {
    let width: CGFloat
    init(_ width: CGFloat) { self.width = width }
    func body(content: Content) -> some View { MaxWidthLayout(maxWidth: width) { content } }
}

/// Stacks the bubble content vertically: everything leading, only the last view (the time row) trailing.
/// A VStack can only align all children the same way, which pushed short texts to the right.
private struct BubbleContentLayout: Layout {
    let spacing: CGFloat

    /// Child sizes per proposed width: measuring text is the expensive part of laying out a bubble,
    /// and SwiftUI asks for the same widths again when placing.
    struct Cache { var sizes: [CGFloat?: [CGSize]] = [:] }

    func makeCache(subviews: Subviews) -> Cache { Cache() }
    func updateCache(_ cache: inout Cache, subviews: Subviews) { cache.sizes.removeAll(keepingCapacity: true) }

    private func sizes(_ width: CGFloat?, _ subviews: Subviews, _ cache: inout Cache) -> [CGSize] {
        if let s = cache.sizes[width] { return s }
        let s = subviews.map { $0.sizeThatFits(ProposedViewSize(width: width, height: nil)) }
        cache.sizes[width] = s
        return s
    }

    // Children are always measured by width only: a proposed height would stretch flexible parts
    // (e.g. the quote's accent bar) when sizing, but not when placing, leaving the bubble too tall.
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) -> CGSize {
        let sizes = sizes(proposal.width, subviews, &cache)
        let height = sizes.map(\.height).reduce(0, +) + spacing * CGFloat(max(sizes.count - 1, 0))
        return CGSize(width: sizes.map(\.width).max() ?? 0, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) {
        var y = bounds.minY
        let all = sizes(bounds.width, subviews, &cache)
        for (i, v) in subviews.enumerated() {
            let size = all[i]
            let x = i == subviews.count - 1 ? bounds.maxX - size.width : bounds.minX
            v.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(width: size.width, height: size.height))
            y += size.height + spacing
        }
    }
}

private struct MaxWidthLayout: Layout {
    let maxWidth: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let v = subviews.first else { return .zero }
        let w = min(proposal.width ?? maxWidth, maxWidth)
        return v.sizeThatFits(ProposedViewSize(width: w, height: proposal.height))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(at: bounds.origin, proposal: ProposedViewSize(width: bounds.width, height: bounds.height))
    }
}

