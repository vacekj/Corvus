import Foundation

/// What the media gallery of one conversation lists, newest first (built once, off the main thread).
public struct MediaGallery {
    public struct Item: Identifiable {
        public var message: Message
        public var index: Int
        public var id: String { "\(message.id)#\(index)" }
        public var attachment: Attachment { message.attachments[index] }
    }

    public struct LinkItem: Identifiable {
        public var url: URL
        public var message: Message
        public var id: String { message.id + url.absoluteString }
    }

    public var media: [Item] = []
    public var audio: [Item] = []
    public var files: [Item] = []
    public var links: [LinkItem] = []

    public init() {}

    /// Deleted and View Once messages and stickers are left out.
    public init(_ msgs: [Message]) {
        for m in msgs.reversed() where !m.deleted && !m.viewOnce {
            for i in m.attachments.indices where !m.attachments[i].isSticker {
                let a = m.attachments[i], it = Item(message: m, index: i)
                if a.isImage || a.isVideo { media.append(it) } else if a.isAudio { audio.append(it) } else { files.append(it) }
            }
            links += MediaGallery.links(in: m.text).map { LinkItem(url: $0, message: m) }
        }
    }

    private static let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)

    /// http(s) links in a message text.
    public static func links(in text: String) -> [URL] {
        guard !text.isEmpty, let detector else { return [] }
        return detector.matches(in: text, range: NSRange(location: 0, length: (text as NSString).length)).compactMap { m in
            guard let u = m.url, ["http", "https"].contains(u.scheme?.lowercased() ?? "") else { return nil }
            return u
        }
    }
}
