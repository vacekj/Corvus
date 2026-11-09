import Foundation

/// Runs the writes to the history store on one background serial queue, in the order they were made,
/// so the main thread never waits for encryption or a full rewrite. The store must not be used
/// elsewhere while writes are queued (`perform` and `drain` serialise with them).
public final class HistoryWriter: @unchecked Sendable {
    public let store: HistoryStore
    private let queue = DispatchQueue(label: "corvus.history-writer", qos: .userInitiated)

    public init(store: HistoryStore = HistoryStore()) { self.store = store }

    /// Appends one record; `done` runs on the main thread with the error, if any.
    public func append(_ record: JSON, done: (@MainActor (Error?) -> Void)? = nil) {
        let box = Box(record)
        enqueue(done) { try $0.append(box.value) }
    }

    /// Replaces the file with the records of `state` (a snapshot; the records are built on the queue too).
    public func rewrite(_ state: ChatState, done: (@MainActor (Error?) -> Void)? = nil) {
        let box = Box(state)
        enqueue(done) { try $0.rewrite(box.value.allRecords()) }
    }

    /// Runs `body` on the queue after every write queued before it.
    public func perform<T>(_ body: @escaping @Sendable (HistoryStore) throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { c in
            queue.async { [store] in c.resume(with: Result { try body(store) }) }
        }
    }

    /// Blocks until every queued write has finished (before closing the store).
    public func drain() { queue.sync {} }

    private func enqueue(_ done: (@MainActor (Error?) -> Void)?, _ write: @escaping (HistoryStore) throws -> Void) {
        let doneBox = Box(done)
        queue.async { [store] in
            var failure: Error?
            do { try write(store) } catch { failure = error }
            guard let done = doneBox.value else { return }
            let errorBox = Box(failure)
            DispatchQueue.main.async { MainActor.assumeIsolated { done(errorBox.value) } }
        }
    }
}

/// Moves a value that is only used by one side at a time across the queue boundary.
private final class Box<T>: @unchecked Sendable {
    let value: T
    init(_ value: T) { self.value = value }
}
