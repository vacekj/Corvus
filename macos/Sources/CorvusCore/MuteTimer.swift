import Foundation

// Timed mutes (Signal Desktop: 1 hour, 8 hours, 1 day, 1 week, Always). Local only: signal-cli does not
// sync the mute state. A timed mute stores its end; the chat unmutes itself when it passes.

public enum MuteDuration: CaseIterable, Equatable, Sendable {
    case oneHour, eightHours, oneDay, oneWeek, always

    public var title: String {
        switch self {
        case .oneHour: "1 hour"
        case .eightHours: "8 hours"
        case .oneDay: "1 day"
        case .oneWeek: "1 week"
        case .always: "Always"
        }
    }

    /// Length in ms; nil for "Always".
    public var milliseconds: Int64? {
        switch self {
        case .oneHour: 3_600_000
        case .eightHours: 8 * 3_600_000
        case .oneDay: 86_400_000
        case .oneWeek: 7 * 86_400_000
        case .always: nil
        }
    }

    /// End of a mute started at `now`; 0 = until unmuted.
    public func until(now: Int64) -> Int64 { milliseconds.map { now + $0 } ?? 0 }
}

extension Conversation {
    /// Muted at `now`: switched on and a timed mute has not run out yet.
    public func isMuted(at now: Int64) -> Bool { muted && (muteUntilMs == 0 || muteUntilMs > now) }
}

extension ChatState {
    /// Mutes until `until` (0 = until unmuted) or unmutes (nil). Returns the record to persist, nil when
    /// nothing changed.
    public mutating func setMute(_ key: String, until: Int64?) -> JSON? {
        guard let c = convs[key] else { return nil }
        let muted = until != nil
        let end = max(0, until ?? 0)
        guard c.muted != muted || c.muteUntilMs != end else { return nil }
        convs[key]!.muted = muted
        convs[key]!.muteUntilMs = end
        return Records.mute(key, muted, until: end)
    }

    /// Chats whose timed mute has run out at `now` (read only: callers change only what changed).
    public func expiredMutes(now: Int64) -> [String] {
        convs.values.filter { $0.muted && $0.muteUntilMs > 0 && $0.muteUntilMs <= now }.map(\.key).sorted()
    }

    /// The earliest end of a timed mute still to come, if any.
    public func nextMuteExpiry() -> Int64? {
        convs.values.lazy.filter { $0.muted && $0.muteUntilMs > 0 }.map(\.muteUntilMs).min()
    }
}

public enum MuteText {
    /// Time left of a timed mute: "45 min", "7 h 59 min", "6 days 23 h". At least a minute.
    public static func remaining(untilMs: Int64, now: Int64) -> String {
        let minutes = max(1, Int((untilMs - now + 59_999) / 60_000))
        if minutes < 60 { return "\(minutes) min" }
        let hours = minutes / 60, restMin = minutes % 60
        if hours < 24 { return restMin == 0 ? "\(hours) h" : "\(hours) h \(restMin) min" }
        let days = hours / 24, restH = hours % 24
        let d = days == 1 ? "1 day" : "\(days) days"
        return restH == 0 ? d : "\(d) \(restH) h"
    }
}
