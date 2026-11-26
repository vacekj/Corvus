import AppKit
import CorvusCore

/// While the user scrolls (any scroll view, momentum included), incoming messages wait, at most
/// `maxHold`, and are applied together when the scroll ends. Each message updates the chat list and
/// redraws the window: one after the other they cost frames at 120 Hz, together they cost one update.
@MainActor
final class ScrollHold {
    static let shared = ScrollHold()
    static let maxHold: TimeInterval = 1.5

    private(set) var scrolling = false
    private var held: [JSON] = []
    private var flushTimer: Timer?
    private var observers: [NSObjectProtocol] = []
    /// Applies held envelopes (`AppModel.onEnvelope` for each, in order).
    var apply: (([JSON]) -> Void)?

    func start() {
        guard observers.isEmpty else { return }
        let nc = NotificationCenter.default
        observers.append(nc.addObserver(forName: NSScrollView.willStartLiveScrollNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { ScrollHold.shared.began() }
        })
        observers.append(nc.addObserver(forName: NSScrollView.didEndLiveScrollNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { ScrollHold.shared.ended() }
        })
    }

    func began() { scrolling = true }

    func ended() {
        scrolling = false
        flush()
    }

    func hold(_ env: JSON) {
        held.append(env)
        guard flushTimer == nil else { return }
        flushTimer = Timer.scheduledTimer(withTimeInterval: Self.maxHold, repeats: false) { _ in
            MainActor.assumeIsolated { ScrollHold.shared.flush() }
        }
    }

    func flush() {
        flushTimer?.invalidate()
        flushTimer = nil
        guard !held.isEmpty else { return }
        let items = held
        held = []
        apply?(items)
    }
}
