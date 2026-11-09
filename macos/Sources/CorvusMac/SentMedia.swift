import CorvusCore
import Foundation
import ImageIO
import UniformTypeIdentifiers

extension Media {
    /// Applies Settings → Sent media quality to staged attachments (copies in `dir`): with Standard, large
    /// pictures are scaled to 1600 px and re-encoded (which also drops their metadata, e.g. the location).
    /// Returns the paths to send; files that are left alone keep their path.
    static func prepareForSending(_ paths: [String], in dir: URL, quality: SentMediaQuality = .load()) async -> [String] {
        guard quality == .standard else { return paths }
        return await Task.detached(priority: .userInitiated) {
            paths.enumerated().map { i, path in downsized(path, index: i, in: dir, quality: quality) ?? path }
        }.value
    }

    /// The re-encoded copy of one picture, nil when it is sent as it is.
    nonisolated static func downsized(_ path: String, index: Int, in dir: URL, quality: SentMediaQuality) -> String? {
        let mime = mimeType(forFile: path)
        guard mime.hasPrefix("image/"), let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              let w = props[kCGImagePropertyPixelWidth] as? Int, let h = props[kCGImagePropertyPixelHeight] as? Int else { return nil }
        let bytes = ((try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? NSNumber)?.int64Value ?? 0
        let alpha = props[kCGImagePropertyHasAlpha] as? Bool ?? false
        let plan = quality.plan(contentType: mime, width: w, height: h, bytes: bytes, hasAlpha: alpha,
                                animated: CGImageSourceGetCount(src) > 1)
        guard case let .reencode(maxSide, png) = plan else { return nil }
        let opts: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                     kCGImageSourceCreateThumbnailWithTransform: true,
                                     kCGImageSourceThumbnailMaxPixelSize: maxSide]
        guard let img = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { return nil }
        let name = ((path as NSString).lastPathComponent as NSString).deletingPathExtension
        let target = dir.appendingPathComponent("q\(index)", isDirectory: true)
            .appendingPathComponent((name.isEmpty ? "image" : name) + (png ? ".png" : ".jpg"))
        do { try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true) } catch {
            return nil
        }
        let type = (png ? UTType.png : UTType.jpeg).identifier as CFString
        guard let dest = CGImageDestinationCreateWithURL(target as CFURL, type, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, img, png ? nil : [kCGImageDestinationLossyCompressionQuality: SentMediaQuality.jpegQuality] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        // A staged copy is no longer needed (never the user's own file outside the staging folder).
        if path.hasPrefix(dir.path + "/") { try? FileManager.default.removeItem(atPath: path) }
        return target.path
    }
}
