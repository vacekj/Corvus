import Foundation

/// Runs the writes to the history database on one background serial queue, so the main thread never
/// waits for the disk. A write is "make the file hold this state" (`HistoryDB.sync`): states handed
/// over while an earlier one is still waiting replace it, and their callbacks run when the newest is
/// written. The database must not be used elsewhere while writes are queued (`perform` and `drain`
/// serialise with them).
public final class HistoryWriter: @unchecked Sendable {
    public let db: HistoryDB
    private let queue = DispatchQueue(label: "corvus.history-writer", qos: .userInitiated)
    private let lock = NSLock()
    private var waiting: Waiting?

    private struct Waiting {
        var state: ChatState
        var force: Bool
        var done: [@MainActor (Error?) -> Void]
    }

    public init(db: HistoryDB = HistoryDB()) { self.db = db }

    /// Writes what differs between `state` and the file; `done` runs on the main thread with the error, if any.
    /// `force` allows it to remove chats and many messages (see `HistoryDB.sync`).
    public func sync(_ state: ChatState, force: Bool = false, done: (@MainActor (Error?) -> Void)? = nil) {
        lock.lock()
        if waiting != nil {
            waiting!.state = state
            waiting!.force = waiting!.force || force
            if let done { waiting!.done.append(done) }
            lock.unlock()
            return
        }
        waiting = Waiting(state: state, force: force, done: done.map { [$0] } ?? [])
        lock.unlock()
        queue.async { [self] in
            lock.lock()
            let job = waiting
            waiting = nil
            lock.unlock()
            guard let job else { return }
            var failure: Error?
            do { try db.sync(job.state, force: job.force) } catch { failure = error }
            guard !job.done.isEmpty else { return }
            let box = Box((job.done, failure))
            DispatchQueue.main.async { MainActor.assumeIsolated { box.value.0.forEach { $0(box.value.1) } } }
        }
    }

    /// Runs `body` on the queue after every write queued before it.
    public func perform<T>(_ body: @escaping @Sendable (HistoryDB) throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { c in
            queue.async { [db] in c.resume(with: Result { try body(db) }) }
        }
    }

    /// Blocks until every queued write has finished (before closing the database).
    public func drain() { queue.sync {} }
}

/// Moves a value that is only used by one side at a time across the queue boundary.
private final class Box<T>: @unchecked Sendable {
    let value: T
    init(_ value: T) { self.value = value }
}
