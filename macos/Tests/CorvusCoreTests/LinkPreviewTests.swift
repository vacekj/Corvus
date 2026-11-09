import XCTest
@testable import CorvusCore

/// Link previews: envelope parsing, the "lp" history extra (same keys as the Qt app), draft helpers.
final class LinkPreviewTests: XCTestCase {
    private func envelope(_ dm: JSON) -> ParsedEnvelope {
        parseEnvelope(["sourceNumber": "+49111", "timestamp": 1, "dataMessage": dm])
    }

    private func sample() -> LinkPreview {
        var lp = LinkPreview()
        lp.url = "https://example.com/article"
        lp.title = "Example article"
        lp.description = "A short description"
        lp.imageId = "img-1"
        lp.imageContentType = "image/jpeg"
        lp.imageFilename = "p.jpg"
        lp.imageSize = 2048
        lp.imageThumb = Data([1, 2, 3, 4])
        return lp
    }

    // MARK: Parsing

    func testParsesIncomingPreview() {
        let pe = envelope([
            "timestamp": 5, "message": "look https://example.com/article",
            "previews": [[
                "url": "https://example.com/article", "title": "Example article", "description": "A short description",
                "image": ["id": "img-1", "contentType": "image/jpeg", "filename": "p.jpg", "size": 2048],
            ] as JSON],
        ])
        XCTAssertEqual(pe.kind, .message)
        let lp = pe.msg.linkPreview
        XCTAssertTrue(lp.isValid)
        XCTAssertEqual(lp.url, "https://example.com/article")
        XCTAssertEqual(lp.title, "Example article")
        XCTAssertEqual(lp.description, "A short description")
        XCTAssertEqual(lp.imageId, "img-1")
        XCTAssertEqual(lp.imageContentType, "image/jpeg")
        XCTAssertEqual(lp.imageSize, 2048)
        XCTAssertTrue(lp.imageThumb.isEmpty) // fetched later through signal-cli, never from the site
        XCTAssertEqual(lp.host, "example.com")
    }

    func testRejectsNonHttpsAndTitlelessPreviews() {
        let http = envelope(["timestamp": 5, "message": "x", "previews": [["url": "http://example.com/", "title": "T"] as JSON]])
        XCTAssertFalse(http.msg.linkPreview.isValid)
        XCTAssertTrue(http.msg.linkPreview.title.isEmpty)
        let js = envelope(["timestamp": 5, "message": "x", "previews": [["url": "javascript:alert(1)", "title": "T"] as JSON]])
        XCTAssertFalse(js.msg.linkPreview.isValid)
        let noTitle = envelope(["timestamp": 5, "message": "x", "previews": [["url": "https://example.com/", "title": " "] as JSON]])
        XCTAssertFalse(noTitle.msg.linkPreview.isValid)
        // the first valid preview wins
        let two = envelope(["timestamp": 5, "message": "x", "previews": [
            ["url": "http://bad.example.com/", "title": "Bad"] as JSON, ["url": "https://example.com/", "title": "Good"] as JSON]])
        XCTAssertEqual(two.msg.linkPreview.title, "Good")
    }

    func testViewOnceAndSyncedMessages() {
        let once = envelope(["timestamp": 5, "message": "x", "viewOnce": true,
                             "previews": [["url": "https://example.com/", "title": "T"] as JSON]])
        XCTAssertTrue(once.msg.viewOnce)
        XCTAssertFalse(once.msg.linkPreview.isValid)
        let sync = parseEnvelope(["sourceNumber": "+49me", "syncMessage": ["sentMessage": [
            "destinationNumber": "+49111", "timestamp": 6, "message": "https://example.com/",
            "previews": [["url": "https://example.com/", "title": "Mine"] as JSON],
        ] as JSON]])
        XCTAssertTrue(sync.outgoing)
        XCTAssertEqual(sync.msg.linkPreview.title, "Mine")
    }

    func testOpenURLOnlyHttp() {
        var lp = sample()
        XCTAssertEqual(lp.openURL?.absoluteString, "https://example.com/article")
        lp.url = "file:///etc/passwd"
        XCTAssertNil(lp.openURL)
        XCTAssertFalse(lp.isValid)
    }

    // MARK: Records

    func testRecordRoundTripUsesQtKeys() throws {
        var m = Message()
        m.ts = 100
        m.text = "https://example.com/article"
        m.authorKey = "+49111"
        m.linkPreview = sample()
        let rec = Records.message("+49111", m)
        let lp = try XCTUnwrap(jsonObject(rec["d"])["lp"] as? JSON)
        XCTAssertEqual(Set(lp.keys), ["u", "t", "d", "id", "ct", "fn", "sz", "th"])
        XCTAssertEqual(jsonString(lp["u"]), "https://example.com/article")
        XCTAssertEqual(jsonString(lp["t"]), "Example article")
        XCTAssertEqual(jsonString(lp["d"]), "A short description")
        XCTAssertEqual(jsonString(lp["id"]), "img-1")
        XCTAssertEqual(jsonString(lp["ct"]), "image/jpeg")
        XCTAssertEqual(jsonString(lp["fn"]), "p.jpg")
        XCTAssertEqual(jsonInt64(lp["sz"]), 2048)
        XCTAssertEqual(jsonString(lp["th"]), Data([1, 2, 3, 4]).base64EncodedString())

        // survives the JSON the history store keeps
        let data = try JSONSerialization.data(withJSONObject: rec)
        let back = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? JSON)
        XCTAssertEqual(Records.messageFromRecord(back).linkPreview, m.linkPreview)
    }

    func testReadsAPreviewWrittenByTheQtApp() {
        let rec: JSON = ["t": "m", "c": "+49111", "ts": 7, "s": "A", "x": "see https://example.org/a", "o": false, "au": "+49111",
                         "d": ["lp": ["u": "https://example.org/a", "t": "Title", "d": "Desc", "id": "x", "ct": "image/png",
                                      "sz": 99, "th": "AQID"] as JSON] as JSON]
        let lp = Records.messageFromRecord(rec).linkPreview
        XCTAssertEqual(lp.url, "https://example.org/a")
        XCTAssertEqual(lp.title, "Title")
        XCTAssertEqual(lp.imageSize, 99)
        XCTAssertEqual(lp.imageThumb, Data([1, 2, 3]))
        XCTAssertEqual(lp.imageFilename, "")
    }

    func testMessageWithoutPreviewAndDeletedMessageStoreNoExtra() {
        var m = Message()
        m.ts = 1
        XCTAssertNil(jsonObject(Records.message("c", m)["d"])["lp"])
        m.linkPreview = sample()
        m.markDeleted()
        XCTAssertNil(jsonObject(Records.message("c", m)["d"])["lp"])
        XCTAssertFalse(m.linkPreview.isValid)
        // an invalid preview is not stored either
        var bad = Message()
        bad.linkPreview.url = "http://example.com/"
        bad.linkPreview.title = "T"
        XCTAssertNil(jsonObject(Records.message("c", bad)["d"])["lp"])
    }

    func testThumbnailUpdateRecord() {
        var m = Message()
        m.ts = 100
        m.authorKey = "+49111"
        m.text = "hi https://example.com/article"
        var lp = sample()
        lp.imageThumb = Data()
        m.linkPreview = lp
        var s = ChatState()
        s.account = "+49me"
        var records = s.addMessage("+49111", m)!.records
        XCTAssertTrue(s.convs["+49111"]!.msgs[0].linkPreview.imageThumb.isEmpty)

        var updated = s.convs["+49111"]!.msgs[0]
        updated.linkPreview.imageThumb = Data([9, 9])
        let update = Records.linkPreviewUpdate("+49111", updated)
        XCTAssertEqual(jsonString(update["t"]), "u") // never a new record type
        XCTAssertEqual(Set(update.keys), ["t", "c", "ts", "au", "d"])
        records.append(update)

        var reloaded = ChatState()
        reloaded.account = "+49me"
        reloaded.loadHistory(records)
        let restored = reloaded.convs["+49111"]!.msgs[0].linkPreview
        XCTAssertEqual(restored.imageThumb, Data([9, 9]))
        XCTAssertEqual(restored.title, "Example article")
        XCTAssertEqual(restored.imageId, "img-1")
    }

    func testEditClearsPreview() {
        var m = Message()
        m.ts = 100
        m.outgoing = true
        m.authorKey = "+49me"
        m.text = "https://example.com/article"
        m.linkPreview = sample()
        var s = ChatState()
        s.account = "+49me"
        var records = s.addMessage("+49111", m)!.records
        let edit = s.applyEdit("+49111", targetTs: 100, authors: ["+49me"], text: "no link now", newTs: 200)!
        XCTAssertEqual((jsonObject(edit["d"])["lp"] as? JSON)?.count, 0) // empty object: same marker as the Qt app
        XCTAssertFalse(s.convs["+49111"]!.msgs[0].linkPreview.isValid)
        records.append(edit)

        var reloaded = ChatState()
        reloaded.account = "+49me"
        reloaded.loadHistory(records)
        XCTAssertEqual(reloaded.convs["+49111"]!.msgs[0].text, "no link now")
        XCTAssertFalse(reloaded.convs["+49111"]!.msgs[0].linkPreview.isValid)
    }

    func testEditKeepsPreviewSentWithIt() {
        var m = Message()
        m.ts = 100
        m.outgoing = true
        m.authorKey = "+49me"
        m.text = "https://example.com/article"
        m.linkPreview = sample()
        var s = ChatState()
        s.account = "+49me"
        var records = s.addMessage("+49111", m)!.records
        records.append(s.applyEdit("+49111", targetTs: 100, authors: ["+49me"], text: "see https://example.com/article",
                                   newTs: 200, linkPreview: sample())!)
        XCTAssertTrue(s.convs["+49111"]!.msgs[0].linkPreview.isValid)

        var reloaded = ChatState()
        reloaded.account = "+49me"
        reloaded.loadHistory(records)
        XCTAssertEqual(reloaded.convs["+49111"]!.msgs[0].text, "see https://example.com/article")
        XCTAssertEqual(reloaded.convs["+49111"]!.msgs[0].linkPreview.url, sample().url)
    }

    func testPreviewSurvivesCompaction() {
        var m = Message()
        m.ts = 100
        m.authorKey = "+49111"
        m.text = "hi https://example.com/article"
        m.linkPreview = sample()
        var s = ChatState()
        s.account = "+49me"
        _ = s.addMessage("+49111", m)
        var reloaded = ChatState()
        reloaded.account = "+49me"
        reloaded.loadHistory(s.allRecords())
        XCTAssertEqual(reloaded.convs["+49111"]!.msgs[0].linkPreview, sample())
    }

    func testPreviewRecordsAreAcceptedByTheRustStore() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("history.corvus").path

        var m = Message()
        m.ts = 1_700_000_000_000
        m.text = "https://example.com/article"
        m.authorKey = "+49111"
        m.linkPreview = sample()
        var thumb = m
        thumb.linkPreview.imageThumb = Data([7, 7, 7])
        let records = [Records.message("+49111", m), Records.linkPreviewUpdate("+49111", thumb)]

        let store = HistoryStore()
        try store.create(path: path, passphrase: "pw")
        for r in records { try store.append(r) }
        store.close()
        var s = ChatState()
        s.loadHistory(try HistoryStore().open(path: path, passphrase: "pw"))
        XCTAssertEqual(s.convs["+49111"]!.msgs[0].linkPreview, thumb.linkPreview)
    }

    // MARK: Generating previews

    func testFirstHttpsLink() {
        XCTAssertEqual(LinkPreviews.firstHttpsLink(in: "see https://example.com/a?b=1, ok"), "https://example.com/a?b=1")
        XCTAssertEqual(LinkPreviews.firstHttpsLink(in: "(https://example.com/x)"), "https://example.com/x")
        XCTAssertEqual(LinkPreviews.firstHttpsLink(in: "https://example.com/wiki/A_(b)"), "https://example.com/wiki/A_(b)")
        XCTAssertEqual(LinkPreviews.firstHttpsLink(in: "HTTPS://Example.com/A!"), "HTTPS://Example.com/A")
        XCTAssertNil(LinkPreviews.firstHttpsLink(in: "http://example.com/ and example.com"))
        XCTAssertNil(LinkPreviews.firstHttpsLink(in: "no link"))
    }

    func testSafeToFetch() {
        func safe(_ s: String) -> Bool { LinkPreviews.isSafeToFetch(URL(string: s)!) }
        XCTAssertTrue(safe("https://example.com/a"))
        XCTAssertTrue(safe("https://sub.example.co.uk/"))
        XCTAssertFalse(safe("http://example.com/"))
        XCTAssertFalse(safe("https://localhost/"))
        XCTAssertFalse(safe("https://printer.local/"))
        XCTAssertFalse(safe("https://intranet/"))
        XCTAssertFalse(safe("https://192.168.1.1/"))
        XCTAssertFalse(safe("https://127.0.0.1/"))
        XCTAssertFalse(safe("https://[::1]/"))
        XCTAssertFalse(safe("https://user:pw@example.com/"))
        XCTAssertFalse(safe("ftp://example.com/"))
    }

    func testParsesOpenGraphMetadata() {
        let html = """
        <html><head><title>Plain &amp; title</title>
        <meta property="og:title" content="OG &quot;Title&quot;  here">
        <META content='Desc &#233; &#x41; &mdash; more' name="description">
        <meta property='og:image' content="/img/p.png">
        </head><body><meta property="og:title" content="late"></body></html>
        """
        let meta = LinkPreviews.parseMetadata(html: html)
        XCTAssertEqual(meta.title, "OG \"Title\" here")
        XCTAssertEqual(meta.description, "Desc é A — more")
        XCTAssertEqual(meta.imageURL, "/img/p.png")
        let base = URL(string: "https://example.com/dir/page")!
        XCTAssertEqual(LinkPreviews.resolveImageURL(meta.imageURL, base: base)?.absoluteString, "https://example.com/img/p.png")
        XCTAssertEqual(LinkPreviews.resolveImageURL("p.png", base: base)?.absoluteString, "https://example.com/dir/p.png")
        XCTAssertEqual(LinkPreviews.resolveImageURL("https://cdn.example.net/x.jpg", base: base)?.absoluteString, "https://cdn.example.net/x.jpg")
    }

    func testMetadataFallbacksAndLimits() {
        let onlyTitle = LinkPreviews.parseMetadata(html: "<html><head><title>\n  Just   a title\n</title></head></html>")
        XCTAssertEqual(onlyTitle.title, "Just a title")
        XCTAssertEqual(onlyTitle.description, "")
        XCTAssertEqual(onlyTitle.imageURL, "")
        let twitter = LinkPreviews.parseMetadata(html: """
            <meta name="twitter:title" content="T"><meta name="twitter:description" content="D"><meta name="twitter:image" content="https://e.example.com/i.jpg">
            """)
        XCTAssertEqual([twitter.title, twitter.description, twitter.imageURL], ["T", "D", "https://e.example.com/i.jpg"])
        let long = LinkPreviews.parseMetadata(html: "<meta property=\"og:title\" content=\"\(String(repeating: "a", count: 500))\">"
            + "<meta property=\"og:description\" content=\"\(String(repeating: "b", count: 500))\">")
        XCTAssertEqual(long.title.count, LinkPreviews.maxTitle)
        XCTAssertEqual(long.description.count, LinkPreviews.maxDescription)
        XCTAssertEqual(LinkPreviews.parseMetadata(html: "<html>nothing</html>"), PageMetadata())
        XCTAssertEqual(LinkPreviews.htmlUnescape("a &unknown; b &amp;amp; &#xZZ;"), "a &unknown; b &amp; &#xZZ;")
    }

    func testImageSuffix() {
        XCTAssertEqual(LinkPreviews.imageSuffix(forContentType: "image/JPEG; charset=x"), "jpg")
        XCTAssertEqual(LinkPreviews.imageSuffix(forContentType: "image/png"), "png")
        XCTAssertNil(LinkPreviews.imageSuffix(forContentType: "image/svg+xml"))
        XCTAssertNil(LinkPreviews.imageSuffix(forContentType: "text/html"))
    }

    func testSendParamsForSignalCli() {
        let p = LinkPreviews.sendParams(sample(), imagePath: "/tmp/x/preview.jpg")
        XCTAssertEqual(p["previewUrl"] as? String, "https://example.com/article")
        XCTAssertEqual(p["previewTitle"] as? String, "Example article")
        XCTAssertEqual(p["previewDescription"] as? String, "A short description")
        XCTAssertEqual(p["previewImage"] as? String, "/tmp/x/preview.jpg")
        var bare = sample()
        bare.description = ""
        let q = LinkPreviews.sendParams(bare, imagePath: nil)
        XCTAssertEqual(Set(q.keys), ["previewUrl", "previewTitle"])
    }
}
