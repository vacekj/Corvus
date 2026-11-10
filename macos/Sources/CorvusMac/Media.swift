import AppKit
import ImageIO
import UniformTypeIdentifiers

enum Media {
    static let maxThumbSource: Int64 = 30 * 1024 * 1024
    static let maxAttachment: Int64 = 100 * 1024 * 1024 // Signal's upload limit

    static func mimeType(forFile path: String) -> String {
        let ext = (path as NSString).pathExtension
        return UTType(filenameExtension: ext)?.preferredMIMEType ?? "application/octet-stream"
    }

    static func preferredSuffix(forMime mime: String) -> String {
        UTType(mimeType: mime)?.preferredFilenameExtension ?? ""
    }

    static func humanSize(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    static func pixelSize(_ data: Data) -> (Int, Int)? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              let w = props[kCGImagePropertyPixelWidth] as? Int, let h = props[kCGImagePropertyPixelHeight] as? Int
        else { return nil }
        let orientation = props[kCGImagePropertyOrientation] as? Int ?? 1
        return orientation >= 5 ? (h, w) : (w, h)
    }

    /// JPEG/PNG preview with the longest side <= maxDim (orientation applied), as stored in the history.
    static func makeThumbnail(_ data: Data, maxDim: Int = 480) -> Data {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil) else { return Data() }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxDim,
        ]
        guard let img = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { return Data() }
        let hasAlpha: Bool = {
            switch img.alphaInfo {
            case .none, .noneSkipFirst, .noneSkipLast: return false
            default: return true
            }
        }()
        let out = NSMutableData()
        let type = (hasAlpha ? UTType.png : UTType.jpeg).identifier as CFString
        guard let dest = CGImageDestinationCreateWithData(out, type, 1, nil) else { return Data() }
        CGImageDestinationAddImage(dest, img, hasAlpha ? nil : [kCGImageDestinationLossyCompressionQuality: 0.82] as CFDictionary)
        return CGImageDestinationFinalize(dest) ? out as Data : Data()
    }

    /// Copies the files to send into a new folder in the temporary directory and returns the copies, so the
    /// backend reads a file that cannot change or move before it is sent.
    static func stageForBackend(_ paths: [String]) -> (paths: [String], dir: URL) {
        let dir = AppPaths.tempDir.appendingPathComponent("send-" + UUID().uuidString, isDirectory: true)
        let staged = paths.enumerated().map { i, path -> String in
            // One folder per file: the backend sends the file name along.
            let target = dir.appendingPathComponent("\(i)", isDirectory: true)
                .appendingPathComponent((path as NSString).lastPathComponent)
            do {
                try FileManager.default.createDirectory(at: target.deletingLastPathComponent(),
                                                        withIntermediateDirectories: true)
                try FileManager.default.copyItem(atPath: path, toPath: target.path)
                return target.path
            } catch {
                return path
            }
        }
        return (staged, dir)
    }

    /// Writes data to a fresh file in the temporary directory.
    static func writeTemp(_ data: Data, name: String) throws -> URL {
        let dir = AppPaths.tempDir.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(name.isEmpty ? "attachment" : name)
        try data.write(to: url)
        return url
    }

    /// Like `writeTemp`, for data received from others: the file is marked as downloaded (quarantine).
    static func writeAttachmentTemp(_ data: Data, name: String) throws -> URL {
        let url = try writeTemp(data, name: name)
        quarantine(url)
        return url
    }

    /// Sets the quarantine flag browsers set on downloads, so Gatekeeper checks the file (and anything
    /// unpacked from it) before it can run.
    static func quarantine(_ url: URL) {
        var u = url
        var values = URLResourceValues()
        values.quarantineProperties = [kLSQuarantineAgentNameKey as String: "Corvus",
                                       kLSQuarantineTypeKey as String: kLSQuarantineTypeOtherDownload as String]
        try? u.setResourceValues(values)
    }

    // MARK: Avatars

    /// Coloured circle with the first letter, like the official client shows without a picture.
    private static let placeholderCache: NSCache<NSString, NSImage> = { let c = NSCache<NSString, NSImage>(); c.countLimit = 2000; return c }()

    /// Same picture object for the same contact, so views don't redraw it on every update.
    static func placeholderAvatar(key: String, title: String, size: CGFloat = 64) -> NSImage {
        let ck = "\(key)|\(title)|\(size)" as NSString
        if let img = placeholderCache.object(forKey: ck) { return img }
        let img = drawPlaceholderAvatar(key: key, title: title, size: size)
        placeholderCache.setObject(img, forKey: ck)
        return img
    }

    private static func drawPlaceholderAvatar(key: String, title: String, size: CGFloat) -> NSImage {
        let letter = title.first(where: { $0.isLetter || $0.isNumber }).map { String($0).uppercased() } ?? "?"
        var hash: UInt32 = 2166136261
        for b in key.utf8 { hash = (hash ^ UInt32(b)) &* 16777619 }
        let hue = CGFloat(hash % 360) / 360
        return NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            NSColor(hue: hue, saturation: 0.45, brightness: 0.62, alpha: 1).setFill()
            NSBezierPath(ovalIn: rect).fill()
            let font = NSFont.boldSystemFont(ofSize: size * 0.5)
            let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.white]
            let s = NSAttributedString(string: letter, attributes: attrs)
            let sz = s.size()
            s.draw(at: NSPoint(x: rect.midX - sz.width / 2, y: rect.midY - sz.height / 2))
            return true
        }
    }

    /// Round avatar, cut from the centre of the picture.
    /// The picture cropped to a circle of `size` points. It is kept as a small JPEG (drawn once, at 2x) and
    /// decoded and clipped when the avatar is drawn: there are hundreds of avatars and a screenful is visible,
    /// so only those cost a decoded picture.
    static func roundAvatar(_ image: NSImage, size: CGFloat = 64) -> NSImage {
        let px = Int(size * 2)
        guard let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return image }
        let side = CGFloat(px)
        ctx.setFillColor(CGColor(gray: 1, alpha: 1)) // behind a picture with transparent parts
        ctx.fill(CGRect(x: 0, y: 0, width: side, height: side))
        ctx.interpolationQuality = .high
        let s = image.size
        let scale = max(side / max(s.width, 1), side / max(s.height, 1))
        let w = s.width * scale, h = s.height * scale
        let rect = CGRect(x: (side - w) / 2, y: (side - h) / 2, width: w, height: h)
        var proposed = rect
        guard let source = image.cgImage(forProposedRect: &proposed, context: nil, hints: nil) else { return image }
        ctx.draw(source, in: rect)
        let out = NSMutableData()
        guard let square = ctx.makeImage(),
              let dest = CGImageDestinationCreateWithData(out, "public.jpeg" as CFString, 1, nil) else { return image }
        CGImageDestinationAddImage(dest, square, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return image }
        let jpeg = Data(out) // exactly the bytes (the buffer written to has room to spare)
        return NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            guard let packed = CGImageSourceCreateWithData(jpeg as CFData, nil),
                  let picture = CGImageSourceCreateImageAtIndex(packed, 0, nil),
                  let target = NSGraphicsContext.current?.cgContext else { return false }
            target.addEllipse(in: rect)
            target.clip()
            target.interpolationQuality = .high
            target.draw(picture, in: rect)
            return true
        }
    }

    static func pngData(_ image: NSImage) -> Data? {
        guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }
}
