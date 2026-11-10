import AppKit
import CorvusCore
import SwiftUI

/// Edit / reply / attachment previews and the message input of the current conversation.
struct ComposerArea: View {
    @Environment(AppModel.self) private var model
    @State private var emojiShown = false
    @State private var stickersShown = false
    @State private var gifsShown = false

    var body: some View {
        @Bindable var model = model
        let canSend = !(model.composerText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && model.pendingFiles.isEmpty)
        VStack(spacing: 8) {
            if !model.editKey.isEmpty {
                ComposerCard(icon: "pencil", title: "Edit message", text: "Return saves · Esc cancels") { model.cancelEdit() }
            }
            if model.replyQuote.valid {
                ComposerCard(icon: "arrowshape.turn.up.left",
                             title: "Replying to \(model.displayName(model.replyQuote.authorKey))",
                             text: replyText, accent: Theme.senderColor(model.replyQuote.authorKey)) { model.replyQuote = Quote() }
            }
            if let lp = model.linkDraft.visiblePreview {
                LinkPreviewChip(preview: lp) { model.linkDraft.dismiss() }
            }
            if !model.pendingFiles.isEmpty {
                AttachmentTray(files: model.pendingFiles) { f in
                    model.pendingFiles.removeAll { $0 == f }
                    if model.pendingFiles.isEmpty { model.pendingGifAnalyticsUrl = nil }
                }
            }
            MentionSuggestionList()
            EmojiSuggestionList()
            if model.isRecording {
                RecordingBar()
            } else {
            HStack(alignment: .bottom, spacing: 8) {
                // The field with the emoji button inside, like the Signal clients.
                HStack(alignment: .bottom, spacing: 2) {
                    Button { emojiShown.toggle() } label: {
                        Image(systemName: "face.smiling").font(.system(size: 17)).frame(width: 28, height: 30)
                    }
                    .iconHelp("Emoji")
                    .popover(isPresented: $emojiShown, arrowEdge: .top) {
                        EmojiPicker { e in
                            NotificationCenter.default.post(name: MessageInput.insertText, object: e)
                        }
                    }
                    MessageInput(text: $model.composerText)
                        .frame(minHeight: 30)
                }
                .padding(.leading, 6)
                .padding(.trailing, 4)
                .background(RoundedRectangle(cornerRadius: 17, style: .continuous).fill(Theme.field))

                Button { gifsShown.toggle() } label: {
                    Text("GIF")
                        .font(.system(size: 10, weight: .heavy))
                        .padding(.horizontal, 4)
                        .padding(.vertical, 2)
                        .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(lineWidth: 1.5))
                        .frame(width: 30, height: 34)
                }
                .iconHelp("GIFs", tooltip: "Search GIPHY GIFs")
                .popover(isPresented: $gifsShown, arrowEdge: .top) {
                    GifPopover { gifsShown = false }
                }
                Button { stickersShown.toggle() } label: {
                    Image(systemName: "seal").font(.system(size: 17)).frame(width: 30, height: 34)
                }
                .iconHelp("Stickers")
                .popover(isPresented: $stickersShown, arrowEdge: .top) {
                    StickerPicker { stickersShown = false }
                }
                .onChange(of: model.stickerPackAddRequest) { stickersShown = true }
                Menu {
                    Button { model.chooseAttachments() } label: { Label("Attach files …", systemImage: "paperclip") }
                    Button { model.pollComposerShown = true } label: { Label("Poll …", systemImage: "chart.bar.xaxis") }
                } label: {
                    Image(systemName: "paperclip").font(.system(size: 17))
                } primaryAction: {
                    model.chooseAttachments()
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .frame(width: 30, height: 34)
                .iconHelp("Attach files", tooltip: "Attach files (hold for more: poll)")
                if model.canSendViewOnce {
                    Button { model.viewOnceNext.toggle() } label: {
                        Text("1×").font(.system(size: 13, weight: .bold))
                            .foregroundStyle(model.viewOnceNext ? Color.white : Color.secondary)
                            .frame(width: 28, height: 28)
                            .background(Circle().fill(model.viewOnceNext ? Theme.signalBlue : Color.clear))
                            .overlay(Circle().strokeBorder(Color.secondary.opacity(0.5)))
                    }
                    .iconHelp(model.viewOnceNext ? "View once: on" : "Send as view once")
                }
                if !canSend && model.editKey.isEmpty {
                    Button { model.startRecording() } label: {
                        Image(systemName: "mic").font(.system(size: 17)).frame(width: 30, height: 34)
                    }
                    .iconHelp("Record a voice message")
                }
                Button { model.sendMessage() } label: {
                    Image(systemName: model.editKey.isEmpty ? "arrow.up" : "checkmark")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 32, height: 32)
                        .background(Circle().fill(canSend ? Theme.signalBlue : Color.secondary.opacity(0.35)))
                }
                .iconHelp(model.editKey.isEmpty ? "Send" : "Save edit", tooltip: model.editKey.isEmpty ? "Send (Return)" : "Save edit (Return)")
                .disabled(!canSend)
                .animation(.easeOut(duration: 0.15), value: canSend)
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .disabled(!model.connected)
            }
        }
        .sheet(isPresented: $model.pollComposerShown) { PollComposerSheet() }
        .modifier(LinkPreviewTriggers())
        .onChange(of: model.canSendViewOnce) { _, ok in if !ok { model.viewOnceNext = false } }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Theme.chrome)
        .overlay(alignment: .top) { Divider() }
    }

    private var replyText: String {
        var t = model.replyQuote.text.isEmpty ? "📎 Attachment" : model.replyQuote.text
        t = t.replacingOccurrences(of: "\n", with: " ")
        if t.count > 120 { t = String(t.prefix(120)) + "…" }
        return t
    }
}

/// Reply / edit preview above the field.
private struct ComposerCard: View {
    let icon: String
    let title: String
    let text: String
    var accent: Color = Theme.signalBlue
    let close: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            RoundedRectangle(cornerRadius: 2).fill(accent).frame(width: 3)
            Image(systemName: icon).foregroundStyle(accent)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.caption.weight(.semibold)).foregroundStyle(accent)
                Text(text).font(.callout).lineLimit(1).truncationMode(.tail).foregroundStyle(.secondary)
            }
            Spacer()
            Button(action: close) { Image(systemName: "xmark.circle.fill").font(.system(size: 15)) }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
        }
        .padding(8)
        .frame(height: 48)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.field))
    }
}

/// Files queued for the next message: image thumbnails or file chips, each removable.
private struct AttachmentTray: View {
    let files: [String]
    let remove: (String) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(files, id: \.self) { f in
                    ZStack(alignment: .topTrailing) {
                        Group {
                            if Media.mimeType(forFile: f).hasPrefix("image/") {
                                PendingImageThumb(path: f)
                            } else {
                                VStack(spacing: 4) {
                                    Image(systemName: "doc.fill").font(.title3)
                                    Text((f as NSString).lastPathComponent).font(.caption2).lineLimit(2)
                                        .multilineTextAlignment(.center)
                                }
                                .padding(6)
                                .frame(width: 96, height: 64)
                                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Theme.field))
                            }
                        }
                        .help((f as NSString).lastPathComponent)
                        Button { remove(f) } label: {
                            Image(systemName: "xmark.circle.fill")
                                .symbolRenderingMode(.palette)
                                .foregroundStyle(.white, .black.opacity(0.6))
                                .font(.system(size: 16))
                        }
                        .buttonStyle(.plain)
                        .iconHelp("Remove \((f as NSString).lastPathComponent)")
                        .offset(x: 5, y: -5)
                    }
                }
            }
            .padding(.top, 6)
            .padding(.horizontal, 2)
        }
    }
}

/// A queued picture, decoded once off the main thread at thumbnail size.
private struct PendingImageThumb: View {
    let path: String
    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
            } else {
                Rectangle().fill(Theme.field)
            }
        }
        .frame(width: 64, height: 64)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .task(id: path) {
            let path = path
            image = await MediaImageCache.shared.image("pending:" + path) {
                await Task.detached(priority: .userInitiated) {
                    (try? Data(contentsOf: URL(fileURLWithPath: path))).flatMap { MediaDecode.image($0, maxPixel: 192) }
                }.value
            }
        }
    }
}

/// Multi-line message field: Return sends, Shift/Option+Return inserts a line break, ↑ in an empty field
/// edits the last message, Esc cancels an edit, then a reply, then closes the search, ⌘B / ⌘I add bold /
/// italic markers, "@" in a group suggests members, and pasting a screenshot or files attaches them.
struct MessageInput: NSViewRepresentable {
    static let insertText = Notification.Name("MessageInput.insertText")

    static let spellCheckKey = "composer.spellCheck"

    @Environment(AppModel.self) private var model
    @AppStorage(MessageInput.spellCheckKey) private var spellCheck = false
    @Binding var text: String

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder

        let tv = InputTextView()
        tv.delegate = context.coordinator
        tv.isRichText = false
        tv.importsGraphics = false
        tv.allowsUndo = true
        tv.font = .systemFont(ofSize: NSFont.systemFontSize + 1)
        tv.textContainerInset = NSSize(width: 2, height: 7)
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.isAutomaticDashSubstitutionEnabled = false
        tv.drawsBackground = false
        tv.isVerticallyResizable = true
        tv.isHorizontallyResizable = false
        tv.autoresizingMask = [.width]
        tv.textContainer?.widthTracksTextView = true
        tv.placeholder = "Write a message …"
        if #available(macOS 15.0, *) { tv.writingToolsBehavior = .none } // no "Write with Siri" pill in the composer
        tv.coordinator = context.coordinator
        scroll.documentView = tv

        context.coordinator.textView = tv
        context.coordinator.scroll = scroll
        context.coordinator.observeInsertions()
        MentionAutocomplete.shared.insert = { [weak coordinator = context.coordinator] in coordinator?.insertMention($0) }
        EmojiAutocomplete.shared.insert = { [weak coordinator = context.coordinator] in coordinator?.insertEmojiShortcode($0) }
        DispatchQueue.main.async { tv.window?.makeFirstResponder(tv) }
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        let c = context.coordinator
        c.parent = self
        guard let tv = c.textView else { return }
        if tv.string != text {
            tv.string = text
            tv.needsDisplay = true
            MentionAutocomplete.shared.hide() // sent, or another chat's draft
            EmojiAutocomplete.shared.hide()
        }
        tv.isEditable = model.connected && model.canCompose
        // Settings → General: spell checking, grammar and autocorrect follow one switch.
        if tv.isContinuousSpellCheckingEnabled != spellCheck {
            tv.isContinuousSpellCheckingEnabled = spellCheck
            tv.isGrammarCheckingEnabled = spellCheck
            tv.isAutomaticSpellingCorrectionEnabled = spellCheck
        }
        if c.focusRequest != model.composerFocusRequest {
            c.focusRequest = model.composerFocusRequest
            DispatchQueue.main.async { tv.window?.makeFirstResponder(tv) }
        }
        if c.cursorRequest != model.composerCursorToEnd {
            c.cursorRequest = model.composerCursorToEnd
            tv.setSelectedRange(NSRange(location: (tv.string as NSString).length, length: 0))
        }
        c.updateHeight()
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: MessageInput
        weak var textView: InputTextView?
        weak var scroll: NSScrollView?
        var focusRequest = -1
        var cursorRequest = 0
        private var heightConstraint: NSLayoutConstraint?
        private var observer: NSObjectProtocol?

        init(_ parent: MessageInput) {
            self.parent = parent
            self.cursorRequest = 0
        }

        func observeInsertions() {
            observer = NotificationCenter.default.addObserver(forName: MessageInput.insertText, object: nil, queue: .main) { [weak self] n in
                MainActor.assumeIsolated {
                    guard let self, let tv = self.textView, let s = n.object as? String else { return }
                    tv.insertText(s, replacementRange: tv.selectedRange())
                    tv.window?.makeFirstResponder(tv)
                }
            }
        }

        func textDidChange(_ notification: Notification) {
            guard let tv = textView else { return }
            if parent.text != tv.string { parent.text = tv.string }
            updateHeight()
            updateMentions()
            updateEmojiShortcodes(afterEdit: true)
            parent.model.composerEdited()
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            updateMentions()
            updateEmojiShortcodes(afterEdit: false)
        }

        /// Shows the members matching the "@…" before the caret (groups only).
        func updateMentions() {
            let ac = MentionAutocomplete.shared
            let model = parent.model
            guard let tv = textView, let key = model.current, model.chats.convs[key]?.isGroup == true,
                  tv.selectedRange().length == 0,
                  let q = mentionQuery(text: tv.string, caret: tv.selectedRange().location)
            else { ac.hide(); return }
            ac.show(range: q.range, mentionSuggestions(q.query, model.mentionCandidates(key)))
        }

        func insertMention(_ c: MentionCandidate) {
            guard let tv = textView, let r = MentionAutocomplete.shared.range,
                  r.location + r.length <= (tv.string as NSString).length else { return }
            tv.insertText("@" + c.name + " ", replacementRange: r)
            MentionAutocomplete.shared.hide()
            tv.window?.makeFirstResponder(tv)
        }

        /// 1 … 6 lines high.
        func updateHeight() {
            guard let tv = textView, let scroll, let lm = tv.layoutManager, let tc = tv.textContainer else { return }
            lm.ensureLayout(for: tc)
            let lineHeight = (tv.font?.boundingRectForFont.height ?? 17)
            let content = lm.usedRect(for: tc).height + tv.textContainerInset.height * 2
            let h = min(max(content, lineHeight + tv.textContainerInset.height * 2), lineHeight * 6 + tv.textContainerInset.height * 2)
            if heightConstraint == nil {
                heightConstraint = scroll.heightAnchor.constraint(equalToConstant: h)
                heightConstraint?.isActive = true
            } else if abs((heightConstraint?.constant ?? 0) - h) > 0.5 {
                heightConstraint?.constant = h
            }
        }

        func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            let model = parent.model
            let flags = NSApp.currentEvent?.modifierFlags ?? []
            if handleEmojiCommand(selector) { return true }
            let mentions = MentionAutocomplete.shared
            if mentions.active {
                switch selector {
                case #selector(NSResponder.moveUp(_:)): mentions.move(-1); return true
                case #selector(NSResponder.moveDown(_:)): mentions.move(1); return true
                case #selector(NSResponder.insertNewline(_:)), #selector(NSResponder.insertTab(_:)):
                    if let c = mentions.selected { insertMention(c) }
                    return true
                case #selector(NSResponder.cancelOperation(_:)): mentions.dismiss(); return true
                default: break
                }
            }
            switch selector {
            case #selector(NSResponder.insertNewline(_:)):
                if flags.contains(.shift) || flags.contains(.option) {
                    textView.insertNewlineIgnoringFieldEditor(nil)
                } else {
                    model.sendMessage()
                }
                return true
            case #selector(NSResponder.cancelOperation(_:)):
                if !model.editKey.isEmpty {
                    model.cancelEdit()
                    return true
                }
                if model.replyQuote.valid {
                    model.replyQuote = Quote()
                    return true
                }
                if model.searchVisible {
                    model.closeSearch()
                    return true
                }
                return false
            case #selector(NSResponder.moveUp(_:)):
                if textView.string.isEmpty { return model.editLastMessage() }
                return false
            case #selector(NSResponder.moveUpAndModifySelection(_:)):
                // Shift+↑ selects the whole current draft.
                if !textView.string.isEmpty {
                    textView.selectAll(nil)
                    return true
                }
                return false
            default:
                return false
            }
        }

        func paste(from pb: NSPasteboard) -> Bool { parent.model.attach(from: pb) }
    }
}

final class InputTextView: NSTextView {
    weak var coordinator: MessageInput.Coordinator?
    var placeholder = ""

    // Screenshots and copied files become attachments; real text is pasted as usual.
    override func paste(_ sender: Any?) {
        if let coordinator, MainActor.assumeIsolated({ coordinator.paste(from: .general) }) { return }
        pasteAsPlainText(sender)
    }

    // A plain-text view only accepts text types, so Paste would be disabled for a screenshot on the clipboard.
    override var readablePasteboardTypes: [NSPasteboard.PasteboardType] {
        super.readablePasteboardTypes + [.png, .tiff, .fileURL]
    }

    override func readSelection(from pboard: NSPasteboard, type: NSPasteboard.PasteboardType) -> Bool {
        if let coordinator, MainActor.assumeIsolated({ coordinator.paste(from: pboard) }) { return true }
        return super.readSelection(from: pboard, type: type)
    }

    /// ⌘B / ⌘I: the composer is plain text with markdown markers (see `parseMarkdownStyles`).
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if isEditable, window?.firstResponder === self, flags == .command,
           let key = event.charactersIgnoringModifiers?.lowercased(), key == "b" || key == "i" {
            let r = toggleMarker(key == "b" ? "**" : "_", text: string, selection: selectedRange())
            insertText(r.replacement, replacementRange: r.range)
            setSelectedRange(r.selection)
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard string.isEmpty, !placeholder.isEmpty else { return }
        let attrs: [NSAttributedString.Key: Any] = [.foregroundColor: NSColor.placeholderTextColor, .font: font ?? .systemFont(ofSize: 13)]
        let origin = NSPoint(x: textContainerInset.width + (textContainer?.lineFragmentPadding ?? 5), y: textContainerInset.height)
        (placeholder as NSString).draw(at: origin, withAttributes: attrs)
    }

    override func becomeFirstResponder() -> Bool {
        needsDisplay = true
        return super.becomeFirstResponder()
    }

    override func didChangeText() {
        super.didChangeText()
        needsDisplay = true
    }
}
