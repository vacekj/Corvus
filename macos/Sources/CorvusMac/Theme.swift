import AppKit
import SwiftUI

/// Colours and metrics shared by the views (Signal Desktop's own design tokens, light / dark).
enum Theme {
    static let signalBlue = Color(nsColor: rgb(0x2267f5))

    static func rgb(_ v: UInt32) -> NSColor {
        NSColor(srgbRed: CGFloat((v >> 16) & 0xff) / 255, green: CGFloat((v >> 8) & 0xff) / 255,
                blue: CGFloat(v & 0xff) / 255, alpha: 1)
    }

    static func dynamic(_ light: UInt32, _ dark: UInt32) -> NSColor {
        NSColor(name: nil) { a in a.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? rgb(dark) : rgb(light) }
    }

    /// Background of the chat list and composer (Signal: surface-secondary).
    static let chrome = Color(nsColor: dynamic(0xf5f5f5, 0x1e1e1e))

    /// Filled background of the message field (surface-tertiary).
    static let field = Color(nsColor: dynamic(0xebebeb, 0x2e2e2e))

    /// Background of the selected chat in the chat list (surface-quaternary).
    static let selection = Color(nsColor: dynamic(0xe1e1e1, 0x373737))

    /// Stable colour per contact for sender names in groups (readable on light and dark bubbles).
    static func senderColor(_ key: String) -> Color {
        let palette: [Color] = [
            Color(red: 0.82, green: 0.25, blue: 0.25), Color(red: 0.85, green: 0.45, blue: 0.10),
            Color(red: 0.62, green: 0.50, blue: 0.05), Color(red: 0.20, green: 0.60, blue: 0.30),
            Color(red: 0.10, green: 0.55, blue: 0.60), Color(red: 0.25, green: 0.45, blue: 0.85),
            Color(red: 0.50, green: 0.35, blue: 0.85), Color(red: 0.80, green: 0.30, blue: 0.60),
        ]
        var hash: UInt32 = 2166136261
        for b in key.utf8 { hash = (hash ^ UInt32(b)) &* 16777619 }
        return palette[Int(hash % UInt32(palette.count))]
    }

    /// Messages of the same author within this time form one group (joined bubbles, one avatar).
    static let groupGapMs: Int64 = 3 * 60 * 1000
}

/// Inter, the typeface of Signal Desktop, bundled with the app and registered at launch.
enum Fonts {
    static let family = "Inter"

    static func register() {
        guard let e = FileManager.default.enumerator(at: AppResources.bundle.bundleURL, includingPropertiesForKeys: nil)
        else { return }
        let urls = e.compactMap { $0 as? URL }.filter { $0.pathExtension == "otf" }
        CTFontManagerRegisterFontURLs(urls as CFArray, .process, true, nil)
    }

    static func ns(_ size: CGFloat, weight: NSFont.Weight = .regular) -> NSFont {
        let d = NSFontDescriptor(fontAttributes: [.family: family])
            .addingAttributes([.traits: [NSFontDescriptor.TraitKey.weight: weight]])
        return NSFont(descriptor: d, size: size) ?? .systemFont(ofSize: size, weight: weight)
    }
}

extension Font {
    /// Inter at a fixed size (scaled by the caller where the text size setting applies).
    static func inter(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .custom(Fonts.family, fixedSize: size).weight(weight)
    }
}

/// Signal Desktop's type scale in Inter, in place of the system text styles.
enum TypeScale {
    static let largeTitle = Font.inter(26, weight: .semibold)
    static let title = Font.inter(20, weight: .semibold)
    static let title2 = Font.inter(17, weight: .semibold)
    static let title3 = Font.inter(15, weight: .semibold)
    static let headline = Font.inter(14, weight: .semibold)
    static let body = Font.inter(14)
    static let callout = Font.inter(13)
    static let subheadline = Font.inter(12)
    static let footnote = Font.inter(12)
    static let caption = Font.inter(12)
    static let caption2 = Font.inter(11)
}

/// Small round avatar from the model's cache (or the letter placeholder).
struct AvatarView: View {
    let image: NSImage
    var size: CGFloat = 32

    var body: some View {
        Image(nsImage: image)
            .resizable()
            .interpolation(.high)
            .frame(width: size, height: size)
            .clipShape(Circle())
    }
}
