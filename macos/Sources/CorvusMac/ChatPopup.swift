import AppKit
import CorvusCore
import SwiftUI

/// Chats opened in their own window ("Open in new window", like Signal Desktop's pop-out chats).
///
/// The main window's chat pane is built around the one selected chat (`AppModel.current`: composer,
/// search, scroll and attachment state all hang on it), so a pop-out window has its own lighter view: the
/// messages, a reply, and a text composer with its own draft. Attachments, reactions and the other message
/// actions open the chat in the main window.
@MainActor @Observable
final class ChatPopups {
    static let shared = ChatPopups()
    static let windowId = "chat"

    /// Chats whose pop-out window is the key window (the user reads them there).
    @ObservationIgnored private var keyWindows: [String: Int] = [:]
    /// Unsent text and reply of each pop-out window, by chat. Kept when the window closes.
    @ObservationIgnored var drafts: [String: (text: String, quote: Quote)] = [:]

    func isLooking(at key: String) -> Bool { NSApp.isActive && (keyWindows[key] ?? 0) > 0 }

    func setKey(_ key: String, _ isKey: Bool) {
        let n = max(0, (keyWindows[key] ?? 0) + (isKey ? 1 : -1))
        keyWindows[key] = n == 0 ? nil : n
    }
}

/// "Open in new window" for chat context menus.
struct OpenInNewWindowButton: View {
    @Environment(\.openWindow) private var openWindow
    let key: String

    var body: some View {
        Button { openWindow(id: ChatPopups.windowId, value: key) } label: {
            Label("Open in new window", systemImage: "macwindow.on.rectangle")
        }
    }
}

struct ChatPopupWindow: View {
    @Environment(AppModel.self) private var model
    let key: String

    var body: some View {
        Group {
            if !model.historyReady {
                ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let c = model.chats.convs[key] {
                ChatPopupContent(conversation: c)
            } else {
                Text("This chat no longer exists.").foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(minWidth: 340, minHeight: 360)
        .tint(Theme.signalBlue)
    }
}

private struct ChatPopupContent: View {
    @Environment(AppModel.self) private var model
    let conversation: Conversation
    @State private var text = ""
    @State private var quote = Quote()
    @State private var error: String?
    @State private var isKey = false
    @State private var focus = 0

    var body: some View {
        let c = conversation
        VStack(spacing: 0) {
            PopupMessageList(conversation: c, pendingTs: model.chats.pendingTimestamps(c.key),
                             onReply: { startReply($0) })
                .equatable()
                .background(model.appearance.backgroundColor)
            if let error {
                HStack {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    Text(error).font(.caption).lineLimit(2)
                    Spacer()
                    Button { self.error = nil } label: { Image(systemName: "xmark") }
                        .buttonStyle(.borderless)
                        .iconHelp("Dismiss")
                }
                .padding(.horizontal, 12).padding(.vertical, 6)
                .background(.bar)
            }
            if quote.valid { replyBar }
            composer(c)
        }
        .navigationTitle(model.visibleTitle(c))
        .toolbar {
            ToolbarItem(placement: .navigation) { header(c) }
            ToolbarItem(placement: .automatic) {
                Button { model.activateConversation(c.key) } label: { Label("Open in main window", systemImage: "rectangle.portrait.and.arrow.right") }
                    .iconHelp("Open in main window")
            }
        }
        .background(PopupWindowObserver(key: c.key, isKey: $isKey))
        .onAppear {
            if let d = ChatPopups.shared.drafts[c.key] {
                text = d.text
                quote = d.quote
            }
        }
        .onChange(of: text) { saveDraft() }
        .onChange(of: quote) { saveDraft() }
        // Messages arriving while this window is in front are read here, like in the main window.
        .onChange(of: isKey) { markReadIfLooking() }
        .onChange(of: c.unread) { markReadIfLooking() }
        .onChange(of: c.markedUnread) { markReadIfLooking() }
    }

    private func header(_ c: Conversation) -> some View {
        HStack(spacing: 8) {
            AvatarView(image: model.avatarImage(c), size: 26)
            VStack(alignment: .leading, spacing: 0) {
                Text(model.visibleTitle(c)).font(.headline).lineLimit(1)
                if let typing = model.typingLabel(c.key) {
                    Text(typing).font(.caption).foregroundStyle(Theme.signalBlue).lineLimit(1)
                } else if c.isGroup {
                    Text("Group").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    private var replyBar: some View {
        HStack(spacing: 8) {
            RoundedRectangle(cornerRadius: 2).fill(Theme.signalBlue).frame(width: 3)
            VStack(alignment: .leading, spacing: 1) {
                Text("Reply to " + (quote.authorKey == model.account ? "yourself" : model.displayName(quote.authorKey)))
                    .font(.caption.weight(.semibold))
                Text(quote.text.isEmpty ? "Attachment" : quote.text).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            Button { quote = Quote() } label: { Image(systemName: "xmark.circle.fill") }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .iconHelp("Cancel reply", tooltip: "Cancel reply (Esc)")
        }
        .frame(height: 34)
        .padding(.horizontal, 12)
        .padding(.top, 6)
        .background(.bar)
    }

    private func composer(_ c: Conversation) -> some View {
        let locked = model.isSendLocked(c.key)
        let canSend = !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && model.connected && !locked
        return HStack(alignment: .bottom, spacing: 8) {
            PopupTextInput(text: $text, placeholder: locked ? "Accept the message request in the main window" : "Message",
                           focusRequest: focus, onSend: send, onCancel: { quote = Quote() })
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Theme.field))
                .disabled(locked)
            Button(action: send) {
                Image(systemName: "arrow.up.circle.fill").font(.system(size: 24))
            }
            .buttonStyle(.borderless)
            .foregroundStyle(canSend ? Theme.signalBlue : Color.secondary)
            .disabled(!canSend)
            .iconHelp("Send", tooltip: model.connected ? "Send (Return)" : "Not connected to Signal")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(.bar)
    }

    private func startReply(_ m: Message) {
        var q = Quote()
        q.valid = true
        q.id = m.latestTs
        q.authorKey = model.chats.effectiveAuthor(conversation, m)
        q.text = m.text
        if m.text.isEmpty, let a = m.attachments.first { q.attachmentNote = a.contentType }
        quote = q
        focus += 1
    }

    private func send() {
        let key = conversation.key, sent = text, sentQuote = quote
        guard !sent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        error = nil
        text = ""
        quote = Quote()
        model.markReadWithoutOpening(key)
        model.sendQuickText(sent, to: key, quote: sentQuote) { why in
            error = "Not sent: \(why)"
            if text.isEmpty { // give the text back unless something new was typed
                text = sent
                if !quote.valid { quote = sentQuote }
            }
        }
    }

    private func saveDraft() {
        let key = conversation.key
        if text.isEmpty && !quote.valid {
            ChatPopups.shared.drafts[key] = nil
        } else {
            ChatPopups.shared.drafts[key] = (text, quote)
        }
    }

    private func markReadIfLooking() {
        let c = conversation
        guard isKey, NSApp.isActive, c.unread > 0 || c.markedUnread else { return }
        model.markReadWithoutOpening(c.key)
    }
}

// MARK: - Messages

private struct PopupMessageList: View, Equatable {
    @Environment(AppModel.self) private var model
    let conversation: Conversation
    let pendingTs: Set<Int64>
    let onReply: (Message) -> Void

    /// Rebuilt only when this chat changes (the message array is compared by identity, see `MessageList`).
    static func == (a: PopupMessageList, b: PopupMessageList) -> Bool {
        let ca = a.conversation, cb = b.conversation
        return a.pendingTs == b.pendingTs && ca.key == cb.key && ca.title == cb.title && ca.msgs.count == cb.msgs.count
            && ca.msgs.withUnsafeBufferPointer { pa in cb.msgs.withUnsafeBufferPointer { pa.baseAddress == $0.baseAddress } }
    }

    var body: some View {
        let c = conversation
        let msgs = c.msgs
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 4) {
                    ForEach(msgs.indices, id: \.self) { i in
                        let m = msgs[i]
                        let prev = i > 0 ? msgs[i - 1] : nil
                        if prev.map({ !Calendar.current.isDate($0.time, inSameDayAs: m.time) }) ?? true {
                            Text(m.time.formatted(date: .abbreviated, time: .omitted))
                                .font(.caption.weight(.medium))
                                .foregroundStyle(.secondary)
                                .padding(.vertical, 6)
                        }
                        let firstOfRun = prev.map { $0.outgoing != m.outgoing || $0.authorKey != m.authorKey } ?? true
                        PopupBubble(message: m, isGroup: c.isGroup, showSender: c.isGroup && !m.outgoing && firstOfRun,
                                    pending: pendingTs.contains(m.ts), conversationKey: c.key, onReply: onReply)
                            .id(m.id)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
            }
            .defaultScrollAnchor(.bottom)
            .onChange(of: msgs.last?.id) { _, id in
                if let id { withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(id, anchor: .bottom) } }
            }
            .overlay {
                if msgs.isEmpty { Text("No messages yet").foregroundStyle(.secondary) }
            }
        }
    }
}

private struct PopupBubble: View {
    @Environment(AppModel.self) private var model
    let message: Message
    let isGroup: Bool
    let showSender: Bool
    let pending: Bool
    let conversationKey: String
    let onReply: (Message) -> Void

    var body: some View {
        let m = message
        let a = model.appearance
        let fg = m.outgoing ? a.outTextColor : a.inTextColor
        let bg = m.outgoing ? a.outBgColor : a.inBgColor
        HStack(alignment: .bottom, spacing: 0) {
            if m.outgoing { Spacer(minLength: 48) }
            VStack(alignment: m.outgoing ? .trailing : .leading, spacing: 2) {
                VStack(alignment: .leading, spacing: 5) {
                    if showSender {
                        Text(m.sender.isEmpty ? model.displayName(m.authorKey) : m.sender)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Theme.senderColor(m.authorKey))
                    }
                    if m.quote.valid && !m.deleted { quoteView(m.quote, fg) }
                    content(m, fg)
                    HStack(spacing: 4) {
                        if m.isEdited && !m.deleted { Text("Edited") }
                        Text(m.time.formatted(date: .omitted, time: .shortened))
                        if m.outgoing && !m.deleted {
                            DeliveryTicks(message: m, pending: pending, isGroup: isGroup, muted: fg.opacity(0.7), read: fg)
                        }
                    }
                    .font(.caption2)
                    .foregroundStyle(fg.opacity(0.7))
                    .frame(maxWidth: .infinity, alignment: .trailing)
                }
                .padding(.horizontal, 11)
                .padding(.vertical, 7)
                .background(RoundedRectangle(cornerRadius: CGFloat(a.radius), style: .continuous).fill(bg))
                .frame(maxWidth: 380, alignment: m.outgoing ? .trailing : .leading)
                .fixedSize(horizontal: false, vertical: true)
                if !m.reactions.isEmpty { reactions(m) }
            }
            .opacity(pending ? 0.7 : 1)
            .contextMenu { menu(m) }
            if !m.outgoing { Spacer(minLength: 48) }
        }
        .environment(\.conversationKey, conversationKey)
    }

    @ViewBuilder
    private func content(_ m: Message, _ fg: Color) -> some View {
        if m.deleted {
            Text(m.outgoing ? "You deleted this message." : "This message was deleted.").italic().foregroundStyle(fg.opacity(0.7))
        } else if m.viewOnce {
            Label("View once media", systemImage: "1.circle").foregroundStyle(fg)
        } else if m.isPoll {
            Label(m.poll.question, systemImage: "chart.bar.xaxis").foregroundStyle(fg)
        } else {
            ForEach(Array(m.attachments.enumerated()), id: \.offset) { _, att in
                Button { model.activateConversation(conversationKey); model.scrollToMessage(id: m.id) } label: {
                    Label(Self.attachmentTitle(att), systemImage: Self.attachmentIcon(att))
                        .foregroundStyle(fg)
                        .lineLimit(1)
                }
                .buttonStyle(.plain)
                .help("Show in the main window")
            }
            if !m.text.isEmpty {
                FormattedMessageText(message: m, foreground: fg) { PopupBubble.linkified($0) }
            }
        }
    }

    private func quoteView(_ q: Quote, _ fg: Color) -> some View {
        HStack(spacing: 6) {
            RoundedRectangle(cornerRadius: 2).fill(fg.opacity(0.8)).frame(width: 3)
            VStack(alignment: .leading, spacing: 1) {
                Text(q.authorKey == model.account ? "You" : model.displayName(q.authorKey)).font(.caption.weight(.semibold))
                Text(q.text.isEmpty ? "Attachment" : q.text).font(.caption).lineLimit(2)
            }
        }
        .foregroundStyle(fg)
        .padding(5)
        .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(fg.opacity(0.12)))
    }

    private func reactions(_ m: Message) -> some View {
        let counts = Dictionary(grouping: m.reactions.values, by: { $0 }).map { ($0.key, $0.value.count) }.sorted { $0.1 > $1.1 }
        return HStack(spacing: 4) {
            ForEach(counts, id: \.0) { emoji, n in Text(n > 1 ? "\(emoji) \(n)" : emoji).font(.caption) }
        }
        .padding(.horizontal, 6).padding(.vertical, 2)
        .background(Capsule().fill(.regularMaterial))
    }

    @ViewBuilder
    private func menu(_ m: Message) -> some View {
        if !m.deleted && model.connected {
            Button { onReply(m) } label: { Label("Reply", systemImage: "arrowshape.turn.up.left") }
        }
        if !m.text.isEmpty && !m.deleted {
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(m.text, forType: .string)
            } label: { Label("Copy text", systemImage: "doc.on.doc") }
        }
        Button { model.activateConversation(conversationKey); model.scrollToMessage(id: m.id) } label: {
            Label("Show in main window", systemImage: "rectangle.portrait.and.arrow.right")
        }
    }

    static func attachmentTitle(_ a: Attachment) -> String {
        if a.isSticker { return "Sticker" }
        if a.isGif { return "GIF" }
        if a.isImage { return "Photo" }
        if a.isVideo { return "Video" }
        if a.isAudio { return "Voice message" }
        return a.filename.isEmpty ? "File" : a.filename
    }

    static func attachmentIcon(_ a: Attachment) -> String {
        a.isImage || a.isSticker ? "photo" : a.isVideo ? "film" : a.isAudio ? "waveform" : "paperclip"
    }

    private static let linkDetector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)

    static func linkified(_ text: String) -> AttributedString {
        var s = AttributedString(text)
        s.font = .system(size: NSFont.systemFontSize + 1)
        guard let detector = linkDetector else { return s }
        for match in detector.matches(in: text, range: NSRange(location: 0, length: (text as NSString).length)) {
            guard let url = match.url, ["http", "https", "mailto"].contains(url.scheme?.lowercased() ?? ""),
                  let r = Range(match.range, in: text), let ar = Range(r, in: s) else { continue }
            s[ar].link = url
            s[ar].underlineStyle = .single
        }
        return s
    }
}

// MARK: - Window state

/// Tells the view whether its window is the key window, and keeps `ChatPopups` informed.
private struct PopupWindowObserver: NSViewRepresentable {
    let key: String
    @Binding var isKey: Bool

    func makeNSView(context: Context) -> ObserverView {
        let v = ObserverView()
        v.key = key
        v.onChange = { isKey = $0 }
        return v
    }

    func updateNSView(_ v: ObserverView, context: Context) { v.onChange = { isKey = $0 } }

    static func dismantleNSView(_ v: ObserverView, coordinator: ()) { v.detach() }

    final class ObserverView: NSView {
        var key = ""
        var onChange: ((Bool) -> Void)?
        private var observers: [NSObjectProtocol] = []
        private var reportedKey = false

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            detach()
            guard let window else { return }
            window.setFrameAutosaveName("chat-popup") // pop-outs open where the last one was
            let nc = NotificationCenter.default
            for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification, NSWindow.willCloseNotification] {
                observers.append(nc.addObserver(forName: name, object: window, queue: .main) { [weak self] n in
                    MainActor.assumeIsolated { self?.update(n.name == NSWindow.didBecomeKeyNotification) }
                })
            }
            update(window.isKeyWindow)
        }

        private func update(_ isKey: Bool) {
            if isKey != reportedKey {
                reportedKey = isKey
                ChatPopups.shared.setKey(key, isKey)
            }
            onChange?(isKey)
        }

        func detach() {
            observers.forEach { NotificationCenter.default.removeObserver($0) }
            observers = []
            if reportedKey {
                reportedKey = false
                ChatPopups.shared.setKey(key, false)
            }
        }
    }
}

// MARK: - Composer

/// A plain multi-line text field: Return sends, Shift+Return or Option+Return starts a new line, Esc cancels
/// the reply. Grows with its text up to six lines.
private struct PopupTextInput: NSViewRepresentable {
    @Binding var text: String
    let placeholder: String
    let focusRequest: Int
    let onSend: () -> Void
    let onCancel: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        let tv = PlaceholderTextView()
        tv.delegate = context.coordinator
        tv.isRichText = false
        tv.allowsUndo = true
        tv.drawsBackground = false
        tv.font = .systemFont(ofSize: NSFont.systemFontSize + 1)
        tv.textContainerInset = NSSize(width: 0, height: 2)
        tv.isVerticallyResizable = true
        tv.isHorizontallyResizable = false
        tv.autoresizingMask = [.width]
        tv.textContainer?.widthTracksTextView = true
        tv.placeholder = placeholder
        tv.setAccessibilityLabel("Message")
        scroll.documentView = tv
        context.coordinator.textView = tv
        DispatchQueue.main.async { tv.window?.makeFirstResponder(tv) }
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let tv = context.coordinator.textView else { return }
        if tv.string != text { tv.string = text }
        if tv.placeholder != placeholder {
            tv.placeholder = placeholder
            tv.needsDisplay = true
        }
        if context.coordinator.lastFocus != focusRequest {
            context.coordinator.lastFocus = focusRequest
            DispatchQueue.main.async { tv.window?.makeFirstResponder(tv) }
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSScrollView, context: Context) -> CGSize? {
        guard let tv = context.coordinator.textView, let lm = tv.layoutManager, let tc = tv.textContainer else { return nil }
        let width = proposal.width ?? 300
        tc.containerSize = NSSize(width: max(width, 50), height: .greatestFiniteMagnitude)
        lm.ensureLayout(for: tc)
        let line = (tv.font ?? .systemFont(ofSize: 14)).boundingRectForFont.height
        let used = max(lm.usedRect(for: tc).height, line)
        return CGSize(width: width, height: min(used, line * 6) + 4)
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: PopupTextInput
        weak var textView: PlaceholderTextView?
        var lastFocus = 0

        init(_ parent: PopupTextInput) {
            self.parent = parent
            lastFocus = parent.focusRequest
        }

        func textDidChange(_ notification: Notification) {
            guard let tv = textView else { return }
            parent.text = tv.string
        }

        func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            switch selector {
            case #selector(NSResponder.insertNewline(_:)):
                let flags = NSApp.currentEvent?.modifierFlags ?? []
                if flags.contains(.shift) || flags.contains(.option) {
                    textView.insertNewlineIgnoringFieldEditor(nil)
                } else {
                    parent.onSend()
                }
                return true
            case #selector(NSResponder.cancelOperation(_:)):
                parent.onCancel()
                return true
            default:
                return false
            }
        }
    }
}

private final class PlaceholderTextView: NSTextView {
    var placeholder = ""

    override func paste(_ sender: Any?) { pasteAsPlainText(sender) }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard string.isEmpty, !placeholder.isEmpty else { return }
        let attrs: [NSAttributedString.Key: Any] = [.foregroundColor: NSColor.placeholderTextColor, .font: font ?? .systemFont(ofSize: 13)]
        let origin = NSPoint(x: textContainerInset.width + (textContainer?.lineFragmentPadding ?? 5), y: textContainerInset.height)
        (placeholder as NSString).draw(at: origin, withAttributes: attrs)
    }
}
