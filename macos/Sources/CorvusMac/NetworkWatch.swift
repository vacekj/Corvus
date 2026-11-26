import AppKit
import Network

/// Tells the backend when the Mac woke up or the network came back: it then reconnects at once instead
/// of after its backoff (up to a minute), so the messages that arrived meanwhile come in right away.
@MainActor
final class NetworkWatch {
    private let monitor = NWPathMonitor()
    private var wakeObserver: NSObjectProtocol?
    private var online = true

    func start(_ nudge: @escaping @MainActor () -> Void) {
        guard wakeObserver == nil else { return }
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated { nudge() }
        }
        monitor.pathUpdateHandler = { [weak self] path in
            let now = path.status == .satisfied
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    if now && !self.online { nudge() }
                    self.online = now
                }
            }
        }
        monitor.start(queue: DispatchQueue(label: "corvus.network-watch", qos: .utility))
    }
}
