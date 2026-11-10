import Foundation

/// One voice call as the app saw it. signal-cli's `listCalls` only lists the calls that are going on right
/// now, so the history is built from the call events (and kept locally, encrypted like the roster cache).
public struct CallRecord: Codable, Equatable, Identifiable, Sendable {
    public enum Outcome: String, Sendable {
        case ongoing, answered, missed, declined, unanswered, answeredElsewhere, failed
    }

    public var callId: Int64
    public var peerKey: String
    public var outgoing: Bool
    public var startedMs: Int64
    public var connectedMs: Int64?
    public var endedMs: Int64?
    public var endReason: String

    public var id: String { "\(callId):\(startedMs)" }

    public init(callId: Int64, peerKey: String, outgoing: Bool, startedMs: Int64, connectedMs: Int64? = nil,
                endedMs: Int64? = nil, endReason: String = "") {
        self.callId = callId
        self.peerKey = peerKey
        self.outgoing = outgoing
        self.startedMs = startedMs
        self.connectedMs = connectedMs
        self.endedMs = endedMs
        self.endReason = endReason
    }

    /// End reasons: signal-cli's call events ("remote_hangup", "ring_timeout", "acceptedonanotherdevice", …)
    /// and Corvus's own ("declined", "hangup", "Signal backend disconnected").
    public var outcome: Outcome {
        if endedMs == nil { return .ongoing }
        if connectedMs != nil { return .answered }
        let r = endReason.lowercased()
        if r.hasPrefix("tunnel_") { return .failed }
        if outgoing { return .unanswered }
        switch r {
        case "declined", "rejected", "declinedonanotherdevice": return .declined
        case "acceptedonanotherdevice": return .answeredElsewhere
        default: return .missed
        }
    }

    public var isMissed: Bool { outcome == .missed }

    /// Seconds between connecting and hanging up (0 for a call that never connected).
    public var durationSeconds: Int {
        guard let c = connectedMs, let e = endedMs, e > c else { return 0 }
        return Int((e - c) / 1000)
    }

    /// The line in the call list, worded like Signal Desktop.
    public var title: String {
        switch outcome {
        case .ongoing: return outgoing ? "Outgoing voice call" : "Incoming voice call"
        case .answered: return outgoing ? "Outgoing voice call" : "Incoming voice call"
        case .missed: return "Missed voice call"
        case .declined: return "Declined voice call"
        case .unanswered: return "Unanswered voice call"
        case .answeredElsewhere: return "Answered on another device"
        case .failed: return "Voice call failed"
        }
    }

    /// "3:05", "1:02:09"
    public static func durationText(_ seconds: Int) -> String {
        let h = seconds / 3600, m = seconds / 60 % 60, s = seconds % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }
}

/// The call list, newest first.
public struct CallLog: Codable, Equatable, Sendable {
    public private(set) var records: [CallRecord] = []
    public static let limit = 500

    public init(records: [CallRecord] = []) {
        self.records = Array(records.sorted { $0.startedMs > $1.startedMs }.prefix(Self.limit))
    }

    private func index(_ callId: Int64) -> Int? {
        // The newest record with that id: signal-cli call ids are random, a repeat is a different call.
        records.firstIndex { $0.callId == callId }
    }

    /// A call started or rang. Repeated events for a call that is still going on change nothing.
    @discardableResult
    public mutating func begin(callId: Int64, peerKey: String, outgoing: Bool, at ms: Int64) -> Bool {
        if let i = index(callId), records[i].endedMs == nil { return false }
        records.insert(CallRecord(callId: callId, peerKey: peerKey, outgoing: outgoing, startedMs: ms), at: 0)
        if records.count > Self.limit { records.removeLast(records.count - Self.limit) }
        return true
    }

    @discardableResult
    public mutating func connected(callId: Int64, at ms: Int64) -> Bool {
        guard let i = index(callId), records[i].endedMs == nil, records[i].connectedMs == nil else { return false }
        records[i].connectedMs = ms
        return true
    }

    /// Ends the call; the first end wins (the local hang-up and signal-cli's "ENDED" event both arrive).
    @discardableResult
    public mutating func ended(callId: Int64, reason: String, at ms: Int64) -> CallRecord? {
        guard let i = index(callId), records[i].endedMs == nil else { return nil }
        records[i].endedMs = max(ms, records[i].startedMs)
        records[i].endReason = reason
        return records[i]
    }

    /// Calls left open by a crash or a lost connection are closed when the log is loaded.
    public mutating func closeDangling(at ms: Int64) {
        for i in records.indices where records[i].endedMs == nil {
            records[i].endedMs = max(ms, records[i].startedMs)
            records[i].endReason = "interrupted"
        }
    }

    public mutating func remove(id: String) { records.removeAll { $0.id == id } }

    public mutating func removeAll() { records.removeAll() }

    public func filtered(missedOnly: Bool) -> [CallRecord] {
        missedOnly ? records.filter(\.isMissed) : records
    }
}
