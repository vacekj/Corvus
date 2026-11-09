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
    /// Stays on once the pointer was over the message, so a selection survives moving the pointer away.
    @State private var selectable = false

    var body: some View {
        Group {
            if selectable || hovered {
                styled(Text(attributed)).textSelection(.enabled)
            } else {
                styled(Text(attributed))
            }
        }
        .onChange(of: hovered) { _, h in if h { selectable = true } }
    }

    private func styled(_ t: Text) -> some View {
        t
            .foregroundStyle(foreground)
            .tint(message.outgoing ? foreground : Theme.signalBlue)
            .fixedSize(horizontal: false, vertical: true)
            .environment(\.openURL, OpenURLAction { url in
                let s = url.absoluteString
                guard s.hasPrefix(Self.spoilerScheme), let i = Int(s.dropFirst(Self.spoilerScheme.count)) else {
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

    private var attributed: AttributedString {
        let body = expandedBody
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
