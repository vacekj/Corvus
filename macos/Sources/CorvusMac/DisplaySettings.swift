import AppKit
import CorvusCore
import SwiftUI

/// Settings → Appearance: theme, text size and chat wallpaper (kept apart from `Appearance`, which holds
/// the bubble colours, so a zoom step does not rebuild the chat list rows).
@MainActor @Observable
final class DisplaySettings {
    static let shared = DisplaySettings()

    enum Theme: String, CaseIterable, Identifiable {
        case system, light, dark
        var id: String { rawValue }
        var title: String {
            switch self {
            case .system: "System"
            case .light: "Light"
            case .dark: "Dark"
            }
        }
        var appearance: NSAppearance? {
            switch self {
            case .system: nil
            case .light: NSAppearance(named: .aqua)
            case .dark: NSAppearance(named: .darkAqua)
            }
        }
    }

    private static let prefix = "appearance."
    @ObservationIgnored private let defaults: UserDefaults

    var theme: Theme {
        didSet {
            guard theme != oldValue else { return }
            defaults.set(theme.rawValue, forKey: Self.prefix + "theme")
            applyTheme()
        }
    }

    /// Scale of the message text and the chat list (1 = normal).
    var textZoom: Double {
        didSet {
            if textZoom == 1 { defaults.removeObject(forKey: Self.prefix + "textZoom") } else { defaults.set(textZoom, forKey: Self.prefix + "textZoom") }
        }
    }

    /// Wallpaper of every chat that has none of its own; empty = the plain chat background.
    var wallpaper: String { didSet { defaults.set(wallpaper, forKey: Self.prefix + "wallpaper") } }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        theme = Theme(rawValue: defaults.string(forKey: Self.prefix + "theme") ?? "") ?? .system
        let z = defaults.double(forKey: Self.prefix + "textZoom")
        textZoom = z > 0 ? TextZoomLevels.nearest(z) : 1
        wallpaper = defaults.string(forKey: Self.prefix + "wallpaper") ?? ""
    }

    func applyTheme() { NSApp.appearance = theme.appearance }

    /// Theme and screen capture protection, once the app runs.
    static func applyAtLaunch() {
        shared.applyTheme()
        if AccountPrivacy.shared.hideFromScreenCapture { ScreenCaptureProtection.apply(true) }
    }

    /// A font size scaled by the text size setting.
    func size(_ base: CGFloat) -> CGFloat { (base * textZoom).rounded() }

    // Sizes of the system text styles, scaled.
    static let bodySize = NSFont.systemFontSize
    static let captionSize = NSFont.preferredFont(forTextStyle: .caption1).pointSize
    static let caption2Size = NSFont.preferredFont(forTextStyle: .caption2).pointSize

    func zoomIn() { set(TextZoomLevels.larger(textZoom)) }
    func zoomOut() { set(TextZoomLevels.smaller(textZoom)) }
    func zoomReset() { set(1) }

    private func set(_ z: Double) {
        if z != textZoom { textZoom = z }
    }
}

/// View → Actual Size / Zoom In / Zoom Out. While a picture is shown full size the keys belong to it.
struct ZoomCommands: Commands {
    var body: some Commands {
        CommandGroup(before: .toolbar) {
            let d = DisplaySettings.shared
            let viewer = ImageViewerWindow.shared.item != nil
            Button("Actual Size") { if ImageViewerWindow.shared.item == nil { d.zoomReset() } }
                .keyboardShortcut("0")
                .disabled(viewer || d.textZoom == 1)
            Button("Zoom In") { if ImageViewerWindow.shared.item == nil { d.zoomIn() } }
                .keyboardShortcut("+")
                .disabled(viewer || d.textZoom >= TextZoomLevels.levels.last!)
            Button("Zoom Out") { if ImageViewerWindow.shared.item == nil { d.zoomOut() } }
                .keyboardShortcut("-")
                .disabled(viewer || d.textZoom <= TextZoomLevels.levels.first!)
            Divider()
        }
    }
}

// MARK: - Wallpapers

/// Built-in chat wallpapers: solid colours and gradients, as in Signal.
struct Wallpaper: Identifiable, Equatable {
    let id: String
    let title: String
    let colors: [Color]

    /// A chat that has its own "no wallpaper" setting.
    static let noneId = "none"

    private static func hex(_ v: UInt32) -> Color {
        Color(.sRGB, red: Double((v >> 16) & 0xff) / 255, green: Double((v >> 8) & 0xff) / 255, blue: Double(v & 0xff) / 255)
    }

    static let all: [Wallpaper] = [
        Wallpaper(id: "blush", title: "Blush", colors: [hex(0xF2D4D7)]),
        Wallpaper(id: "copper", title: "Copper", colors: [hex(0xEDD2BC)]),
        Wallpaper(id: "dust", title: "Dust", colors: [hex(0xDFD9CE)]),
        Wallpaper(id: "celadon", title: "Celadon", colors: [hex(0xCFE3D2)]),
        Wallpaper(id: "pacific", title: "Pacific", colors: [hex(0xC8DDEB)]),
        Wallpaper(id: "frost", title: "Frost", colors: [hex(0xDCE2EE)]),
        Wallpaper(id: "lilac", title: "Lilac", colors: [hex(0xE2D8F0)]),
        Wallpaper(id: "navy", title: "Navy", colors: [hex(0x2E3A55)]),
        Wallpaper(id: "sunset", title: "Sunset", colors: [hex(0xF8D9A8), hex(0xEE9B8C)]),
        Wallpaper(id: "peach", title: "Peach", colors: [hex(0xFDE6CF), hex(0xF5BBAA)]),
        Wallpaper(id: "aqua", title: "Aqua", colors: [hex(0xB4E8DF), hex(0x7DB5DC)]),
        Wallpaper(id: "sky", title: "Sky", colors: [hex(0xDDEBFB), hex(0xAFC8F2)]),
        Wallpaper(id: "bliss", title: "Bliss", colors: [hex(0xDCCDF2), hex(0xF3CADA)]),
        Wallpaper(id: "noir", title: "Noir", colors: [hex(0x3C3C40), hex(0x1C1C1F)]),
    ]

    static func find(_ id: String) -> Wallpaper? { all.first { $0.id == id } }

    @ViewBuilder
    var fill: some View {
        if colors.count == 1 {
            colors[0]
        } else {
            LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing)
        }
    }
}

/// The chat area behind the messages: the chat's own wallpaper, else the global one, else the plain colour.
struct ChatBackground: View {
    @Environment(AppModel.self) private var model
    @Environment(\.colorScheme) private var scheme
    let key: String

    var body: some View {
        let own = model.chats.convs[key]?.wallpaper ?? ""
        if let w = Wallpaper.find(own.isEmpty ? DisplaySettings.shared.wallpaper : own) {
            // Dimmed in the dark theme, so the bubbles keep their contrast.
            w.fill.overlay(scheme == .dark ? Color.black.opacity(0.55) : Color.clear)
        } else {
            model.appearance.backgroundColor
        }
    }
}

/// A row of wallpaper swatches; `selection` "" means none (or "follow the default" with `defaultTitle`).
struct WallpaperPicker: View {
    @Binding var selection: String
    var defaultTitle: String?

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 34, maximum: 40), spacing: 8)], alignment: .leading, spacing: 8) {
            if let defaultTitle {
                swatch(id: "", title: defaultTitle) { Image(systemName: "arrow.uturn.backward").foregroundStyle(.secondary) }
                swatch(id: Wallpaper.noneId, title: "None") { Image(systemName: "slash.circle").foregroundStyle(.secondary) }
            } else {
                swatch(id: "", title: "None") { Image(systemName: "slash.circle").foregroundStyle(.secondary) }
            }
            ForEach(Wallpaper.all) { w in
                swatch(id: w.id, title: w.title) { w.fill }
            }
        }
    }

    private func swatch<Content: View>(id: String, title: String, @ViewBuilder content: () -> Content) -> some View {
        Button { selection = id } label: {
            ZStack {
                Circle().fill(Theme.field)
                content().clipShape(Circle())
            }
            .frame(width: 30, height: 30)
            .overlay(Circle().strokeBorder(selection == id ? Theme.signalBlue : Color.secondary.opacity(0.3),
                                           lineWidth: selection == id ? 2.5 : 1))
            .padding(2)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(title)
        .accessibilityLabel(title)
        .accessibilityAddTraits(selection == id ? .isSelected : [])
    }
}

extension AppModel {
    /// Wallpaper of one chat: "" follows Settings → Appearance, `Wallpaper.noneId` shows none.
    func setChatWallpaper(_ key: String, _ id: String) {
        guard chats.convs[key] != nil, chats.convs[key]!.wallpaper != id else { return }
        if let rec = chats.setWallpaper(key, id) { persist(rec) }
    }
}

/// Theme, text size and wallpaper sections of Settings → Appearance.
struct DisplaySettingsSections: View {
    var body: some View {
        @Bindable var d = DisplaySettings.shared
        Section("Display") {
            Picker("Theme", selection: $d.theme) {
                ForEach(DisplaySettings.Theme.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            Picker("Text size", selection: $d.textZoom) {
                ForEach(TextZoomLevels.levels, id: \.self) { Text(TextZoomLevels.label($0)).tag($0) }
            }
        }
        Section("Chat wallpaper") {
            WallpaperPicker(selection: $d.wallpaper)
        }
    }
}

/// Wallpaper of the open chat in its info panel.
struct ChatWallpaperRow: View {
    @Environment(AppModel.self) private var model
    let conversation: Conversation

    var body: some View {
        let c = conversation
        DisclosureGroup {
            WallpaperPicker(selection: Binding(get: { c.wallpaper }, set: { model.setChatWallpaper(c.key, $0) }),
                            defaultTitle: "Default (Settings → Appearance)")
                .padding(.top, 6)
        } label: {
            Label("Chat wallpaper", systemImage: "photo.artframe")
        }
    }
}
