import AppKit
import CorvusCore
import SwiftUI

/// ":shortcode" suggestions of the composer, like Signal Desktop: typing ":smi" lists matching emoji,
/// ↑/↓ move, Return or Tab insert, Esc hides the list. A complete ":code:" is replaced as soon as the closing
/// colon is typed. Emoji with skin tones use the default tone (Settings → General).
@MainActor @Observable
final class EmojiAutocomplete {
    static let shared = EmojiAutocomplete()

    private(set) var suggestions: [EmojiShortcodeIndex.Match] = []
    private(set) var index = 0
    @ObservationIgnored private(set) var range: NSRange?
    @ObservationIgnored private var dismissedAt: Int?      // Esc: stays hidden for this ":"
    @ObservationIgnored var insert: ((EmojiShortcodeIndex.Match) -> Void)?

    var active: Bool { !suggestions.isEmpty }
    var selected: EmojiShortcodeIndex.Match? { suggestions.indices.contains(index) ? suggestions[index] : nil }

    func show(range r: NSRange, _ list: [EmojiShortcodeIndex.Match]) {
        range = r
        if dismissedAt == r.location { return }
        dismissedAt = nil
        if list != suggestions {
            suggestions = list
            if index != 0 { index = 0 }
        }
    }

    func hide() {
        range = nil
        dismissedAt = nil
        if !suggestions.isEmpty { suggestions = [] }
        if index != 0 { index = 0 }
    }

    func dismiss() {
        let at = range?.location
        hide()
        dismissedAt = at
    }

    func move(_ step: Int) {
        guard !suggestions.isEmpty else { return }
        index = (index + step + suggestions.count) % suggestions.count
    }
}

/// The emoji list above the composer while a ":code" is typed.
struct EmojiSuggestionList: View {
    private let ac = EmojiAutocomplete.shared

    var body: some View {
        if ac.active {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(ac.suggestions.enumerated()), id: \.element) { i, m in
                    HStack(spacing: 8) {
                        Text(EmojiCatalog.toned(m.emoji)).font(.system(size: 18)).frame(width: 24)
                        Text(":\(m.code):").lineLimit(1).truncationMode(.middle)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(RoundedRectangle(cornerRadius: 6).fill(i == ac.index ? Theme.signalBlue.opacity(0.22) : .clear))
                    .contentShape(Rectangle())
                    .onTapGesture { ac.insert?(m) }
                }
            }
            .padding(4)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.field))
            .accessibilityLabel("Emoji suggestions")
        }
    }
}

extension MessageInput.Coordinator {
    static let emojiSuggestionLimit = 7

    /// Updates the suggestions for the ":code" before the caret. After an edit, a just completed ":code:" is
    /// replaced by its emoji.
    func updateEmojiShortcodes(afterEdit: Bool) {
        let ac = EmojiAutocomplete.shared
        guard let tv = textView, tv.selectedRange().length == 0 else { ac.hide(); return }
        let text = tv.string, caret = tv.selectedRange().location
        if afterEdit, let done = emojiShortcodeCompleted(text: text, caret: caret),
           let emoji = EmojiCatalog.shortcodes.emoji(forCode: done.code) {
            ac.hide()
            tv.insertText(EmojiCatalog.toned(emoji), replacementRange: done.range)
            return
        }
        guard let q = emojiShortcodeQuery(text: text, caret: caret) else { ac.hide(); return }
        ac.show(range: q.range, EmojiCatalog.shortcodes.search(q.query, limit: Self.emojiSuggestionLimit))
    }

    func insertEmojiShortcode(_ m: EmojiShortcodeIndex.Match) {
        let ac = EmojiAutocomplete.shared
        guard let tv = textView, let r = ac.range, r.location + r.length <= (tv.string as NSString).length else { return }
        let emoji = EmojiCatalog.toned(m.emoji)
        ac.hide()
        tv.insertText(emoji, replacementRange: r)
        EmojiCatalog.remember(emoji)
        tv.window?.makeFirstResponder(tv)
    }

    /// Keys while the list is shown; true when handled.
    func handleEmojiCommand(_ selector: Selector) -> Bool {
        let ac = EmojiAutocomplete.shared
        guard ac.active else { return false }
        switch selector {
        case #selector(NSResponder.moveUp(_:)): ac.move(-1)
        case #selector(NSResponder.moveDown(_:)): ac.move(1)
        case #selector(NSResponder.insertNewline(_:)), #selector(NSResponder.insertTab(_:)):
            if let m = ac.selected { insertEmojiShortcode(m) }
        case #selector(NSResponder.cancelOperation(_:)): ac.dismiss()
        default: return false
        }
        return true
    }
}
