import AppKit
import CorvusCore
import SwiftUI

/// State of the app's "chrome" around the chats: the call list, the keyboard shortcuts sheet and the
/// menu bar's notification mute. Kept out of `AppModel` so none of it makes the chat views update.
@MainActor @Observable
final class AppChrome {
    static let shared = AppChrome()

    var callsShown = false
    var shortcutsShown = false
    var mute = NotificationMute.load() {
        didSet {
            guard mute != oldValue else { return }
            mute.save()
            scheduleUnmute()
        }
    }
    @ObservationIgnored private var unmuteTask: Task<Void, Never>?

    private init() { scheduleUnmute() }

    /// A timed mute ends by itself (the menu then offers "Mute notifications" again).
    private func scheduleUnmute() {
        unmuteTask?.cancel()
        guard let until = mute.until, until != .distantFuture else { return }
        unmuteTask = Task { [weak self] in
            let wait = until.timeIntervalSinceNow
            if wait > 0 { try? await Task.sleep(for: .seconds(wait)) }
            guard !Task.isCancelled, let self, self.mute.until == until else { return }
            self.mute = NotificationMute()
        }
    }

    func muteNotifications(for seconds: TimeInterval?) {
        mute = .muted(for: seconds, now: Date())
    }

    func unmuteNotifications() { mute = NotificationMute() }

    /// Read when a message arrives, not by views: no observation.
    var notificationsMuted: Bool {
        let m = mute
        if m.until != nil && !m.isMuted(at: Date()) {
            mute = NotificationMute() // the time ran out
            return false
        }
        return m.isMuted(at: Date())
    }
}

extension AppModel {
    /// Everything this part of the app needs before `start()`: notification actions, the proxy option for
    /// the Signal backend, the call history and Corvus's own update checks.
    func installAppChrome() {
        _ = AppChrome.shared // a timed notification mute ends on time
        notifier.onReply = { [weak self] key, text in self?.replyFromNotification(key, text) }
        notifier.onMarkRead = { [weak self] key in self?.markReadWithoutOpening(key) }
        cli.globalOptions = SignalProxy.arguments(ProxySetting.value)
        CallHistoryStore.shared.install()
        AppUpdater.shared.startAutomaticChecks()
    }

    /// No banner or sound: notifications are muted from the menu bar, or the chat is open in its own window
    /// in front of the user (that window marks it read).
    func alertSuppressed(_ key: String) -> Bool {
        AppChrome.shared.notificationsMuted || ChatPopups.shared.isLooking(at: key)
    }
}

/// The sheets of the main window that belong to the app chrome (call list, keyboard shortcuts).
struct AppChromeSheets: ViewModifier {
    private let chrome = AppChrome.shared

    func body(content: Content) -> some View {
        @Bindable var chrome = chrome
        content
            .sheet(isPresented: $chrome.callsShown) { CallHistorySheet() }
            .sheet(isPresented: $chrome.shortcutsShown) { KeyboardShortcutsSheet() }
    }
}
