import Foundation

// Typing indicators: received from signal-cli as `typingMessage` envelopes, sent with `sendTyping`.

/// signal-cli: {"sourceNumber": ..., "typingMessage": {"action": "STARTED" | "STOPPED", "timestamp", "groupId"?}}.
public struct TypingEvent: Equatable {
    public var sender = ""
    public var groupId = ""
    public var started = false
    public var timestamp: Int64 = 0

    public init(sender: String = "", groupId: String = "", started: Bool = false, timestamp: Int64 = 0) {
        self.sender = sender
        self.groupId = groupId
        self.started = started
        self.timestamp = timestamp
    }
}

public func parseTyping(_ env: JSON) -> TypingEvent? {
    let t = jsonObject(env["typingMessage"])
    if t.isEmpty { return nil }
    var e = TypingEvent()
    e.sender = jsonString(env["sourceNumber"])
    if e.sender.isEmpty { e.sender = jsonString(env["sourceUuid"]) }
    if e.sender.isEmpty { e.sender = jsonString(env["source"]) }
    e.groupId = jsonString(t["groupId"])
    e.started = jsonString(t["action"]).uppercased() == "STARTED"
    e.timestamp = jsonInt64(t["timestamp"])
    if e.timestamp <= 0 { e.timestamp = jsonInt64(env["timestamp"]) }
    return e.sender.isEmpty ? nil : e
}

/// Who is typing where. A "started" without a later "stopped" ends after `timeoutMs` (Signal: 15 s).
public struct TypingTracker: Equatable {
    public static let timeoutMs: Int64 = 15_000
    private var since: [String: [String: Int64]] = [:]   // conversation -> typer -> when the indicator was last refreshed

    public init() {}

    /// Returns true when the state changed.
    @discardableResult
    public mutating func apply(conversation key: String, typer: String, started: Bool, now: Int64) -> Bool {
        if started {
            let changed = since[key]?[typer] == nil
            since[key, default: [:]][typer] = now
            return changed
        }
        return clear(conversation: key, typer: typer)
    }

    /// A message from the typer ends their indicator.
    @discardableResult
    public mutating func clear(conversation key: String, typer: String) -> Bool {
        guard since[key]?[typer] != nil else { return false }
        since[key]![typer] = nil
        if since[key]!.isEmpty { since[key] = nil }
        return true
    }

    /// Drops indicators older than the timeout; returns true when something was dropped.
    @discardableResult
    public mutating func expire(now: Int64) -> Bool {
        var changed = false
        for (key, typers) in since {
            for (t, at) in typers where now - at >= Self.timeoutMs {
                since[key]![t] = nil
                changed = true
            }
            if since[key]!.isEmpty { since[key] = nil }
        }
        return changed
    }

    /// Typers of a conversation in a stable order.
    public func typers(in key: String) -> [String] { (since[key] ?? [:]).keys.sorted() }

    public var isEmpty: Bool { since.isEmpty }
}

/// When the composer sends "typing started" / "typing stopped", like the official clients: started on the
/// first keystroke and again every 10 s while typing goes on; stopped after 5 s without a keystroke, when the
/// field is emptied (sent) or when another chat is opened.
public struct TypingOutbox: Equatable {
    public static let refreshMs: Int64 = 10_000
    public static let idleMs: Int64 = 5_000

    public enum Action: Equatable {
        case start(String)
        case stop(String)
    }

    public private(set) var key: String?       // conversation we told that we are typing
    private var startedAt: Int64 = 0
    private var lastEditAt: Int64 = 0

    public init() {}

    /// The composer text of `conversation` changed. `allowed`: typing indicators may be sent to this chat.
    public mutating func edited(conversation c: String, empty: Bool, allowed: Bool, now: Int64) -> [Action] {
        var out: [Action] = []
        if let k = key, k != c || empty || !allowed {
            out.append(.stop(k))
            key = nil
        }
        guard !empty, allowed else { return out }
        lastEditAt = now
        if key == nil || now - startedAt >= Self.refreshMs {
            out.append(.start(c))
            key = c
            startedAt = now
        }
        return out
    }

    /// Called periodically and when the message was sent.
    public mutating func tick(now: Int64) -> [Action] {
        guard let k = key, now - lastEditAt >= Self.idleMs else { return [] }
        key = nil
        return [.stop(k)]
    }

    /// The message was sent (receivers end the indicator themselves) or the chat was closed.
    public mutating func reset() -> [Action] {
        guard let k = key else { return [] }
        key = nil
        return [.stop(k)]
    }
}
