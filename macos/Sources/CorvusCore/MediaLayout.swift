import CoreGraphics
import Foundation
import UniformTypeIdentifiers

// UI-free media rules: album grids, viewer zoom steps, voice note waveforms and queueing,
// the quality of sent pictures and the icon kind of a file attachment.

// MARK: - Albums

/// Tiles of a message with several pictures / videos, like Signal Desktop's image grid:
/// 2 side by side, 3 = one big and two stacked, 4 = 2×2, 5+ = two on top and three below ("+N" on the last).
/// The geometry depends only on the count, the bubble width and the stored pixel sizes, so a bubble never
/// changes its size when the pictures are decoded.
public struct AlbumLayout: Equatable {
    public var tiles: [CGRect]
    public var size: CGSize
    /// Items not shown; drawn as "+N" over the last tile.
    public var overflow: Int

    public static let maxTiles = 5

    /// `aspects`: height / width of each item (nil or ≤ 0 when unknown).
    public static func make(aspects: [Double?], width w: CGFloat, spacing s: CGFloat = 2) -> AlbumLayout {
        let n = aspects.count
        guard n > 0 else { return AlbumLayout(tiles: [], size: .zero, overflow: 0) }
        func aspect(_ i: Int) -> CGFloat {
            guard i < aspects.count, let a = aspects[i], a > 0, a.isFinite else { return 1 }
            return CGFloat(a)
        }
        switch n {
        case 1:
            let h = (w * min(max(aspect(0), 0.5), 1.5)).rounded()
            return AlbumLayout(tiles: [CGRect(x: 0, y: 0, width: w, height: h)], size: CGSize(width: w, height: h), overflow: 0)
        case 2:
            let tw = ((w - s) / 2).rounded(.down)
            // Two portraits get taller tiles, two landscapes flatter ones; never extreme.
            let a = min(max(min(aspect(0), aspect(1)), 0.75), 1.33)
            let h = (tw * a).rounded()
            return AlbumLayout(tiles: [CGRect(x: 0, y: 0, width: tw, height: h),
                                       CGRect(x: w - tw, y: 0, width: tw, height: h)],
                               size: CGSize(width: w, height: h), overflow: 0)
        case 3:
            let small = ((w - s) / 3).rounded(.down)
            let big = w - s - small
            let half = ((big - s) / 2).rounded(.down)
            return AlbumLayout(tiles: [CGRect(x: 0, y: 0, width: big, height: big),
                                       CGRect(x: big + s, y: 0, width: small, height: half),
                                       CGRect(x: big + s, y: big - half, width: small, height: half)],
                               size: CGSize(width: w, height: big), overflow: 0)
        case 4:
            let t = ((w - s) / 2).rounded(.down)
            return AlbumLayout(tiles: [CGRect(x: 0, y: 0, width: t, height: t), CGRect(x: w - t, y: 0, width: t, height: t),
                                       CGRect(x: 0, y: t + s, width: t, height: t), CGRect(x: w - t, y: t + s, width: t, height: t)],
                               size: CGSize(width: w, height: t * 2 + s), overflow: 0)
        default:
            let top = ((w - s) / 2).rounded(.down)
            let bottom = ((w - 2 * s) / 3).rounded(.down)
            let y = top + s
            return AlbumLayout(tiles: [CGRect(x: 0, y: 0, width: top, height: top),
                                       CGRect(x: w - top, y: 0, width: top, height: top),
                                       CGRect(x: 0, y: y, width: bottom, height: bottom),
                                       CGRect(x: ((w - bottom) / 2).rounded(), y: y, width: bottom, height: bottom),
                                       CGRect(x: w - bottom, y: y, width: bottom, height: bottom)],
                               size: CGSize(width: w, height: y + bottom), overflow: n - maxTiles)
        }
    }
}

extension Attachment {
    /// Pictures and videos that go into an album (stickers stay on their own).
    public var isAlbumMedia: Bool { (isImage && !isSticker) || isVideo }

    /// Height / width from the stored pixel size, nil when unknown.
    public var aspect: Double? { width > 0 && height > 0 ? Double(height) / Double(width) : nil }
}

// MARK: - Viewer zoom

/// Zoom levels of the media viewer (1 = one image pixel per point).
public enum ViewerZoom {
    public static let maxScale: CGFloat = 8
    public static let steps: [CGFloat] = [0.1, 0.25, 0.5, 0.75, 1, 1.5, 2, 3, 4, 6, 8]

    /// Scale that shows the whole image; small images are not enlarged.
    public static func fit(image: CGSize, in viewport: CGSize) -> CGFloat {
        guard image.width > 0, image.height > 0, viewport.width > 0, viewport.height > 0 else { return 1 }
        return min(1, viewport.width / image.width, viewport.height / image.height)
    }

    public static func minScale(fit: CGFloat) -> CGFloat { min(fit, 1) * 0.5 }

    /// Double-click: fitted → 100 % (or 200 % for a small image that is already shown at 100 %), else back to fit.
    public static func toggled(current: CGFloat, fit: CGFloat) -> CGFloat {
        let atFit = abs(current - fit) < 0.01
        if !atFit { return fit }
        return fit < 0.99 ? 1 : 2
    }

    /// ⌘+ / ⌘−: the next step up or down (the fitted scale counts as a step too).
    public static func step(current: CGFloat, fit: CGFloat, zoomIn: Bool) -> CGFloat {
        let all = Set(steps + [fit]).sorted()
        let lo = minScale(fit: fit)
        if zoomIn {
            return min(maxScale, all.first { $0 > current + 0.001 } ?? maxScale)
        }
        return max(lo, all.last { $0 < current - 0.001 } ?? lo)
    }
}

// MARK: - Viewer navigation

public struct MediaRef: Hashable {
    public var messageId: String
    public var index: Int
    public init(messageId: String, index: Int) {
        self.messageId = messageId
        self.index = index
    }
}

public enum MediaViewerList {
    /// Pictures and videos of a conversation in timeline order (what ← → move through in the viewer).
    public static func refs(_ msgs: [Message]) -> [MediaRef] {
        var out: [MediaRef] = []
        for m in msgs where !m.deleted && !m.viewOnce {
            for i in m.attachments.indices where m.attachments[i].isAlbumMedia {
                out.append(MediaRef(messageId: m.id, index: i))
            }
        }
        return out
    }
}

// MARK: - Voice notes

public enum Waveform {
    public static let barCount = 42

    /// Reduces loudness values (one per short window, any scale) to `count` bars between 0.05 and 1.
    /// Bars are the peak of their bucket, scaled to the loudest bar, so quiet recordings still show a shape.
    public static func bars(_ values: [Float], count: Int = barCount) -> [Float] {
        guard count > 0 else { return [] }
        let clean = values.map { $0.isFinite ? abs($0) : 0 }
        guard !clean.isEmpty else { return Array(repeating: 0.05, count: count) }
        var out = [Float](repeating: 0, count: count)
        for b in 0..<count {
            let lo = b * clean.count / count
            let hi = max(lo + 1, (b + 1) * clean.count / count)
            var peak: Float = 0
            for i in lo..<min(hi, clean.count) where clean[i] > peak { peak = clean[i] }
            out[b] = peak
        }
        let top = out.max() ?? 0
        guard top > 0 else { return Array(repeating: 0.05, count: count) }
        return out.map { max(0.05, min(1, $0 / top)) }
    }

    /// Playback speeds offered for voice notes, in order of the speed button.
    public static let speeds: [Double] = [1, 1.5, 2]

    public static func nextSpeed(after s: Double) -> Double {
        guard let i = speeds.firstIndex(where: { abs($0 - s) < 0.01 }) else { return speeds[0] }
        return speeds[(i + 1) % speeds.count]
    }

    public static func speedLabel(_ s: Double) -> String {
        s == s.rounded() ? "\(Int(s))×" : String(format: "%.1f×", s)
    }

    /// "m:ss" of a duration in seconds.
    public static func time(_ s: Double) -> String {
        guard s.isFinite, s > 0 else { return "0:00" }
        let t = Int(s.rounded(.down))
        return String(format: "%d:%02d", t / 60, t % 60)
    }
}

public enum VoiceNoteQueue {
    /// The voice note that plays after the one in message `id` ends: the first audio attachment of the
    /// directly following message, if it has one (consecutive voice notes autoplay, like Signal).
    public static func next(after id: String, in msgs: [Message]) -> (message: Message, index: Int)? {
        guard let i = msgs.firstIndex(where: { $0.id == id }), i + 1 < msgs.count else { return nil }
        let m = msgs[i + 1]
        guard !m.deleted, !m.viewOnce, let a = m.attachments.firstIndex(where: \.isAudio) else { return nil }
        return (m, a)
    }
}

// MARK: - Sent media quality

public enum SentMediaQuality: String, CaseIterable {
    case standard, high

    public static let key = "media.sentQuality"
    public static let maxSide = 1600
    public static let jpegQuality = 0.75
    /// Small pictures within `maxSide` are still re-encoded above this size.
    public static let maxStandardBytes: Int64 = 1_000_000

    public static func load(_ d: UserDefaults = .standard) -> SentMediaQuality {
        d.string(forKey: key).flatMap(SentMediaQuality.init(rawValue:)) ?? .standard
    }

    public enum Plan: Equatable {
        case original
        /// Re-encode at most `maxSide` on the longer side; PNG keeps transparency, everything else becomes JPEG.
        case reencode(maxSide: Int, png: Bool)
    }

    /// What happens to a picture before it is sent.
    public func plan(contentType: String, width: Int, height: Int, bytes: Int64, hasAlpha: Bool, animated: Bool) -> Plan {
        let type = contentType.lowercased()
        guard self == .standard, type.hasPrefix("image/"), !animated, type != "image/gif", type != "image/svg+xml",
              width > 0, height > 0 else { return .original }
        let side = max(width, height)
        let foreign = type.contains("heic") || type.contains("heif") // not shown by every Signal client
        if side <= SentMediaQuality.maxSide && bytes <= SentMediaQuality.maxStandardBytes && !foreign { return .original }
        return .reencode(maxSide: min(side, SentMediaQuality.maxSide), png: hasAlpha)
    }
}

// MARK: - File icons

/// The kind of a file attachment, for its icon.
public enum FileKind: String, CaseIterable {
    case pdf, archive, audio, video, image, code, text, document, spreadsheet, presentation, generic

    private static let byExtension: [String: FileKind] = {
        var m: [String: FileKind] = ["pdf": .pdf]
        for e in ["zip", "rar", "7z", "tar", "gz", "tgz", "bz2", "xz", "zst", "lz", "lzma", "cab", "iso"] { m[e] = .archive }
        for e in ["mp3", "m4a", "aac", "wav", "flac", "ogg", "oga", "opus", "aiff", "aif", "wma", "amr"] { m[e] = .audio }
        for e in ["mp4", "mov", "m4v", "mkv", "avi", "webm", "wmv", "mpg", "mpeg", "3gp", "ogv"] { m[e] = .video }
        for e in ["jpg", "jpeg", "png", "gif", "heic", "heif", "webp", "tif", "tiff", "bmp", "svg", "raw", "dng"] { m[e] = .image }
        for e in ["swift", "c", "h", "cpp", "hpp", "cc", "m", "mm", "rs", "go", "java", "kt", "js", "ts", "tsx", "jsx",
                  "py", "rb", "php", "sh", "zsh", "bash", "json", "xml", "yaml", "yml", "toml", "html", "htm", "css",
                  "scss", "sql", "lua", "pl", "cs", "dart", "nix", "ini", "conf", "gradle", "plist"] { m[e] = .code }
        for e in ["txt", "md", "markdown", "rtf", "log", "tex", "srt", "vtt"] { m[e] = .text }
        for e in ["doc", "docx", "odt", "pages", "epub", "mobi"] { m[e] = .document }
        for e in ["xls", "xlsx", "ods", "numbers", "csv", "tsv"] { m[e] = .spreadsheet }
        for e in ["ppt", "pptx", "odp", "key"] { m[e] = .presentation }
        return m
    }()

    public static func of(filename: String, contentType: String) -> FileKind {
        let ext = fileExtension(filename)
        if let k = byExtension[ext] { return k }
        let t = contentType.lowercased()
        if t == "application/pdf" { return .pdf }
        if t.hasPrefix("audio/") { return .audio }
        if t.hasPrefix("video/") { return .video }
        if t.hasPrefix("image/") { return .image }
        if t.contains("zip") || t.contains("compressed") || t.contains("x-tar") || t.contains("gzip") { return .archive }
        if t.contains("spreadsheet") || t.contains("excel") { return .spreadsheet }
        if t.contains("presentation") || t.contains("powerpoint") { return .presentation }
        if t.contains("wordprocessing") || t.contains("msword") || t.contains("opendocument.text") { return .document }
        if t.contains("json") || t.contains("xml") || t.contains("javascript") { return .code }
        if t.hasPrefix("text/") { return .text }
        return .generic
    }

    /// Lowercased extension of a file name ("" without one).
    public static func fileExtension(_ filename: String) -> String {
        let name = (filename as NSString).lastPathComponent.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let dot = name.lastIndex(of: "."), dot != name.startIndex else { return "" }
        let ext = name[name.index(after: dot)...]
        guard !ext.isEmpty, ext.count <= 8, ext.allSatisfy({ $0.isLetter || $0.isNumber }) else { return "" }
        return ext.lowercased()
    }

    /// "PDF · 1.2 MB": upper-case extension and size, like the second line of a Signal Desktop file row.
    public static func detail(filename: String, contentType: String, size: Int64) -> String {
        var ext = fileExtension(filename).uppercased()
        if ext.isEmpty, let type = UTType(mimeType: contentType.split(separator: ";").first.map(String.init) ?? ""),
           let suffix = type.preferredFilenameExtension {
            ext = suffix.uppercased()
        }
        let s = size > 0 ? ByteCountFormatter.string(fromByteCount: size, countStyle: .file) : ""
        return [ext, s].filter { !$0.isEmpty }.joined(separator: " · ")
    }
}
