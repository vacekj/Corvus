import AppKit
import QuartzCore
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
        observers.append(nc.addObserver(forName: NSScrollView.willStartLiveScrollNotification, object: nil, queue: .main) { n in
            let sv = n.object as? NSScrollView
            MainActor.assumeIsolated {
                ScrollHold.shared.began()
                if let sv { LiveScrollMonitor.shared.began(sv) }
            }
        })
        observers.append(nc.addObserver(forName: NSScrollView.didEndLiveScrollNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated {
                ScrollHold.shared.ended()
                LiveScrollMonitor.shared.ended()
            }
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

/// Frame times of real scroll gestures (trackpad or wheel, momentum included): one perf log line per
/// gesture ("live scroll: …"). A display link runs only while scrolling; a refresh it missed is a frame
/// the main thread did not finish in time.
@MainActor
final class LiveScrollMonitor: NSObject {
    static let shared = LiveScrollMonitor()
    private var link: CADisplayLink?
    private var last: CFTimeInterval = 0
    private var deltas: [Double] = []
    private weak var scroll: NSScrollView?

    func began(_ sv: NSScrollView) {
        guard link == nil else { return }
        scroll = sv
        last = 0
        deltas.removeAll(keepingCapacity: true)
        let l = sv.displayLink(target: self, selector: #selector(tick(_:)))
        l.add(to: .main, forMode: .common)
        link = l
        Perf.mark("live scroll start")
    }

    @objc private func tick(_ l: CADisplayLink) {
        if last > 0 { deltas.append((l.timestamp - last) * 1000) }
        last = l.timestamp
    }

    func ended() {
        link?.invalidate()
        link = nil
        guard deltas.count > 10, let fps = scroll?.window?.screen?.maximumFramesPerSecond, fps > 0 else { return }
        let period = 1000 / Double(fps)
        let dropped = deltas.reduce(0) { $0 + max(0, Int(($1 / period).rounded()) - 1) }
        let s = deltas.sorted()
        Perf.mark(String(format: "live scroll: %d frames at %d Hz, %d dropped (%.1f%%), p50 %.1f ms, p95 %.1f ms, max %.1f ms",
                         s.count, fps, dropped, 100 * Double(dropped) / Double(s.count + dropped),
                         s[s.count / 2], s[min(s.count - 1, s.count * 95 / 100)], s.last!))
    }
}
