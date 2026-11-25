import AppKit
import CorvusCore

// Messages the server kept while Corvus was closed or offline arrive in one burst after connecting.
// The backend says when that burst starts and ends ("syncState"); until it ends they are only
// collected, then applied in one pass: no sound, notification or dock bounce for them, and the chat
// list changes once instead of with every message.

extension AppModel {
    /// A catch-up of days shows what came so far after this long, still quietly.
    static let catchupFlushSeconds: Double = 20

    func bufferEnvelope(_ env: JSON) {
        earlyEnvelopes.append(env)
        guard catchingUp, !catchupCountScheduled else { return }
        // The count in the status bar, a few times a second at most.
        catchupCountScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.catchupCountScheduled = false
                if self.catchingUp { self.catchupCount = self.earlyEnvelopes.count }
            }
        }
    }

    func setCatchingUp(_ on: Bool) {
        if on {
            guard !catchingUp else { return }
            catchingUp = true
            catchupCount = 0
            catchupGen &+= 1
            scheduleCatchupFlush(catchupGen)
            return
        }
        guard catchingUp else { return }
        catchingUp = false
        catchupCount = 0
        flushBacklog()
    }

    private func scheduleCatchupFlush(_ gen: Int) {
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.catchupFlushSeconds) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.catchingUp, self.catchupGen == gen else { return }
                self.flushBacklog()
                self.scheduleCatchupFlush(gen)
            }
        }
    }

    /// Applies the collected messages in one go (once the history is loaded).
    func flushBacklog() {
        guard historyReady, !earlyEnvelopes.isEmpty else { return }
        let items = earlyEnvelopes
        earlyEnvelopes = []
        let started = Date()
        quietBatch = true
        for env in items { onEnvelope(env) }
        quietBatch = false
        if current != nil { updateSearch() }
        listChanged()
        let line = "catch-up: \(items.count) envelopes applied in \(Int(Date().timeIntervalSince(started) * 1000)) ms"
        Perf.mark(line)
        #if DEBUG
        FileHandle.standardError.write(Data((line + "\n").utf8))
        #endif
    }

    /// "Catching up … 120 messages" in the status bar while a long catch-up runs.
    var catchupText: String? {
        guard catchingUp, catchupCount > 0 else { return nil }
        return "Catching up … \(catchupCount) message\(catchupCount == 1 ? "" : "s")"
    }
}
