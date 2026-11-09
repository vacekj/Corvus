import AppKit
import CorvusCore
import SwiftUI

/// The attachments of a bubble: two or more pictures / videos form an album grid, everything else is listed
/// below it one by one.
struct AttachmentStack: View {
    let message: Message
    let foreground: Color
    var edgeToEdge = false

    var body: some View {
        let atts = message.attachments
        let album = atts.indices.filter { atts[$0].isAlbumMedia }
        if album.count >= 2 {
            MediaAlbum(message: message, indices: album, width: edgeToEdge ? 340 : 300, cornerRadius: edgeToEdge ? 0 : 10)
            ForEach(atts.indices.filter { !atts[$0].isAlbumMedia }, id: \.self) { i in
                AttachmentView(message: message, index: i, attachment: atts[i], foreground: foreground, edgeToEdge: edgeToEdge)
            }
        } else {
            ForEach(Array(atts.enumerated()), id: \.offset) { i, att in
                AttachmentView(message: message, index: i, attachment: att, foreground: foreground, edgeToEdge: edgeToEdge)
            }
        }
    }
}

/// Signal-style grid; its size comes from the count and the stored pixel sizes only (no jump on decode).
private struct MediaAlbum: View {
    let message: Message
    let indices: [Int]
    let width: CGFloat
    let cornerRadius: CGFloat

    var body: some View {
        let layout = AlbumLayout.make(aspects: indices.map { message.attachments[$0].aspect }, width: width)
        ZStack(alignment: .topLeading) {
            ForEach(Array(layout.tiles.enumerated()), id: \.offset) { n, tile in
                AlbumTile(message: message, index: indices[n], size: tile.size,
                          overflow: n == layout.tiles.count - 1 ? layout.overflow : 0)
                    .offset(x: tile.minX, y: tile.minY)
            }
        }
        .frame(width: layout.size.width, height: layout.size.height, alignment: .topLeading)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }
}

private struct AlbumTile: View {
    @Environment(AppModel.self) private var model
    @Environment(\.conversationKey) private var conversationKey
    @Environment(\.displayScale) private var displayScale
    let message: Message
    let index: Int
    let size: CGSize
    let overflow: Int
    @State private var image: NSImage?
    @State private var failed = false

    var body: some View {
        let att = message.attachments[index]
        let px = pixels(att)
        let image = self.image ?? (att.isVideo ? model.cachedVideoPoster(att, maxPixel: px) : model.cachedDisplayImage(att, maxPixel: px))
        ZStack {
            if let image {
                Image(nsImage: image).resizable().interpolation(.high).aspectRatio(contentMode: .fill)
                    .frame(width: size.width, height: size.height)
            } else {
                Rectangle().fill(att.isVideo ? Color.black.opacity(0.6) : Theme.field)
                if failed { Image(systemName: att.isVideo ? "film" : "photo").font(.title3).foregroundStyle(.secondary) }
            }
            if att.isVideo && overflow == 0 {
                Image(systemName: "play.circle.fill")
                    .font(.system(size: min(36, size.height * 0.35)))
                    .foregroundStyle(.white)
                    .shadow(radius: 3)
            }
            if overflow > 0 {
                Rectangle().fill(.black.opacity(0.45))
                Text("+\(overflow)").font(.system(size: 26, weight: .semibold)).foregroundStyle(.white)
            }
        }
        .frame(width: size.width, height: size.height)
        .clipped()
        .contentShape(Rectangle())
        .onTapGesture { model.openMediaViewer(message, index) }
        .overlay(alignment: .bottomLeading) {
            if att.isGif && overflow == 0 {
                Text("GIF").font(.caption2.weight(.bold)).foregroundStyle(.white)
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .background(Capsule().fill(.black.opacity(0.5)))
                    .padding(6)
                    .allowsHitTesting(false)
            }
        }
        .help(att.filename)
        .task(id: "\(model.attachmentToken(message, index))|\(px)") {
            if self.image != nil || conversationKey.isEmpty { return }
            let img = att.isVideo
                ? await model.videoPoster(conversationKey, message, index, maxPixel: px)
                : await model.displayImage(conversationKey, att, maxPixel: px, message: message, index: index)
            if let img { self.image = img } else { failed = true }
        }
    }

    /// Long side to decode so the picture still covers the tile after cropping (`.fill`); in steps of 128 px,
    /// so nearby tile sizes share one decoded copy.
    private func pixels(_ att: Attachment) -> Int {
        let scale = max(displayScale, 2)
        let side = max(size.width, size.height) * scale
        let crop = att.aspect.map { CGFloat(max($0, 1 / $0)) } ?? 1.5
        let px = side * min(max(crop, 1), 3)
        return Int((px / 128).rounded(.up) * 128)
    }
}
