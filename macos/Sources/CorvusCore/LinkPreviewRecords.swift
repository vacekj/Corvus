import Foundation

/// History records and signal-cli envelope parsing of link previews. The "lp" extra uses exactly the keys of
/// linkPreviewToJson / linkPreviewFromJson in src/Records.cpp: u url, t title, d description, id image
/// attachment id, ct content type, fn file name, sz size, th base64 thumbnail.
extension Records {
    static func linkPreviewToJson(_ lp: LinkPreview) -> JSON {
        var o: JSON = [:]
        if !lp.url.isEmpty { o["u"] = lp.url }
        if !lp.title.isEmpty { o["t"] = lp.title }
        if !lp.description.isEmpty { o["d"] = lp.description }
        if !lp.imageId.isEmpty { o["id"] = lp.imageId }
        if !lp.imageContentType.isEmpty { o["ct"] = lp.imageContentType }
        if !lp.imageFilename.isEmpty { o["fn"] = lp.imageFilename }
        if lp.imageSize > 0 { o["sz"] = lp.imageSize }
        if !lp.imageThumb.isEmpty { o["th"] = lp.imageThumb.base64EncodedString() }
        return o
    }

    /// An empty or invalid object (the marker that removes a preview) gives an empty preview.
    static func linkPreviewFromJson(_ o: JSON) -> LinkPreview {
        var lp = LinkPreview()
        lp.url = jsonString(o["u"])
        lp.title = jsonString(o["t"])
        lp.description = jsonString(o["d"])
        lp.imageId = jsonString(o["id"])
        lp.imageContentType = jsonString(o["ct"])
        lp.imageFilename = jsonString(o["fn"])
        lp.imageSize = jsonInt64(o["sz"])
        lp.imageThumb = Data(base64Encoded: jsonString(o["th"])) ?? Data()
        return lp.isValid ? lp : LinkPreview()
    }

    /// Stored extra of a message ("lp"), or nil when there is nothing to keep.
    static func linkPreviewExtra(_ m: Message) -> JSON? {
        m.linkPreview.isValid && !m.deleted ? linkPreviewToJson(m.linkPreview) : nil
    }

    /// The thumbnail arrived later: an "update" record that sets "lp"; ts = original timestamp.
    public static func linkPreviewUpdate(_ conv: String, _ m: Message) -> JSON {
        ["t": "u", "c": conv, "ts": m.ts, "au": m.authorKey, "d": ["lp": linkPreviewToJson(m.linkPreview)] as JSON]
    }
}

/// `dataMessage.previews`: [{"url", "title", "description", "image": {"id", "contentType", "filename", "size"}}].
/// The first valid https preview wins; the image is only a reference (fetched later with getAttachment).
func parseLinkPreview(_ dm: JSON) -> LinkPreview {
    for v in jsonArray(dm["previews"]) {
        let o = jsonObject(v)
        var lp = LinkPreview()
        lp.url = jsonString(o["url"])
        lp.title = jsonString(o["title"])
        lp.description = jsonString(o["description"])
        let image = jsonObject(o["image"])
        lp.imageId = jsonString(image["id"])
        lp.imageContentType = jsonString(image["contentType"])
        lp.imageFilename = jsonString(image["filename"])
        lp.imageSize = jsonInt64(image["size"])
        if lp.isValid { return lp }
    }
    return LinkPreview()
}
