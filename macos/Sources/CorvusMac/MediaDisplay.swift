import AppKit
import AVFoundation
import CorvusCore
import ImageIO
import SwiftUI

/// Pictures and video posters shown in chats are decoded from the original attachment (signal-cli's file,
/// the encrypted Signal Desktop copy or the file we sent) when they come into view. Nothing is stored in the
/// history: decoded images live in a memory cache only, scaled to what the screen needs.
@MainActor
final class MediaImageCache {
    static let shared = MediaImageCache()
    private let cache = NSCache<NSString, NSImage>()
    private var pending: [String: Task<NSImage?, Never>] = [:]

    // Decoded bytes. Pictures are decoded at the size they are shown, so this is some eighty of them; the
    // rest is decoded again when scrolled back to (the system also empties the cache when memory is short).
    init() { cache.totalCostLimit = 96 * 1024 * 1024 }

    /// Latest decoded size per attachment, so the media viewer can show it while the original loads.
    private var latest: [String: String] = [:]

    func cached(_ key: String) -> NSImage? { cache.object(forKey: key as NSString) }

    /// Any decoded picture of `base` (an attachment), whatever size it was decoded at.
    func anyCached(base: String) -> NSImage? { latest[base].flatMap(cached) }

    func image(_ key: String, base: String? = nil, load: @escaping @Sendable () async -> NSImage?) async -> NSImage? {
        if let img = cached(key) { return img }
        if let t = pending[key] { return await t.value }
        let t = Task { await load() }
        pending[key] = t
        let img = await t.value
        pending[key] = nil
        if let img {
            let px = img.representations.first.map { $0.pixelsWide * $0.pixelsHigh * 4 } ?? 0
            cache.setObject(img, forKey: key as NSString, cost: px)
            if let base { latest[base] = key }
        }
        return img
    }
}

enum MediaDecode {
    /// Pixel size of an image with its EXIF orientation applied.
    static func orientedSize(_ data: Data) -> (Int, Int)? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil),
              let p = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              let w = p[kCGImagePropertyPixelWidth] as? Int, let h = p[kCGImagePropertyPixelHeight] as? Int else { return nil }
        let o = p[kCGImagePropertyOrientation] as? Int ?? 1
        return o >= 5 && o <= 8 ? (h, w) : (w, h) // 5…8 are rotated by 90°
    }

    /// Decodes an image with its EXIF orientation applied, at most `maxPixel` on the longer side.
    static func image(_ data: Data, maxPixel: Int) -> NSImage? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let opts: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                     kCGImageSourceCreateThumbnailWithTransform: true,
                                     kCGImageSourceShouldCacheImmediately: true,
                                     kCGImageSourceThumbnailMaxPixelSize: maxPixel]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
    }

    /// First frame and display size (rotation applied) of a video file.
    static func poster(_ url: URL, maxPixel: Int) async -> (NSImage?, CGSize?) {
        let asset = AVURLAsset(url: url)
        var size: CGSize?
        if let track = try? await asset.loadTracks(withMediaType: .video).first,
           let (natural, transform) = try? await track.load(.naturalSize, .preferredTransform) {
            let r = CGRect(origin: .zero, size: natural).applying(transform)
            size = CGSize(width: abs(r.width), height: abs(r.height))
        }
        let gen = AVAssetImageGenerator(asset: asset)
        gen.appliesPreferredTrackTransform = true
        gen.maximumSize = CGSize(width: maxPixel, height: maxPixel)
        let cg = try? await gen.image(at: CMTime(seconds: 0.1, preferredTimescale: 600)).image
        return (cg.map { NSImage(cgImage: $0, size: NSSize(width: $0.width, height: $0.height)) }, size)
    }
}

extension AppModel {
    /// Bubble size for media of `w`×`h` pixels: the aspect ratio is kept; very long or wide pictures are cropped
    /// by the caller (`.fill`) instead of being stretched.
    static func mediaFrame(width w: Int, height h: Int, maxSide: CGFloat) -> CGSize {
        guard w > 0, h > 0 else { return CGSize(width: maxSide, height: maxSide * 0.75) }
        let w = CGFloat(w), h = CGFloat(h)
        let scale = min(maxSide / w, maxSide / h, 2) // small pictures are enlarged a little
        var size = CGSize(width: w * scale, height: h * scale)
        // Extreme panoramas / slices: keep at least a usable strip, cropped.
        if size.width < 120 { size.width = 120 }
        if size.height < 80 { size.height = 80 }
        return size
    }

    private func mediaCacheKey(_ att: Attachment, _ px: Int) -> String {
        mediaCacheBase(att) + "|\(px)"
    }

    func mediaCacheBase(_ att: Attachment) -> String { "\(att.id)|\(att.encPath)|\(att.path)|\(att.size)" }

    /// A decoded picture (or video poster) of the attachment at any size, for an instant first frame.
    func anyCachedImage(_ att: Attachment) -> NSImage? {
        MediaImageCache.shared.anyCached(base: mediaCacheBase(att)) ?? MediaImageCache.shared.anyCached(base: mediaCacheBase(att) + "|poster")
    }

    func cachedVideoPoster(_ att: Attachment, maxPixel: Int) -> NSImage? {
        MediaImageCache.shared.cached(mediaCacheKey(att, maxPixel) + "|poster")
    }

    /// Already decoded picture, so a row scrolled back into view shows it at once instead of a placeholder.
    func cachedDisplayImage(_ att: Attachment, maxPixel: Int) -> NSImage? {
        MediaImageCache.shared.cached(mediaCacheKey(att, maxPixel))
    }

    /// Full-quality picture of an image attachment, decoded for display. With a message, its stored pixel
    /// size is corrected when it differs (Signal reports the size before EXIF rotation).
    func displayImage(_ key: String, _ att: Attachment, maxPixel: Int, message: Message? = nil, index: Int = 0) async -> NSImage? {
        await MediaImageCache.shared.image(mediaCacheKey(att, maxPixel), base: mediaCacheBase(att)) { [weak self] in
            guard let data = try? await self?.fetchAttachmentData(key, att), !data.isEmpty else { return nil }
            let (img, size) = await Task.detached { (MediaDecode.image(data, maxPixel: maxPixel), MediaDecode.orientedSize(data)) }.value
            if let message, let (w, h) = size { await self?.noteMediaSize(key, message, index, w, h) }
            return img
        }
    }

    /// Poster frame of a video attachment (the file is fetched once and reused for playback).
    func videoPoster(_ key: String, _ m: Message, _ i: Int, maxPixel: Int) async -> NSImage? {
        guard i < m.attachments.count else { return nil }
        let att = m.attachments[i], token = attachmentToken(m, i)
        return await MediaImageCache.shared.image(mediaCacheKey(att, maxPixel) + "|poster", base: mediaCacheBase(att) + "|poster") { [weak self] in
            guard let self, let url = try? await self.videoFile(key, att, token: token) else { return nil }
            let (img, size) = await MediaDecode.poster(url, maxPixel: maxPixel)
            if let size { await self.noteMediaSize(key, m, i, Int(size.width), Int(size.height)) }
            return img
        }
    }

    /// Local file of a video: the backend's own file when there is one, else a temporary copy.
    func videoFile(_ key: String, _ att: Attachment, token: String) async throws -> URL {
        if let url = videoFiles[token], FileManager.default.fileExists(atPath: url.path) { return url }
        if let url = Self.backendAttachmentURL(att) {
            videoFiles[token] = url
            return url
        }
        let data = try await fetchAttachmentData(key, att)
        guard !data.isEmpty else { throw RpcError("The video file is empty.") }
        let suffix = AttachmentPolicy.mediaSuffix(filename: att.filename, contentType: att.contentType, fallback: "mp4")
        let url = try Media.writeAttachmentTemp(data, name: "video." + suffix)
        videoFiles[token] = url
        return url
    }

    /// The backend keeps received attachments as `<data dir>/attachments/<id>`; reading that file avoids
    /// sending megabytes of base64 through JSON-RPC.
    static func backendAttachmentURL(_ att: Attachment) -> URL? {
        SignalDataDir.attachmentURL(id: att.id)
    }

    /// The real (rotated) pixel size became known: remember it so the bubble keeps its shape next time.
    func noteMediaSize(_ key: String, _ m: Message, _ i: Int, _ w: Int, _ h: Int) {
        guard w > 0, h > 0, let c = chats.convs[key], let mi = chats.findMessage(c, ts: m.ts, authors: [chats.effectiveAuthor(c, m)]),
              i < c.msgs[mi].attachments.count else { return }
        let a = c.msgs[mi].attachments[i]
        if a.width == w && a.height == h { return }
        chats.convs[key]!.msgs[mi].attachments[i].width = w
        chats.convs[key]!.msgs[mi].attachments[i].height = h
        persist(Records.attachmentsUpdate(key, chats.convs[key]!.msgs[mi]))
    }
}

/// An image attachment in a bubble, decoded from the original file.
struct FullImageView: View {
    @Environment(AppModel.self) private var model
    let conversation: String
    let message: Message
    let index: Int
    let maxSide: CGFloat
    let cornerRadius: CGFloat
    @State private var image: NSImage?
    @State private var failed = false
    @State private var slow = false
    @Environment(\.displayScale) private var displayScale

    private var attachment: Attachment { message.attachments[index] }

    var body: some View {
        let att = attachment
        let token = model.attachmentToken(message, index)
        let px = Int(maxSide * max(displayScale, 2))
        let image = self.image ?? model.cachedDisplayImage(att, maxPixel: px)
        let size = AppModel.mediaFrame(width: image.map { Int($0.size.width) } ?? att.width,
                                       height: image.map { Int($0.size.height) } ?? att.height, maxSide: maxSide)
        ZStack {
            if att.isGif, let data = model.animatedGifs[token] {
                AnimatedImage(data: data)
            } else if let image {
                Image(nsImage: image).resizable().interpolation(.high).aspectRatio(contentMode: .fill)
            } else {
                Rectangle().fill(Theme.field)
                if failed {
                    Image(systemName: "photo").font(.title2).foregroundStyle(.secondary)
                } else if slow {
                    ProgressView().controlSize(.small) // only for a slow load: no spinner blinking past
                }
            }
        }
        .frame(width: size.width, height: size.height)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .contentShape(Rectangle())
        .onTapGesture { model.openMediaViewer(message, index) }
        .task(id: "\(token)|\(px)") {
            if att.isGif { model.loadAnimatedGif(message, index) }
            if self.image != nil { return }
            let spinner = Task { try? await Task.sleep(for: .milliseconds(400)); if !Task.isCancelled { slow = true } }
            defer { spinner.cancel() }
            if let img = await model.displayImage(conversation, att, maxPixel: px, message: message, index: index) {
                self.image = img
            } else {
                failed = true
            }
        }
        .help(att.filename)
    }
}
