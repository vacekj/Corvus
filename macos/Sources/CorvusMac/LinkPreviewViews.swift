import AppKit
import CorvusCore
import SwiftUI

private enum PreviewImageCache {
    static let cache = NSCache<NSString, NSImage>()

    static func image(for lp: LinkPreview) -> NSImage? {
        guard !lp.imageThumb.isEmpty else { return nil }
        let key = "\(lp.url)#\(lp.imageThumb.count)" as NSString
        if let hit = cache.object(forKey: key) { return hit }
        guard let img = NSImage(data: lp.imageThumb) else { return nil }
        cache.setObject(img, forKey: key)
        return img
    }
}

/// The card of a message: thumbnail, title, description and domain. Clicking opens the link in the browser.
/// Nothing is requested from the linked site; only what the sender provided is shown.
struct LinkPreviewCard: View {
    let preview: LinkPreview
    let foreground: Color

    var body: some View {
        Button {
            if let url = preview.openURL { NSWorkspace.shared.open(url) }
        } label: {
            VStack(alignment: .leading, spacing: 0) {
                if let img = PreviewImageCache.image(for: preview) {
                    Color.clear
                        .frame(maxWidth: .infinity)
                        .frame(height: 130)
                        .overlay(Image(nsImage: img).resizable().scaledToFill())
                        .clipped()
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(preview.title).font(.system(size: NSFont.systemFontSize, weight: .semibold)).lineLimit(2)
                    if !preview.description.isEmpty {
                        Text(preview.description).font(.system(size: NSFont.smallSystemFontSize)).lineLimit(2).opacity(0.85)
                    }
                    Text(preview.host).font(.system(size: NSFont.smallSystemFontSize - 1)).opacity(0.6).lineLimit(1)
                }
                .multilineTextAlignment(.leading)
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .foregroundStyle(foreground)
            .frame(maxWidth: 300, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(foreground.opacity(0.1)))
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(preview.url)
    }
}

/// Removable preview above the composer.
struct LinkPreviewChip: View {
    let preview: LinkPreview
    let remove: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Group {
                if let img = PreviewImageCache.image(for: preview) {
                    Image(nsImage: img).resizable().scaledToFill()
                } else {
                    Image(systemName: "link").font(.title3).foregroundStyle(.secondary)
                }
            }
            .frame(width: 48, height: 48)
            .background(Theme.field.opacity(0.5))
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            VStack(alignment: .leading, spacing: 1) {
                Text(preview.title).font(.callout.weight(.semibold)).lineLimit(1)
                if !preview.description.isEmpty {
                    Text(preview.description).font(.caption).lineLimit(1).foregroundStyle(.secondary)
                }
                Text(preview.host).font(.caption2).lineLimit(1).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            Button(action: remove) { Image(systemName: "xmark.circle.fill").font(.system(size: 15)) }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .iconHelp("Remove link preview")
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.field))
    }
}

/// Keeps the draft preview in step with the composer text, the edit mode and the Settings switch.
struct LinkPreviewTriggers: ViewModifier {
    @Environment(AppModel.self) private var model

    func body(content: Content) -> some View {
        content
            .onChange(of: model.composerText) { model.refreshLinkPreview() }
            .onChange(of: model.editKey) { model.refreshLinkPreview() }
            .onChange(of: model.appearance.generateLinkPreviews) { model.refreshLinkPreview() }
    }
}
