import AppKit
import CorvusCore
import SwiftUI

/// Who is typing in which chat (received) and what the composer told others (sent). Separate from `AppModel`:
/// typing changes often, and only the header subtitle and the bubble at the end of the list show it.
@MainActor @Observable
final class TypingIndicators {
    static let shared = TypingIndicators()

    private(set) var tracker = TypingTracker()
    @ObservationIgnored private var outbox = TypingOutbox()
    @ObservationIgnored private var timer: Timer?

    func typers(in key: String) -> [String] { tracker.typers(in: key) }

    fileprivate func apply(conversation key: String, typer: String, started: Bool) {
        var t = tracker
        // a repeated "started" only refreshes the timeout, but it has to be stored as well
        if t.apply(conversation: key, typer: typer, started: started, now: nowMs()) || started { tracker = t }
        ensureTimer()
    }

    fileprivate func clear(conversation key: String, typer: String) {
        var t = tracker
        if t.clear(conversation: key, typer: typer) { tracker = t }
    }

    fileprivate func outgoing(_ change: (inout TypingOutbox) -> [TypingOutbox.Action]) -> [TypingOutbox.Action] {
        let actions = change(&outbox)
        ensureTimer()
        return actions
    }

    /// One timer while anything is going on: expires received indicators and stops our own after a pause.
    private func ensureTimer() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
            MainActor.assumeIsolated { TypingIndicators.shared.tick() }
        }
    }

    private func tick() {
        let now = nowMs()
        var t = tracker
        if t.expire(now: now) { tracker = t }
        let stops = outbox.tick(now: now)
        if !stops.isEmpty { onActions?(stops) }
        if tracker.isEmpty && outbox.key == nil {
            timer?.invalidate()
            timer = nil
        }
    }

    @ObservationIgnored fileprivate var onActions: (([TypingOutbox.Action]) -> Void)?
}

extension AppModel {
    /// A `typingMessage` envelope. Indicators of blocked people and of unaccepted requests are not shown.
    func handleTyping(_ e: TypingEvent) {
        let sender = chats.resolveKey(e.sender)
        guard !sender.isEmpty, sender != account else { return }
        let key = e.groupId.isEmpty ? sender : GroupInfo.key(forId: e.groupId)
        guard chats.convs[key] != nil, !(e.started && isQuiet(key, author: sender)) else { return }
        TypingIndicators.shared.apply(conversation: key, typer: sender, started: e.started)
    }

    /// A message from someone ends their typing indicator.
    func typingEnded(_ key: String, typer: String) {
        TypingIndicators.shared.clear(conversation: key, typer: typer)
    }

    /// "typing …" for the chat header; nil when nobody types.
    func typingLabel(_ key: String) -> String? {
        let who = TypingIndicators.shared.typers(in: key)
        guard !who.isEmpty else { return nil }
        guard chats.convs[key]?.isGroup == true else { return "typing …" }
        let names = who.map { memberName($0) }
        if names.count == 1 { return "\(names[0]) is typing …" }
        if names.count == 2 { return "\(names[0]) and \(names[1]) are typing …" }
        return "\(names.count) people are typing …"
    }

    /// The composer text changed: tells the chat that we are typing (only when switched on in Settings →
    /// Privacy, and not to an unaccepted request, never to blocked people).
    func composerEdited() {
        guard let key = current else { return }
        let allowed = privacy.typingIndicators && connected && mayAcknowledge(key) && !isSendLocked(key) && editKey.isEmpty
        let empty = composerText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        sendTyping(TypingIndicators.shared.outgoing { $0.edited(conversation: key, empty: empty, allowed: allowed, now: nowMs()) })
    }

    /// The message was sent or the chat closed: "stopped" if "started" was sent.
    func composerTypingReset() {
        sendTyping(TypingIndicators.shared.outgoing { $0.reset() })
    }

    private func sendTyping(_ actions: [TypingOutbox.Action]) {
        TypingIndicators.shared.onActions = { [weak self] in self?.sendTyping($0) }
        for a in actions {
            let (key, stop): (String, Bool) = switch a {
            case .start(let k): (k, false)
            case .stop(let k): (k, true)
            }
            guard connected, let c = chats.convs[key] else { continue }
            var p: JSON = ["stop": stop]
            addRecipient(&p, c)
            Task { [p] in _ = try? await cli.call("sendTyping", p) }
        }
    }
}

/// "… is typing" bubble at the end of a message list.
struct TypingBubbleRow: View {
    @Environment(AppModel.self) private var model
    let key: String
    let isGroup: Bool

    var body: some View {
        let who = TypingIndicators.shared.typers(in: key)
        if !who.isEmpty {
            HStack(alignment: .bottom, spacing: 8) {
                if isGroup, let first = who.first {
                    AvatarView(image: model.avatars[first] ?? Media.placeholderAvatar(key: first, title: model.memberName(first)), size: 28)
                }
                TypingDots()
                    .padding(.horizontal, 14)
                    .padding(.vertical, 11)
                    .background(RoundedRectangle(cornerRadius: CGFloat(model.appearance.radius), style: .continuous)
                        .fill(model.appearance.inBgColor))
                Spacer(minLength: 0)
            }
            .padding(.top, 10)
            .accessibilityLabel(model.typingLabel(key) ?? "")
            .transition(.opacity)
        }
    }
}

private struct TypingDots: View {
    @State private var phase = false

    var body: some View {
        HStack(spacing: 4) {
            ForEach(0..<3) { i in
                Circle()
                    .fill(Color.secondary)
                    .frame(width: 7, height: 7)
                    .opacity(phase ? 1 : 0.3)
                    .animation(.easeInOut(duration: 0.5).repeatForever().delay(Double(i) * 0.18), value: phase)
            }
        }
        .onAppear { phase = true }
    }
}
