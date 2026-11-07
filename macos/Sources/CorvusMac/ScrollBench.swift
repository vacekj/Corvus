import AppKit
import QuartzCore

/// Scroll benchmark for development: with CORVUS_SCROLL_BENCH set, the first open chat is scrolled up and
/// down at a steady speed, one step per display refresh, and frame timing is logged with the perf marks
/// (`log show --predicate 'subsystem == "io.github.corvus.mac"'`). A frame counts as dropped when the
/// display link missed a refresh, i.e. the main thread did not finish a frame in time.
@MainActor
final class ScrollBench: NSObject {
    static let shared = ScrollBench()
    private var link: CADisplayLink?
    private weak var scroll: NSScrollView?
    private var last: CFTimeInterval = 0
    private var deltas: [Double] = []
    private var hitches: [String] = []
    private var step: CGFloat = 0
    private var phase = 0
    private var frames = 0
    private var poll: Timer?

    static let framesPerLeg = Int(ProcessInfo.processInfo.environment["CORVUS_SCROLL_BENCH_FRAMES"] ?? "") ?? 600
    static var enabled: Bool { ProcessInfo.processInfo.environment["CORVUS_SCROLL_BENCH"] != nil }

    private weak var model: AppModel?

    func arm(_ model: AppModel) {
        self.model = model
        if let n = ProcessInfo.processInfo.environment["CORVUS_OPEN_BENCH"].flatMap(Int.init) { openBench(n); return }
        guard Self.enabled else { return }
        poll = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tryStart() }
        }
    }

    private func tryStart() {
        // Run on the fastest screen (a ProMotion panel next to a 60 Hz monitor).
        if let window = NSApp.windows.first(where: { $0.isVisible && $0.styleMask.contains(.titled) }),
           let best = NSScreen.screens.max(by: { $0.maximumFramesPerSecond < $1.maximumFramesPerSecond }),
           (window.screen?.maximumFramesPerSecond ?? 0) < best.maximumFramesPerSecond {
            Perf.mark("scroll bench: moving the window to the \(best.maximumFramesPerSecond) Hz screen")
            window.setFrame(best.visibleFrame, display: true)
            return
        }
        // CORVUS_SCROLL_BENCH_CHAT: part of the title of the chat to open for the run.
        if let model, model.current == nil, let want = ProcessInfo.processInfo.environment["CORVUS_SCROLL_BENCH_CHAT"],
           let c = (want == "largest" ? model.chats.convs.values.max(by: { $0.msgs.count < $1.msgs.count }) : nil)
               ?? model.chats.convs.values.first(where: { model.title($0).caseInsensitiveCompare(want) == .orderedSame })
               ?? model.chats.convs.values.first(where: { model.title($0).localizedCaseInsensitiveContains(want) }) {
            model.openConversation(c.key)
            return
        }
        if model?.current == nil { Perf.mark("scroll bench: waiting for an open chat") }
        guard link == nil, let window = NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil }),
              let sv = Self.scrollViews(window.contentView!).filter({ $0.convert($0.bounds, to: nil).minX > 200 })
                  .max(by: { ($0.documentView?.frame.height ?? 0) < ($1.documentView?.frame.height ?? 0) }),
              (sv.documentView?.frame.height ?? 0) > sv.contentView.bounds.height * 3 else { return }
        poll?.invalidate()
        scroll = sv
        let speed = Double(ProcessInfo.processInfo.environment["CORVUS_SCROLL_BENCH"] ?? "") ?? 3000 // points per second
        step = CGFloat(speed / Double(window.screen?.maximumFramesPerSecond ?? 120))
        Perf.mark("scroll bench: start, \(Int(speed)) pt/s, screen \(window.screen?.maximumFramesPerSecond ?? 0) Hz")
        let l = sv.displayLink(target: self, selector: #selector(tick(_:)))
        l.add(to: .main, forMode: .common)
        link = l
    }

    @objc private func tick(_ l: CADisplayLink) {
        if last > 0 {
            let d = (l.timestamp - last) * 1000
            deltas.append(d)
            if d > 12, let sv = scroll { hitches.append(String(format: "%.0fms@%.0f", d, sv.contentView.bounds.origin.y)) }
        }
        last = l.timestamp
        guard let sv = scroll, let doc = sv.documentView else { finish(l); return }
        frames += 1
        let clip = sv.contentView
        let maxY = max(0, doc.frame.height - clip.bounds.height)
        var y = clip.bounds.origin.y
        let flipped = doc.isFlipped
        // phase 0: towards older messages, phase 1: back towards the newest
        let up = phase == 0
        y += (up == flipped ? -step : step)
        let limitHit = y <= 0 || y >= maxY
        y = min(max(y, 0), maxY)
        clip.scroll(to: NSPoint(x: clip.bounds.origin.x, y: y))
        sv.reflectScrolledClipView(clip)
        if limitHit || frames > Self.framesPerLeg {
            phase += 1
            frames = 0
            if phase > 1 { finish(l) }
        }
    }

    private func finish(_ l: CADisplayLink) {
        l.invalidate()
        link = nil
        let d = deltas.sorted()
        guard !d.isEmpty, let period = scroll?.window?.screen.map({ 1000 / Double($0.maximumFramesPerSecond) }) else { return }
        let dropped = deltas.reduce(0) { $0 + max(0, Int(($1 / period).rounded()) - 1) }
        let p = { (q: Double) in d[min(d.count - 1, Int(Double(d.count) * q))] }
        Self.logHitches(hitches)
        Perf.mark(String(format: "scroll bench: %d frames, %d dropped (%.1f%%), p50 %.1f ms, p95 %.1f ms, p99 %.1f ms, max %.1f ms",
                         deltas.count, dropped, 100 * Double(dropped) / Double(deltas.count + dropped), p(0.5), p(0.95), p(0.99), d.last!))
    }

    /// CORVUS_OPEN_BENCH=n: opens the largest chats in turn, n times, and logs how long each open takes until
    /// the new state is committed to the screen (the Core Animation transaction holding the change is done).
    private func openBench(_ n: Int) {
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(6)) // history loaded, window up
            guard let model else { return }
            // The first 16 chats of the chat list in turn: more than are kept ready, so cold opens are included.
            let keys = model.chatListItems(archived: false).prefix(16).map(\.key)
            guard !keys.isEmpty else { return }
            var times: [Double] = [], cold: [Double] = [], coldFirst: [Double] = []
            for i in 0..<n {
                let key = keys[i % keys.count]
                let wasWarm = model.warmChats.contains(key)
                let t = CACurrentMediaTime()
                let done: Double = await withCheckedContinuation { cont in
                    CATransaction.begin()
                    CATransaction.setCompletionBlock { cont.resume(returning: (CACurrentMediaTime() - t) * 1000) }
                    model.openConversation(key)
                    CATransaction.commit()
                }
                // the SwiftUI update runs at the end of this run loop pass; wait for it to be on screen
                let shown: Double = await withCheckedContinuation { cont in
                    DispatchQueue.main.async {
                        CATransaction.begin()
                        CATransaction.setCompletionBlock { cont.resume(returning: (CACurrentMediaTime() - t) * 1000) }
                        CATransaction.commit()
                    }
                }
                times.append(shown)
                _ = done
                // The switch (header, composer, selection) is committed before the list build starts.
                let switched = WarmListsContainer.lastBuildStart > t ? (WarmListsContainer.lastBuildStart - t) * 1000 : shown
                if !wasWarm { cold.append(shown); coldFirst.append(switched) }
                try? await Task.sleep(for: .milliseconds(250))
            }
            let c = cold.sorted(), f = coldFirst.sorted()
            if !c.isEmpty {
                Perf.mark(String(format: "open bench: %d cold opens, switch committed p50 %.1f ms, max %.1f ms; messages p50 %.1f ms, max %.1f ms",
                                 c.count, f[f.count / 2], f.last!, c[c.count / 2], c.last!))
            }
            let d = times.sorted()
            Perf.mark(String(format: "open bench: %d opens, p50 %.1f ms, p90 %.1f ms, max %.1f ms; all: %@", d.count,
                             d[d.count / 2], d[min(d.count - 1, d.count * 9 / 10)], d.last!,
                             times.map { String(format: "%.0f", $0) }.joined(separator: " ")))
        }
    }

    private static func logHitches(_ h: [String]) {
        if !h.isEmpty { Perf.mark("scroll bench hitches: " + h.prefix(60).joined(separator: " ")) }
    }

    private static func scrollViews(_ v: NSView) -> [NSScrollView] {
        var out: [NSScrollView] = []
        if let s = v as? NSScrollView { out.append(s) }
        for c in v.subviews { out += scrollViews(c) }
        return out
    }
}
