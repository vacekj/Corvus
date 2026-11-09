import Foundation

/// Wording and countdown of disappearing messages.
public enum DisappearingTimer {
    /// "30 seconds", "1 minute", "6 hours", "1 day", "1 week", "4 weeks" …
    public static func label(_ seconds: Int) -> String {
        guard seconds > 0 else { return "off" }
        let units: [(Int, String)] = [(7 * 86_400, "week"), (86_400, "day"), (3_600, "hour"), (60, "minute")]
        for (size, name) in units where seconds % size == 0 {
            let n = seconds / size
            return "\(n) \(name)\(n == 1 ? "" : "s")"
        }
        return "\(seconds) second\(seconds == 1 ? "" : "s")"
    }

    /// The chat note for a timer change. `actor` nil means the user (on this or another of their devices).
    public static func noticeText(_ seconds: Int, actor: String?) -> String {
        let who = actor ?? "You"
        if seconds <= 0 { return "\(who) disabled disappearing messages." }
        return "\(who) set the disappearing message timer to \(label(seconds))."
    }

    /// Steps of the countdown icon (like Signal Desktop's 13 timer images): `steps` = untouched, 0 = gone.
    public static let steps = 12

    /// The countdown step of a message. A timer that has not started yet (unread incoming message) is full.
    public static func step(expiresInSeconds: Int, startMs: Int64, now: Int64) -> Int {
        guard expiresInSeconds > 0, startMs > 0 else { return steps }
        let total = Double(expiresInSeconds) * 1000
        let left = max(0, total - Double(now - startMs))
        return min(steps, Int((left / total * Double(steps)).rounded(.up)))
    }

    /// How often the shared countdown clock needs to tick for the shortest timer on screen: about twice per
    /// step, never more than once a second and at least once a minute.
    public static func tickInterval(shortestSeconds: Int) -> TimeInterval {
        guard shortestSeconds > 0 else { return 60 }
        return min(60, max(1, Double(shortestSeconds) / Double(steps) / 2))
    }
}
