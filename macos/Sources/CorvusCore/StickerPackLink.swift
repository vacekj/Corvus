import Foundation

/// A Signal sticker pack link: https://signal.art/addstickers/#pack_id=<32 hex>&pack_key=<64 hex>
/// or sgnl://addstickers/?pack_id=…&pack_key=… . `find` picks the first one out of pasted text.
public struct StickerPackLink: Equatable {
    public var packId: String
    public var packKey: String

    public init(packId: String, packKey: String) {
        self.packId = packId
        self.packKey = packKey
    }

    /// The form signal-cli's `addStickerPack` accepts.
    public var uri: String { "https://signal.art/addstickers/#pack_id=\(packId)&pack_key=\(packKey)" }

    public static func parse(_ text: String) -> StickerPackLink? {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = t.lowercased()
        let params: Substring
        if lower.hasPrefix("https://signal.art/addstickers/") || lower.hasPrefix("http://signal.art/addstickers/") {
            guard let hash = t.firstIndex(of: "#") else { return nil }
            params = t[t.index(after: hash)...]
        } else if lower.hasPrefix("sgnl://addstickers/") {
            guard let q = t.firstIndex(of: "?") else { return nil }
            params = t[t.index(after: q)...]
        } else {
            return nil
        }
        var id = "", key = ""
        for pair in params.split(separator: "&") {
            let kv = pair.split(separator: "=", maxSplits: 1).map(String.init)
            guard kv.count == 2 else { continue }
            switch kv[0] {
            case "pack_id": id = kv[1].lowercased()
            case "pack_key": key = kv[1].lowercased()
            default: break
            }
        }
        guard isHex(id, length: 32), isHex(key, length: 64) else { return nil }
        return StickerPackLink(packId: id, packKey: key)
    }

    /// The first sticker pack link in `text` (for example a whole pasted message).
    public static func find(in text: String) -> StickerPackLink? {
        if let l = parse(text) { return l }
        for word in text.split(whereSeparator: { $0.isWhitespace || $0 == "<" || $0 == ">" || $0 == "\"" }) {
            if let l = parse(String(word)) { return l }
        }
        return nil
    }

    private static func isHex(_ s: String, length: Int) -> Bool {
        s.count == length && s.allSatisfy(\.isHexDigit)
    }
}
