import CorvusCore
import SwiftUI

/// Whether somebody types in a chat, observed per chat list row: a typing indicator updates one row,
/// not the list (same pattern as `SidebarSelection`).
@MainActor @Observable
final class ChatListTyping {
    static let shared = ChatListTyping()

    @MainActor @Observable
    final class Mark {
        var on = false
    }

    @ObservationIgnored private var marks: [String: Mark] = [:]
    @ObservationIgnored private var typing: Set<String> = []

    func mark(_ key: String) -> Mark {
        if let m = marks[key] { return m }
        let m = Mark()
        m.on = typing.contains(key)
        marks[key] = m
        return m
    }

    /// The chats in which somebody types now (from `TypingIndicators`); only changed rows are written.
    func update(_ now: Set<String>) {
        guard now != typing else { return }
        for key in typing.subtracting(now) { marks[key]?.on = false }
        for key in now.subtracting(typing) { marks[key]?.on = true }
        typing = now
    }
}

/// The second line of a chat list row: the last message, or "typing" with moving dots.
struct ChatRowPreview: View {
    let key: String
    let preview: String
    let isDraft: Bool
    let fontSize: CGFloat

    var body: some View {
        if ChatListTyping.shared.mark(key).on {
            HStack(spacing: 3) {
                Text("typing")
                RowTypingDots()
            }
            .font(.system(size: fontSize))
            .foregroundStyle(Theme.signalBlue)
            .lineLimit(1)
            .accessibilityLabel("typing")
        } else {
            Text(preview)
                .font(.system(size: fontSize))
                .italic(isDraft)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }
}

private struct RowTypingDots: View {
    @State private var phase = false

    var body: some View {
        HStack(spacing: 2) {
            ForEach(0..<3) { i in
                Circle()
                    .frame(width: 3.5, height: 3.5)
                    .opacity(phase ? 1 : 0.25)
                    .animation(.easeInOut(duration: 0.5).repeatForever().delay(Double(i) * 0.18), value: phase)
            }
        }
        .padding(.top, 3)
        .onAppear { phase = true }
    }
}
