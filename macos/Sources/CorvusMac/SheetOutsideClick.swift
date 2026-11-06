import AppKit

/// A click on the window behind an open sheet closes the sheet, as Esc does (SwiftUI sheets close on Esc).
/// Alerts are left alone: they ask for a decision.
@MainActor
enum SheetOutsideClick {
    private static var monitor: Any?

    static func install() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { e in
            let number = e.windowNumber
            let handled = MainActor.assumeIsolated { () -> Bool in
                guard let parent = NSApp.window(withWindowNumber: number), let sheet = parent.attachedSheet,
                      closable(sheet) else { return false }
                close(sheet)
                return true
            }
            return handled ? nil : e
        }
    }

    private static func closable(_ sheet: NSWindow) -> Bool {
        let name = String(describing: type(of: sheet))
        return !name.contains("Alert") && sheet.attachedSheet == nil
    }

    private static func close(_ sheet: NSWindow) {
        sheet.makeKey()
        for type in [NSEvent.EventType.keyDown, .keyUp] {
            if let esc = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                          windowNumber: sheet.windowNumber, context: nil, characters: "\u{1b}",
                                          charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53) {
                NSApp.postEvent(esc, atStart: false)
            }
        }
    }
}
