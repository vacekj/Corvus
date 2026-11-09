import AppKit
import CorvusCore
import SwiftUI

/// The text of a message with Signal styles (bold, italic, strikethrough, monospace, spoiler) and @mentions.
struct FormattedMessageText: View {
    @Environment(AppModel.self) private var model
    let message: Message
    let foreground: Color
    /// Base text with the usual link detection and font.
    let linkify: (String) -> AttributedString
    @State private var revealed: Set<Int> = []

    private static let spoilerScheme = "corvus-spoiler:"
    private static let size = NSFont.systemFontSize + 1

    @Environment(\.messageHovered) private var hovered
    @Environment(\.searchHighlightQuery) private var highlightQuery
    @Environment(\.conversationKey) private var conversationKey
    /// Stays on once the pointer was over the message, so a selection survives moving the pointer away.
    @State private var selectable = false
    /// Long texts: how many characters are shown ("Read more" adds more).
    @State private var shownLength = LongText.initialLength

    var body: some View {
        let b = expandedBody
        let full = attributed(b)
        let cut = LongText.cut(b.text, limit: shownLimit(b.text))
        if cut != nil || message.longTextAttachmentIndex != nil {
            VStack(alignment: .leading, spacing: 4) {
                text(cut.map { Self.shortened(full, b.text, at: $0) } ?? full)
                Button("Read more") { readMore(shown: cut.map { b.text.distance(from: b.text.startIndex, to: $0) } ?? b.text.count) }
                    .buttonStyle(.plain)
                    .font(.system(size: Self.size, weight: .semibold))
                    .foregroundStyle(foreground)
            }
        } else {
            text(full)
        }
    }

    private func text(_ s: AttributedString) -> some View {
        Group {
            if selectable || hovered {
                styled(Text(s)).textSelection(.enabled)
            } else {
                styled(Text(s))
            }
        }
        .onChange(of: hovered) { _, h in if h { selectable = true } }
    }

    /// The shown part of a long text, ending with "…".
    private static func shortened(_ s: AttributedString, _ text: String, at cut: String.Index) -> AttributedString {
        let n = text.distance(from: text.startIndex, to: cut)
        var out = AttributedString(s[s.startIndex..<s.characters.index(s.startIndex, offsetBy: n)])
        out.append(AttributedString("…"))
        return out
    }

    /// Characters shown of a long text: enough to include the last search hit.
    private func shownLimit(_ text: String) -> Int {
        guard let q = highlightQuery, text.utf16.count > LongText.threshold,
              let last = SearchHighlight.ranges(of: q, in: text).last else { return shownLength }
        return max(shownLength, text.distance(from: text.startIndex, to: last.upperBound) + 100)
    }

    private func readMore(shown: Int) {
        shownLength = max(shownLength, shown) + LongText.increment
        // The full text of a long message is still in its attachment (older history): load it first.
        if message.longTextAttachmentIndex != nil, let c = model.chats.convs[conversationKey] {
            model.loadLongText(c.key, ts: message.ts, author: model.chats.effectiveAuthor(c, message), userInitiated: true)
        }
    }

    private func styled(_ t: Text) -> some View {
        t
            .foregroundStyle(foreground)
            .tint(message.outgoing ? foreground : Theme.signalBlue)
            .fixedSize(horizontal: false, vertical: true)
            .environment(\.openURL, OpenURLAction { url in
                let s = url.absoluteString
                guard s.hasPrefix(Self.spoilerScheme), let i = Int(s.dropFirst(Self.spoilerScheme.count)) else {
                    // A group invite link asks whether to join instead of opening the browser.
                    if let link = GroupInviteLink.parse(s) {
                        model.askToJoinGroup(link)
                        return .handled
                    }
                    return .systemAction
                }
                revealed.insert(i)
                return .handled
            })
    }

    /// Mentions that still hold Signal's placeholder (history written by the Qt app) become "@Name".
    private var expandedBody: FormattedBody {
        let m = message
        guard m.mentions.contains(where: { r in
            let u = Array(m.text.utf16)
            return r.start >= 0 && r.start < u.count && u[r.start] == mentionPlaceholder
        }) else { return FormattedBody(text: m.text, styles: m.textStyles, mentions: m.mentions) }
        return expandMentions(text: m.text, styles: m.textStyles, mentions: m.mentions) { i in
            let uuid = m.mentions[i].uuid
            let name = uuid.isEmpty ? "" : model.displayName(model.chats.resolveKey(uuid))
            if name.isEmpty || name == uuid {
                return uuid.isEmpty || uuid.filter({ $0 == "-" }).count >= 4 ? "mentioned member" : uuid
            }
            return name
        }
    }

    private func attributed(_ body: FormattedBody) -> AttributedString {
        var s = styledText(body)
        if let q = highlightQuery { highlight(&s, text: body.text, query: q) }
        return s
    }

    /// Search hits inside the text (Signal Desktop marks them like a highlighter).
    private func highlight(_ s: inout AttributedString, text: String, query: String) {
        for r in SearchHighlight.ranges(of: query, in: text) {
            guard let ar = Range(r, in: s) else { continue }
            s[ar].backgroundColor = Color(red: 1, green: 0.85, blue: 0.2)
            s[ar].foregroundColor = .black
        }
    }

    private func styledText(_ body: FormattedBody) -> AttributedString {
        var s = linkify(body.text)
        if body.styles.isEmpty && body.mentions.isEmpty { return s }
        let text = body.text
        for run in styledRuns(text: text, styles: body.styles, mentions: body.mentions) {
            guard run.styles.isEmpty == false || run.mention != nil,
                  let r = Range(NSRange(location: run.location, length: run.length), in: text),
                  let ar = Range(r, in: s) else { continue }
            var weight: Font.Weight = run.styles.contains(.bold) ? .bold : .regular
            if run.mention != nil && weight == .regular { weight = .semibold }
            var font = Font.system(size: DisplaySettings.shared.size(Self.size), weight: weight, design: run.styles.contains(.monospace) ? .monospaced : .default)
            if run.styles.contains(.italic) { font = font.italic() }
            s[ar].font = font
            if run.styles.contains(.strikethrough) { s[ar].strikethroughStyle = .single }
            if run.styles.contains(.monospace) { s[ar].backgroundColor = foreground.opacity(0.1) }
            if run.mention != nil { s[ar].backgroundColor = foreground.opacity(0.18) }
            if let id = run.spoiler {
                if revealed.contains(id) {
                    s[ar].backgroundColor = foreground.opacity(0.12)
                } else {
                    s[ar].foregroundColor = .clear
                    s[ar].backgroundColor = foreground.opacity(0.4)
                    s[ar].underlineStyle = nil
                    s[ar].link = URL(string: Self.spoilerScheme + String(id))
                }
            }
        }
        return s
    }
}
