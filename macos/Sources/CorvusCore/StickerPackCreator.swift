import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Building a sticker pack for `uploadStickerPack`: Signal's rules for the images, the conversion of picked
/// files to them, and the manifest.json signal-cli reads (title, author, cover, stickers with file, emoji and
/// content type).
public enum StickerRules {
    /// Every sticker is a square of this size (Signal's sticker creator rejects anything else).
    public static let side = 512
    public static let maxBytes = 300 * 1024
    public static let maxStickers = 200
    /// Animated stickers may run for at most this long (one loop).
    public static let maxAnimationSeconds = 3.0
    public static let maxTitleLength = 40
    public static let maxAuthorLength = 40

    /// File types the picker accepts.
    public static let inputTypes: [UTType] = [.png, .webP, .gif, .jpeg, .heic]

    /// Where an image of `size` goes on the square canvas: scaled to fit (never up past the canvas), centered.
    public static func fitRect(_ size: CGSize, side: Int = side) -> CGRect {
        let s = CGFloat(side)
        guard size.width > 0, size.height > 0 else { return CGRect(x: 0, y: 0, width: s, height: s) }
        let scale = min(s / size.width, s / size.height)
        let w = (size.width * scale).rounded(), h = (size.height * scale).rounded()
        return CGRect(x: ((s - w) / 2).rounded(.down), y: ((s - h) / 2).rounded(.down), width: w, height: h)
    }
}

/// One sticker of the pack being created.
public struct StickerDraft: Equatable {
    public var file: String          // name inside the pack directory, e.g. "3.png"
    public var emoji: String
    public var animated: Bool

    public init(file: String, emoji: String, animated: Bool = false) {
        self.file = file
        self.emoji = emoji
        self.animated = animated
    }
}

public struct StickerManifest: Equatable {
    public var title: String
    public var author: String
    public var stickers: [StickerDraft]
    /// Index into `stickers` of the cover (Signal shows it in the sticker picker's tab).
    public var cover: Int

    public init(title: String, author: String, stickers: [StickerDraft], cover: Int = 0) {
        self.title = title
        self.author = author
        self.stickers = stickers
        self.cover = cover
    }

    /// What is missing before the pack can be uploaded, or nil.
    public var problem: String? {
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let a = author.trimmingCharacters(in: .whitespacesAndNewlines)
        if stickers.isEmpty { return "Add at least one sticker." }
        if stickers.count > StickerRules.maxStickers { return "A pack can have at most \(StickerRules.maxStickers) stickers." }
        if stickers.contains(where: { $0.emoji.trimmingCharacters(in: .whitespaces).isEmpty }) {
            return "Choose an emoji for every sticker."
        }
        if t.isEmpty { return "Enter a title." }
        if a.isEmpty { return "Enter an author." }
        if t.count > StickerRules.maxTitleLength { return "The title can have at most \(StickerRules.maxTitleLength) characters." }
        if a.count > StickerRules.maxAuthorLength { return "The author can have at most \(StickerRules.maxAuthorLength) characters." }
        return nil
    }

    private static func entry(_ s: StickerDraft) -> JSON {
        ["file": s.file, "emoji": s.emoji.trimmingCharacters(in: .whitespaces), "contentType": "image/png"]
    }

    /// The manifest.json signal-cli's `uploadStickerPack` reads.
    public var json: JSON {
        var o: JSON = [
            "title": title.trimmingCharacters(in: .whitespacesAndNewlines),
            "author": author.trimmingCharacters(in: .whitespacesAndNewlines),
            "stickers": stickers.map(Self.entry),
        ]
        if stickers.indices.contains(cover) { o["cover"] = Self.entry(stickers[cover]) }
        return o
    }

    public func data() throws -> Data {
        try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys])
    }
}

/// The link `uploadStickerPack` answers with (`{"url": "https://signal.art/addstickers/#pack_id=…&pack_key=…"}`).
public enum StickerUploadResult {
    public static func link(_ result: Any?) -> StickerPackLink? {
        if let s = result as? String { return StickerPackLink.find(in: s) }
        return StickerPackLink.find(in: jsonString(jsonObject(result)["url"]))
    }
}

public enum StickerImageError: Error, LocalizedError, Equatable {
    case unreadable
    case tooLong(seconds: Double)
    case tooLarge(bytes: Int)

    public var errorDescription: String? {
        switch self {
        case .unreadable: "This file is not an image Corvus can read."
        case .tooLong(let s): String(format: "Animated stickers can be at most 3 seconds long (this one is %.1f s).", s)
        case .tooLarge(let b): "This sticker stays larger than 300 KB (\(b / 1024) KB) even after reducing its colours and size."
        }
    }
}

/// Converts a picked image (PNG, APNG, WebP, GIF, JPEG, HEIC) to a 512×512 PNG (APNG when animated) of at most
/// 300 KB. Pictures are scaled to fit with a transparent margin. When the PNG is too large, its colours are
/// reduced step by step (and animations lose every other frame) until it fits.
public enum StickerImageConverter {
    public struct Output: Equatable {
        public var data: Data
        public var animated: Bool
    }

    struct Frame {
        var image: CGImage
        var delay: Double
    }

    /// (content scale, bits per channel), tried in order until the PNG is small enough.
    static let attempts: [(CGFloat, Int)] = [(1, 8), (1, 6), (1, 5), (1, 4), (1, 3), (0.8, 3), (0.8, 2), (0.6, 2)]

    public static func convert(_ input: Data, maxBytes: Int = StickerRules.maxBytes) throws -> Output {
        guard let src = CGImageSourceCreateWithData(input as CFData, nil), CGImageSourceGetCount(src) > 0 else {
            throw StickerImageError.unreadable
        }
        var frames: [Frame] = []
        let count = CGImageSourceGetCount(src)
        for i in 0..<count {
            guard let img = CGImageSourceCreateImageAtIndex(src, i, nil) else { continue }
            frames.append(Frame(image: img, delay: count > 1 ? delay(src, i) : 0))
        }
        guard !frames.isEmpty else { throw StickerImageError.unreadable }
        let animated = frames.count > 1
        if animated {
            let total = frames.reduce(0) { $0 + $1.delay }
            if total > StickerRules.maxAnimationSeconds + 0.05 { throw StickerImageError.tooLong(seconds: total) }
        }
        var last = 0
        var canvases: [CGFloat: [Frame]] = [:]
        // Full colour first, then fewer bits per channel; animations also drop every other frame. As a last
        // resort the picture gets a wider transparent margin inside the 512×512 canvas.
        for (scale, bits) in attempts {
            if canvases[scale] == nil {
                canvases[scale] = try frames.map { f -> Frame in
                    guard let c = render(f.image, scale: scale) else { throw StickerImageError.unreadable }
                    return Frame(image: c, delay: f.delay)
                }
            }
            let base = canvases[scale]!
            var set = bits == 8 ? base : base.compactMap { f in quantize(f.image, bits: bits).map { Frame(image: $0, delay: f.delay) } }
            for pass in 0..<(animated ? 3 : 1) {
                if pass > 0 { set = halve(set) }
                guard let data = encode(set) else { throw StickerImageError.unreadable }
                if data.count <= maxBytes { return Output(data: data, animated: set.count > 1) }
                last = data.count
                if set.count <= 1 { break }
            }
        }
        throw StickerImageError.tooLarge(bytes: last)
    }

    /// Frame duration in seconds (GIF, APNG or WebP); browsers treat very short delays as 0.1 s.
    static func delay(_ src: CGImageSource, _ i: Int) -> Double {
        guard let props = CGImageSourceCopyPropertiesAtIndex(src, i, nil) as? [CFString: Any] else { return 0.1 }
        let dicts: [(CFString, CFString, CFString)] = [
            (kCGImagePropertyGIFDictionary, kCGImagePropertyGIFUnclampedDelayTime, kCGImagePropertyGIFDelayTime),
            (kCGImagePropertyPNGDictionary, kCGImagePropertyAPNGUnclampedDelayTime, kCGImagePropertyAPNGDelayTime),
            (kCGImagePropertyWebPDictionary, kCGImagePropertyWebPUnclampedDelayTime, kCGImagePropertyWebPDelayTime),
        ]
        for (dict, unclamped, clamped) in dicts {
            guard let d = props[dict] as? [CFString: Any] else { continue }
            let v = (d[unclamped] as? Double) ?? (d[clamped] as? Double) ?? 0
            return v < 0.02 ? 0.1 : v
        }
        return 0.1
    }

    /// The image scaled to fit a transparent 512×512 canvas (`scale` < 1 leaves a wider margin).
    static func render(_ image: CGImage, scale: CGFloat = 1) -> CGImage? {
        let side = StickerRules.side
        guard let ctx = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.interpolationQuality = .high
        ctx.clear(CGRect(x: 0, y: 0, width: side, height: side))
        let r = StickerRules.fitRect(CGSize(width: image.width, height: image.height))
        ctx.draw(image, in: r.insetBy(dx: (r.width * (1 - scale) / 2).rounded(), dy: (r.height * (1 - scale) / 2).rounded()))
        return ctx.makeImage()
    }

    /// Keeps the top `bits` of every channel (rounded), which makes the PNG compress much better.
    static func quantize(_ image: CGImage, bits: Int) -> CGImage? {
        let w = image.width, h = image.height
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let base = ctx.data else { return nil }
        let p = base.bindMemory(to: UInt8.self, capacity: w * h * 4)
        let step = 1 << (8 - bits)
        var table = [UInt8](repeating: 0, count: 256)
        for v in 0..<256 { table[v] = UInt8(min(255, (v + step / 2) / step * step)) }
        for i in 0..<(w * h * 4) { p[i] = table[Int(p[i])] }
        // Premultiplied colour must not exceed alpha.
        for i in stride(from: 0, to: w * h * 4, by: 4) {
            let a = p[i + 3]
            if p[i] > a { p[i] = a }
            if p[i + 1] > a { p[i + 1] = a }
            if p[i + 2] > a { p[i + 2] = a }
        }
        return ctx.makeImage()
    }

    /// Every other frame, each shown twice as long.
    static func halve(_ frames: [Frame]) -> [Frame] {
        guard frames.count > 1 else { return frames }
        return stride(from: 0, to: frames.count, by: 2).map { i in
            Frame(image: frames[i].image, delay: frames[i].delay + (i + 1 < frames.count ? frames[i + 1].delay : 0))
        }
    }

    /// PNG, or APNG (looping forever) when there is more than one frame.
    static func encode(_ frames: [Frame]) -> Data? {
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, UTType.png.identifier as CFString, frames.count, nil) else {
            return nil
        }
        if frames.count > 1 {
            CGImageDestinationSetProperties(dest, [kCGImagePropertyPNGDictionary: [kCGImagePropertyAPNGLoopCount: 0]] as CFDictionary)
        }
        for f in frames {
            let props: [CFString: Any] = frames.count > 1
                ? [kCGImagePropertyPNGDictionary: [kCGImagePropertyAPNGDelayTime: f.delay]] : [:]
            CGImageDestinationAddImage(dest, f.image, props as CFDictionary)
        }
        guard CGImageDestinationFinalize(dest) else { return nil }
        return out as Data
    }
}
