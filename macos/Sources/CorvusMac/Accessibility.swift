import SwiftUI

extension View {
    /// Tooltip and VoiceOver label in one, for buttons that show only an icon: `.help` alone is read as a
    /// hint after the symbol's generic name ("face.smiling" becomes "Smiling face").
    func iconHelp(_ text: String) -> some View {
        help(text).accessibilityLabel(text)
    }

    /// Like `iconHelp`, with a tooltip that also names the shortcut ("Search this conversation (⌘F)") while
    /// VoiceOver reads only the action.
    func iconHelp(_ label: String, tooltip: String) -> some View {
        help(tooltip).accessibilityLabel(label)
    }
}
