import AppKit
import CorvusCore
import SwiftUI

/// Timed mutes: one timer for the next end of a mute (and a look after the Mac wakes up, when timers
/// are late).
@MainActor
final class MuteExpiry {
    static let shared = MuteExpiry()

    private var timer: Timer?
    private var wakeObserver: NSObjectProtocol?

    func schedule(_ model: AppModel) {
        timer?.invalidate()
        timer = nil
        if wakeObserver == nil {
            wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
            ) { [weak model] _ in
                MainActor.assumeIsolated { model?.refreshMuteExpiry() }
            }
        }
        guard let next = model.chats.nextMuteExpiry() else { return }
        let t = Timer(fire: Date(timeIntervalSince1970: Double(next) / 1000 + 0.05), interval: 0, repeats: false) { [weak model] _ in
            MainActor.assumeIsolated { model?.refreshMuteExpiry() }
        }
        t.tolerance = 1
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }
}

extension AppModel {
    /// Mutes for a while or for good (`.always`); nil unmutes.
    func setMute(_ key: String, _ duration: MuteDuration?) {
        guard let c = chats.convs[key] else { return }
        let until = duration?.until(now: nowMs())
        // Only real changes: any write to `chats` makes every view showing chats update.
        guard c.muted != (until != nil) || c.muteUntilMs != (until ?? 0) else { return }
        if let rec = chats.setMute(key, until: until) { persist(rec) }
        MuteExpiry.shared.schedule(self)
    }

    /// Unmutes chats whose timed mute ran out and sets the timer for the next one.
    func refreshMuteExpiry() {
        for key in chats.expiredMutes(now: nowMs()) {
            if let rec = chats.setMute(key, until: nil) { persist(rec) }
        }
        MuteExpiry.shared.schedule(self)
    }
}

/// "Mute notifications" submenu of a chat: the Signal Desktop durations, or "Unmute".
struct MuteMenu: View {
    @Environment(AppModel.self) private var model
    let conversation: Conversation

    var body: some View {
        let c = conversation
        if c.isMuted(at: nowMs()) {
            Menu {
                Button("Unmute") { model.setMute(c.key, nil) }
                Divider()
                durations(c)
            } label: { Label("Muted", systemImage: "bell.slash") }
        } else {
            Menu {
                durations(c)
            } label: { Label("Mute notifications", systemImage: "bell.slash") }
        }
    }

    @ViewBuilder
    private func durations(_ c: Conversation) -> some View {
        ForEach(MuteDuration.allCases, id: \.self) { d in
            Button(d.title) { model.setMute(c.key, d) }
        }
    }
}

/// Mute state of the open chat in the info panel, with the time left of a timed mute.
struct MuteInfoRow: View {
    @Environment(AppModel.self) private var model
    let conversation: Conversation

    var body: some View {
        let c = conversation
        HStack {
            Label("Notifications", systemImage: c.muted ? "bell.slash" : "bell")
            Spacer()
            Menu {
                if c.muted {
                    Button("Unmute") { model.setMute(c.key, nil) }
                    Divider()
                }
                ForEach(MuteDuration.allCases, id: \.self) { d in
                    Button("Mute for \(d.title.lowercased())") { model.setMute(c.key, d) }
                }
            } label: {
                Text(c.muted ? "Muted" : "On")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
        if c.muted && c.muteUntilMs > 0 {
            // Updates once a minute while it is shown.
            TimelineView(.periodic(from: .now, by: 30)) { context in
                let now = Int64(context.date.timeIntervalSince1970 * 1000)
                let until = Date(timeIntervalSince1970: Double(c.muteUntilMs) / 1000)
                Text("Muted until \(until.formatted(Self.untilStyle(until))) · \(MuteText.remaining(untilMs: c.muteUntilMs, now: now)) left")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private static func untilStyle(_ d: Date) -> Date.FormatStyle {
        Calendar.current.isDateInToday(d) ? .dateTime.hour().minute() : .dateTime.weekday(.abbreviated).day().month(.abbreviated).hour().minute()
    }
}
