import Foundation

/// "Mute notifications" from the menu bar: no banner and no sound for new messages until a time
/// (or until the user turns them back on). Per-chat mutes are separate (Conversation.muted).
public struct NotificationMute: Equatable, Sendable {
    /// nil: not muted. `Date.distantFuture`: until turned back on.
    public var until: Date?

    public init(until: Date? = nil) { self.until = until }

    public static let choices: [(title: String, seconds: TimeInterval?)] = [
        ("For 1 hour", 3600), ("For 8 hours", 8 * 3600), ("For 1 day", 86400), ("For 1 week", 7 * 86400),
        ("Until I turn them back on", nil),
    ]

    public static func muted(for seconds: TimeInterval?, now: Date) -> NotificationMute {
        NotificationMute(until: seconds.map { now.addingTimeInterval($0) } ?? .distantFuture)
    }

    public func isMuted(at now: Date) -> Bool {
        guard let until else { return false }
        return until > now
    }

    /// "Muted until 15:30", "Muted until Tue 15:30", "Muted"; nil when not muted.
    public func label(now: Date, calendar: Calendar = .current, locale: Locale = .current) -> String? {
        guard let until, isMuted(at: now) else { return nil }
        if until == .distantFuture { return "Notifications muted" }
        let f = DateFormatter()
        f.locale = locale
        f.calendar = calendar
        f.setLocalizedDateFormatFromTemplate(calendar.isDate(until, inSameDayAs: now) ? "jmm" : "EEEjmm")
        return "Muted until " + f.string(from: until)
    }

    // Persistence (UserDefaults stores the end as seconds since 1970; a missing value means not muted).
    public static let defaultsKey = "notifications.mutedUntil"

    public static func load(_ d: UserDefaults = .standard) -> NotificationMute {
        guard let t = d.object(forKey: defaultsKey) as? Double else { return NotificationMute() }
        return NotificationMute(until: t >= Date.distantFuture.timeIntervalSince1970 ? .distantFuture : Date(timeIntervalSince1970: t))
    }

    public func save(_ d: UserDefaults = .standard) {
        if let until { d.set(until.timeIntervalSince1970, forKey: Self.defaultsKey) } else { d.removeObject(forKey: Self.defaultsKey) }
    }
}
