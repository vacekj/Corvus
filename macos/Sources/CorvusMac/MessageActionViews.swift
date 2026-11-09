import AppKit
import CorvusCore
import SwiftUI

// MARK: - Reactions

/// The reaction bar of a message: the quick reactions, the own reaction if it is another emoji, and "+"
/// for the full emoji picker. Clicking the own reaction takes it back; another emoji replaces it.
struct ReactionPicker: View {
    @Environment(AppModel.self) private var model
    let message: Message
    let close: () -> Void
    @State private var full = false

    var body: some View {
        if full {
            EmojiPicker { e in
                close()
                model.sendReaction(message.id, e)
            }
        } else {
            let mine = message.reactions[model.account]
            let quick = EmojiCatalog.quickReactions
            HStack(spacing: 4) {
                ForEach(quick + (mine.map { quick.contains($0) ? [] : [$0] } ?? []), id: \.self) { e in
                    Button {
                        close()
                        model.sendReaction(message.id, e)
                    } label: {
                        Text(e).font(.system(size: 22))
                            .frame(width: 34, height: 34)
                            .background(Circle().fill(e == mine ? Color.secondary.opacity(0.3) : .clear))
                    }
                    .buttonStyle(.borderless)
                    .help(e == mine ? "Remove reaction" : EmojiCatalog.names[e] ?? e)
                }
                Button { full = true } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 14, weight: .semibold))
                        .frame(width: 30, height: 30)
                        .background(Circle().fill(Theme.field))
                }
                .buttonStyle(.borderless)
                .help("More reactions")
            }
            .padding(8)
        }
    }
}

/// "React" submenu of the message menu.
struct ReactionMenuItems: View {
    @Environment(AppModel.self) private var model
    let message: Message

    var body: some View {
        let mine = message.reactions[model.account]
        ForEach(EmojiCatalog.quickReactions, id: \.self) { e in
            Button(mine == e ? "\(e)  (remove)" : e) { model.sendReaction(message.id, e) }
        }
        if let mine, !EmojiCatalog.quickReactions.contains(mine) {
            Divider()
            Button("\(mine)  (remove)") { model.sendReaction(message.id, mine) }
        }
    }
}

// MARK: - Failed sends

/// "Failed to send" with a red exclamation mark in the time row; a click offers Retry and Delete.
struct FailedSendBadge: View {
    @Environment(AppModel.self) private var model
    let message: Message

    var body: some View {
        Menu {
            Button { model.retrySend(message.id) } label: { Label("Retry", systemImage: "arrow.clockwise") }
                .disabled(!model.connected)
            Button(role: .destructive) { Task { await model.deleteMessage(message.id) } } label: {
                Label("Delete …", systemImage: "trash")
            }
        } label: {
            HStack(spacing: 3) {
                Text("Failed to send")
                Image(systemName: "exclamationmark.circle.fill")
            }
            .foregroundStyle(.red)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Retry or delete")
    }
}

// MARK: - Pinned messages

/// Pin / Unpin items of the message menu.
struct PinMenuItems: View {
    @Environment(AppModel.self) private var model
    let message: Message

    var body: some View {
        if message.pinnedAtMs > 0 && (message.pinExpiresMs <= 0 || message.pinExpiresMs > nowMs()) {
            Button {
                guard let key = model.current, let c = model.currentConversation else { return }
                model.unpinMessage(key, ts: message.ts, author: model.chats.effectiveAuthor(c, message))
            } label: { Label("Unpin message", systemImage: "pin.slash") }
            .disabled(!model.connected)
        } else {
            Menu {
                ForEach(AppModel.pinDurations, id: \.seconds) { d in
                    Button(d.label) { model.pinMessage(message.id, seconds: d.seconds) }
                }
            } label: { Label("Pin message", systemImage: "pin") }
            .disabled(!model.connected)
        }
    }
}

/// Bar at the top of a chat with its pinned messages: the newest pin is shown first; a click jumps to
/// the message and the next click shows the next pin (the marks on the left tell which one).
struct PinnedMessagesBar: View {
    @Environment(AppModel.self) private var model
    let conversation: Conversation
    @State private var index = 0

    var body: some View {
        let pins = model.chats.activePins(conversation.key, now: nowMs())
        if !pins.isEmpty {
            let i = min(index, pins.count - 1)
            let (pin, m) = pins[i]
            HStack(spacing: 10) {
                if pins.count > 1 {
                    VStack(spacing: 2) {
                        ForEach(pins.indices, id: \.self) { j in
                            Capsule().fill(j == i ? Theme.signalBlue : Color.secondary.opacity(0.35)).frame(width: 3)
                        }
                    }
                    .frame(height: 30)
                }
                Button {
                    model.scrollToMessage(id: m.id)
                    index = (i + 1) % pins.count
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "pin.fill").foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(m.outgoing ? "You" : model.displayName(pin.authorKey))
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(m.outgoing ? Color.primary : Theme.senderColor(pin.authorKey))
                            Text(Self.preview(m)).font(.callout).lineLimit(1).truncationMode(.tail).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(pins.count > 1 ? "Go to pinned message (\(i + 1) of \(pins.count))" : "Go to pinned message")
                Button { model.unpinMessage(conversation.key, ts: pin.ts, author: pin.authorKey) } label: {
                    Image(systemName: "pin.slash")
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .disabled(!model.connected)
                .help("Unpin message")
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
            .background(Theme.chrome)
            .overlay(alignment: .bottom) { Divider() }
            .onChange(of: conversation.key) { index = 0 }
        }
    }

    static func preview(_ m: Message) -> String {
        if m.isPoll { return "📊 " + m.poll.question }
        if m.viewOnce { return "View once media" }
        let t = m.text.prefix(200).replacingOccurrences(of: "\n", with: " ")
        if !t.isEmpty { return t }
        guard let a = m.attachments.first else { return "" }
        return a.isSticker ? "Sticker" : a.isGif ? "GIF" : a.isImage ? "📷 Photo" : a.isVideo ? "🎬 Video"
            : a.isAudio ? "🎤 Voice message" : "📎 " + a.filename
    }
}

// MARK: - Selecting several messages

/// Selection mode of the open chat ("Select" in the message menu). Kept outside the app model so only the
/// rows and the selection bar depend on it.
@MainActor @Observable
final class MessageSelection {
    static let shared = MessageSelection()

    private(set) var key: String?           // chat in selection mode
    private(set) var ids: Set<String> = []  // Message.id of the selected messages
    /// Messages handed to the forward sheet from the selection bar (oldest first).
    @ObservationIgnored var forwardIds: [String] = []

    func isActive(_ key: String) -> Bool { self.key == key }

    func begin(_ key: String, _ id: String) {
        self.key = key
        ids = [id]
    }

    func toggle(_ id: String) {
        if ids.contains(id) { ids.remove(id) } else { ids.insert(id) }
    }

    func end() {
        if key != nil { key = nil }
        if !ids.isEmpty { ids = [] }
        forwardIds = []
    }
}

/// A message row in selection mode: a checkbox on the left, and a click anywhere on the row toggles it.
struct SelectableRow: ViewModifier {
    let id: String
    @Environment(\.conversationKey) private var conversationKey

    func body(content: Content) -> some View {
        let selection = MessageSelection.shared
        let active = selection.isActive(conversationKey)
        let on = active && selection.ids.contains(id)
        content
            .padding(.leading, active ? 32 : 0)
            .overlay(alignment: .leading) {
                if active {
                    Image(systemName: on ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 18))
                        .foregroundStyle(on ? Theme.signalBlue : Color.secondary)
                        .accessibilityLabel(on ? "Selected" : "Not selected")
                }
            }
            .overlay {
                if active {
                    Color.clear
                        .contentShape(Rectangle())
                        .onTapGesture { selection.toggle(id) }
                }
            }
            .background {
                if on { RoundedRectangle(cornerRadius: 8).fill(Theme.signalBlue.opacity(0.08)).padding(.horizontal, -8) }
            }
    }
}

/// The composer, or, in selection mode, the bar with the number of selected messages and their actions.
struct ComposerOrSelectionBar<Composer: View>: View {
    let conversation: Conversation
    @ViewBuilder let composer: () -> Composer

    var body: some View {
        let selecting = MessageSelection.shared.isActive(conversation.key)
        composer()
            .disabled(selecting)
            .opacity(selecting ? 0 : 1)
            .accessibilityHidden(selecting)
            .overlay {
                if selecting { SelectionBar(conversation: conversation) }
            }
    }
}

private struct SelectionBar: View {
    @Environment(AppModel.self) private var model
    let conversation: Conversation

    var body: some View {
        let selection = MessageSelection.shared
        let msgs = model.messages(withIds: selection.ids)
        let pending = model.chats.pendingTimestamps(conversation.key)
        let busy = msgs.contains { pending.contains($0.ts) }
        HStack(spacing: 12) {
            Button { selection.end() } label: { Image(systemName: "xmark") }
                .buttonStyle(.borderless)
                .help("Cancel (Esc)")
            Text(msgs.count == 1 ? "1 selected" : "\(msgs.count) selected")
                .font(.body.weight(.medium))
                .monospacedDigit()
            Spacer()
            if MessageSelectionRules.canForward(msgs) {
                Button { forward(msgs) } label: { Label("Forward", systemImage: "arrowshape.turn.up.right") }
                    .disabled(!model.connected || busy)
            }
            if MessageSelectionRules.canDeleteForEveryone(msgs, now: nowMs()) {
                Button(role: .destructive) { delete(forEveryone: true) } label: {
                    Label("Delete for everyone", systemImage: "trash")
                }
                .disabled(!model.connected || busy)
            }
            Button(role: .destructive) { delete(forEveryone: false) } label: { Label("Delete for me", systemImage: "trash") }
                .disabled(msgs.isEmpty || busy)
        }
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .frame(minHeight: 52)
        .background(Theme.chrome)
        .overlay(alignment: .top) { Divider() }
        .onDisappear { selection.end() } // another chat was opened
        .onLocalKeyDown { e in
            guard e.keyCode == KeyCode.escape, e.window === MainWindowTracker.shared.window,
                  !KeyboardNavigation.shared.quickSwitcherShown else { return false }
            selection.end()
            return true
        }
    }

    private func forward(_ msgs: [Message]) {
        let ids = msgs.map(\.id)
        MessageSelection.shared.forwardIds = ids
        model.forwardMessageId = ids.first
    }

    private func delete(forEveryone: Bool) {
        let ids = MessageSelection.shared.ids
        Task {
            if await model.deleteSelected(ids, forEveryone: forEveryone) { MessageSelection.shared.end() }
        }
    }
}
