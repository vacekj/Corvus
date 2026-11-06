import AppKit
import SwiftUI

/// Key presses for the main window that must work wherever the focus is (the composer usually has it).
/// The handler returns true when it used the event.
struct LocalKeyMonitor: ViewModifier {
    var enabled = true
    /// Plain keys (no ⌘/⌃/⌥) are left to a focused text field when this is false.
    var overrideTextFields = true
    let handler: (NSEvent) -> Bool
    @State private var monitor: Any?

    func body(content: Content) -> some View {
        content
            .onAppear { if enabled { install() } }
            .onDisappear { remove() }
            .onChange(of: enabled) { _, on in if on { install() } else { remove() } }
    }

    private func install() {
        remove()
        let handler = handler, overrideTextFields = overrideTextFields
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { e in
            guard e.window != nil, e.window === MainWindowTracker.shared.window || e.window?.sheetParent === MainWindowTracker.shared.window
            else { return e }
            let plain = e.modifierFlags.intersection([.command, .control, .option]).isEmpty
            if plain && !overrideTextFields && e.window?.firstResponder is NSText { return e }
            return handler(e) ? nil : e
        }
    }

    private func remove() {
        if let m = monitor { NSEvent.removeMonitor(m) }
        monitor = nil
    }
}

extension View {
    func onLocalKeyDown(enabled: Bool = true, overrideTextFields: Bool = true, _ handler: @escaping (NSEvent) -> Bool) -> some View {
        modifier(LocalKeyMonitor(enabled: enabled, overrideTextFields: overrideTextFields, handler: handler))
    }
}

enum KeyCode {
    static let returnKey: UInt16 = 36, enter: UInt16 = 76, escape: UInt16 = 53
    static let leftArrow: UInt16 = 123, rightArrow: UInt16 = 124, m: UInt16 = 46
}
