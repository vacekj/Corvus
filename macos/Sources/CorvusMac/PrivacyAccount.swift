import AppKit
import CorvusCore
import SwiftUI

/// Settings → Privacy beyond receipts and typing: phone number privacy (account attributes on the Signal
/// server, set with `updateAccount`), the default disappearing-message timer for new chats and hiding the
/// windows from screenshots and screen sharing. signal-cli cannot report the current phone number settings,
/// so the last values set here are kept (Signal's defaults until then).
@MainActor @Observable
final class AccountPrivacy {
    static let shared = AccountPrivacy()

    private static let prefix = "privacy."
    @ObservationIgnored private let defaults: UserDefaults

    /// Everyone can see the phone number (Signal: "Who can see my number").
    private(set) var numberSharing: Bool { didSet { defaults.set(numberSharing, forKey: Self.prefix + "numberSharing") } }
    /// The account can be found by its phone number (Signal: "Who can find me by number").
    private(set) var discoverableByNumber: Bool {
        didSet { defaults.set(discoverableByNumber, forKey: Self.prefix + "discoverableByNumber") }
    }
    var busy = false
    var defaultExpirationSeconds: Int {
        didSet { defaults.set(defaultExpirationSeconds, forKey: Self.prefix + "defaultExpiration") }
    }
    var hideFromScreenCapture: Bool {
        didSet {
            defaults.set(hideFromScreenCapture, forKey: Self.prefix + "hideFromScreenCapture")
            ScreenCaptureProtection.apply(hideFromScreenCapture)
        }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        func bool(_ k: String, _ def: Bool) -> Bool { defaults.object(forKey: Self.prefix + k) == nil ? def : defaults.bool(forKey: Self.prefix + k) }
        numberSharing = bool("numberSharing", false)
        discoverableByNumber = bool("discoverableByNumber", true)
        hideFromScreenCapture = bool("hideFromScreenCapture", false)
        defaultExpirationSeconds = max(0, defaults.integer(forKey: Self.prefix + "defaultExpiration"))
    }

    fileprivate func applied(numberSharing: Bool? = nil, discoverable: Bool? = nil) {
        if let numberSharing, numberSharing != self.numberSharing { self.numberSharing = numberSharing }
        if let discoverable, discoverable != discoverableByNumber { discoverableByNumber = discoverable }
    }
}

extension AppModel {
    /// "Who can see my number": everyone or nobody. Seen by everyone implies findable by number (as in Signal).
    func setNumberSharing(_ everyone: Bool) {
        let p = AccountPrivacy.shared
        guard everyone != p.numberSharing else { return }
        var params: JSON = ["numberSharing": everyone]
        if everyone && !p.discoverableByNumber { params["discoverableByNumber"] = true }
        updateAccountPrivacy(params) { p.applied(numberSharing: everyone, discoverable: everyone ? true : nil) }
    }

    /// "Who can find me by number": everyone or nobody (only while the number is not shared with everyone).
    func setDiscoverableByNumber(_ everyone: Bool) {
        let p = AccountPrivacy.shared
        guard everyone != p.discoverableByNumber, everyone || !p.numberSharing else { return }
        updateAccountPrivacy(["discoverableByNumber": everyone]) { p.applied(discoverable: everyone) }
    }

    private func updateAccountPrivacy(_ params: JSON, applied: @escaping @MainActor () -> Void) {
        let p = AccountPrivacy.shared
        guard connected, !p.busy else { return }
        p.busy = true
        Task {
            defer { p.busy = false }
            do {
                try await cli.call("updateAccount", params)
                applied()
            } catch {
                showFlash("Could not change the phone number setting: \(error.localizedDescription)")
            }
        }
    }

    /// Settings → Privacy → default timer, for a chat that was just started.
    func applyDefaultExpiration(_ key: String) {
        let seconds = AccountPrivacy.shared.defaultExpirationSeconds
        guard seconds > 0, connected, let c = chats.convs[key], c.expirationSeconds == 0, c.msgs.isEmpty else { return }
        setExpiration(key, seconds)
    }
}

/// Keeps every window of the app out of screenshots, screen recordings and screen sharing while switched on.
@MainActor
enum ScreenCaptureProtection {
    private static var observers: [NSObjectProtocol] = []

    static func apply(_ on: Bool) {
        for w in NSApp.windows { set(w, on) }
        guard on, observers.isEmpty else { return }
        // Windows opened later (settings, sheets, panels) are covered once they show up.
        let names = [NSWindow.didBecomeKeyNotification, NSWindow.didBecomeMainNotification,
                     NSWindow.didChangeOcclusionStateNotification]
        observers = names.map { name in
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { n in
                MainActor.assumeIsolated {
                    guard AccountPrivacy.shared.hideFromScreenCapture, let w = n.object as? NSWindow else { return }
                    set(w, true)
                }
            }
        }
    }

    private static func set(_ w: NSWindow, _ on: Bool) {
        if on {
            if w.sharingType != .none { w.sharingType = .none }
        } else if w.sharingType == .none {
            // Open View Once media keeps the main window hidden on its own (see ImageViewerWindow).
            if ImageViewerWindow.shared.item?.viewOnce == true && w === MainWindowTracker.shared.window { return }
            w.sharingType = .readOnly
        }
    }
}

/// The phone number, disappearing-message and screen security sections of Settings → Privacy.
struct AccountPrivacySections: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var p = AccountPrivacy.shared
        Section("Phone number") {
            Picker("Who can see my number", selection: Binding(get: { p.numberSharing }, set: { model.setNumberSharing($0) })) {
                Text("Everyone").tag(true)
                Text("Nobody").tag(false)
            }
            Picker("Who can find me by number",
                   selection: Binding(get: { p.discoverableByNumber }, set: { model.setDiscoverableByNumber($0) })) {
                Text("Everyone").tag(true)
                Text("Nobody").tag(false)
            }
            .disabled(p.numberSharing)
        }
        .disabled(!model.connected || p.busy)
        Section("Disappearing messages") {
            Picker("Default timer for new chats", selection: $p.defaultExpirationSeconds) {
                ForEach(AppModel.expirationChoices, id: \.1) { label, seconds in Text(label).tag(seconds) }
            }
        }
        Section("Screen security") {
            Toggle("Hide Corvus in screenshots and screen sharing", isOn: $p.hideFromScreenCapture)
        }
    }
}
