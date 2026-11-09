import CoreGraphics
@testable import CorvusCore
import XCTest

final class AlbumLayoutTests: XCTestCase {
    private func check(_ l: AlbumLayout, width: CGFloat, file: StaticString = #filePath, line: UInt = #line) {
        for t in l.tiles {
            XCTAssertGreaterThanOrEqual(t.minX, 0, file: file, line: line)
            XCTAssertLessThanOrEqual(t.maxX, width + 0.001, file: file, line: line)
            XCTAssertLessThanOrEqual(t.maxY, l.size.height + 0.001, file: file, line: line)
            XCTAssertGreaterThan(t.width, 0, file: file, line: line)
        }
        // No two tiles overlap.
        for i in l.tiles.indices { for j in l.tiles.indices where j > i {
            XCTAssertFalse(l.tiles[i].insetBy(dx: 0.5, dy: 0.5).intersects(l.tiles[j]), "\(i) \(j)", file: file, line: line)
        } }
    }

    func testCounts() {
        let w: CGFloat = 340
        for n in 1...9 {
            let l = AlbumLayout.make(aspects: Array(repeating: 0.75, count: n), width: w)
            XCTAssertEqual(l.tiles.count, min(n, AlbumLayout.maxTiles))
            XCTAssertEqual(l.overflow, max(0, n - AlbumLayout.maxTiles))
            XCTAssertEqual(l.size.width, w)
            check(l, width: w)
        }
    }

    func testShapes() {
        let two = AlbumLayout.make(aspects: [1, 1], width: 300)
        XCTAssertEqual(two.tiles[0].minY, two.tiles[1].minY)          // side by side
        let three = AlbumLayout.make(aspects: [1, 1, 1], width: 300)
        XCTAssertGreaterThan(three.tiles[0].width, three.tiles[1].width) // one big, two small
        XCTAssertEqual(three.tiles[1].minX, three.tiles[2].minX)
        XCTAssertLessThan(three.tiles[1].minY, three.tiles[2].minY)
        let four = AlbumLayout.make(aspects: [1, 1, 1, 1], width: 300)
        XCTAssertEqual(four.tiles[0].size, four.tiles[3].size)          // 2×2
        XCTAssertEqual(four.size.height, four.tiles[0].height * 2 + 2)
    }

    func testSizeDoesNotDependOnUnknownSizes() {
        // Unknown sizes (before decode) and the decoded ones give the same album for 3+ items.
        XCTAssertEqual(AlbumLayout.make(aspects: [nil, nil, nil], width: 300),
                       AlbumLayout.make(aspects: [0.5, 2, 1.2], width: 300))
        // Two portraits are taller than two landscapes, within bounds.
        let portrait = AlbumLayout.make(aspects: [1.8, 1.6], width: 300).size.height
        let landscape = AlbumLayout.make(aspects: [0.5, 0.6], width: 300).size.height
        XCTAssertGreaterThan(portrait, landscape)
        XCTAssertLessThanOrEqual(portrait, 149 * 1.33 + 1)
        XCTAssertGreaterThanOrEqual(landscape, 149 * 0.75 - 1)
    }

    func testAlbumMediaAndViewerList() {
        var img = Attachment(); img.contentType = "image/jpeg"
        var vid = Attachment(); vid.contentType = "video/mp4"
        var doc = Attachment(); doc.contentType = "application/pdf"; doc.filename = "a.pdf"
        let sticker = Attachment.sticker(packId: "p", stickerId: 1)
        XCTAssertTrue(img.isAlbumMedia)
        XCTAssertTrue(vid.isAlbumMedia)
        XCTAssertFalse(doc.isAlbumMedia)
        XCTAssertFalse(sticker.isAlbumMedia)

        var a = Message(); a.ts = 1; a.attachments = [img, doc, vid]
        var b = Message(); b.ts = 2; b.attachments = [img]; b.deleted = true
        var c = Message(); c.ts = 3; c.attachments = [img]; c.viewOnce = true
        var d = Message(); d.ts = 4; d.attachments = [sticker, img]
        let refs = MediaViewerList.refs([a, b, c, d])
        XCTAssertEqual(refs, [MediaRef(messageId: a.id, index: 0), MediaRef(messageId: a.id, index: 2),
                              MediaRef(messageId: d.id, index: 1)])
    }
}

final class ViewerZoomTests: XCTestCase {
    func testFit() {
        XCTAssertEqual(ViewerZoom.fit(image: CGSize(width: 4000, height: 2000), in: CGSize(width: 1000, height: 1000)), 0.25)
        XCTAssertEqual(ViewerZoom.fit(image: CGSize(width: 200, height: 100), in: CGSize(width: 1000, height: 1000)), 1)
        XCTAssertEqual(ViewerZoom.fit(image: .zero, in: CGSize(width: 10, height: 10)), 1)
    }

    func testToggle() {
        XCTAssertEqual(ViewerZoom.toggled(current: 0.25, fit: 0.25), 1)
        XCTAssertEqual(ViewerZoom.toggled(current: 1, fit: 0.25), 0.25)
        XCTAssertEqual(ViewerZoom.toggled(current: 3, fit: 0.25), 0.25)
        XCTAssertEqual(ViewerZoom.toggled(current: 1, fit: 1), 2) // small picture: 100 % ↔ 200 %
        XCTAssertEqual(ViewerZoom.toggled(current: 2, fit: 1), 1)
    }

    func testSteps() {
        XCTAssertEqual(ViewerZoom.step(current: 0.3, fit: 0.3, zoomIn: true), 0.5)
        XCTAssertEqual(ViewerZoom.step(current: 1, fit: 0.3, zoomIn: false), 0.75)
        XCTAssertEqual(ViewerZoom.step(current: 0.6, fit: 0.3, zoomIn: false), 0.5)
        XCTAssertEqual(ViewerZoom.step(current: 0.5, fit: 0.3, zoomIn: false), 0.3) // the fitted size is a step
        XCTAssertEqual(ViewerZoom.step(current: 8, fit: 0.3, zoomIn: true), ViewerZoom.maxScale)
        XCTAssertEqual(ViewerZoom.step(current: 0.15, fit: 0.3, zoomIn: false), ViewerZoom.minScale(fit: 0.3))
    }
}

final class WaveformTests: XCTestCase {
    func testBarsNormalizedAndCounted() {
        let values: [Float] = (0..<1000).map { Float($0 % 100) / 50 }
        let bars = Waveform.bars(values, count: 40)
        XCTAssertEqual(bars.count, 40)
        XCTAssertEqual(bars.max() ?? 0, 1, accuracy: 0.0001)
        XCTAssertTrue(bars.allSatisfy { $0 >= 0.05 && $0 <= 1 })
    }

    func testFewValuesAndSilence() {
        XCTAssertEqual(Waveform.bars([], count: 5), Array(repeating: 0.05, count: 5))
        XCTAssertEqual(Waveform.bars([0, 0, 0], count: 4), Array(repeating: 0.05, count: 4))
        let few = Waveform.bars([0.5, 1, .nan], count: 6)
        XCTAssertEqual(few.count, 6)
        XCTAssertEqual(few.max(), 1)
        XCTAssertEqual(Waveform.bars([1, 2], count: 0), [])
    }

    func testPeakPerBucket() {
        let bars = Waveform.bars([0.1, 1, 0.1, 0.1, 0.5, 0.1], count: 2)
        XCTAssertEqual(bars, [1, 0.5])
    }

    func testSpeedsAndTime() {
        XCTAssertEqual(Waveform.nextSpeed(after: 1), 1.5)
        XCTAssertEqual(Waveform.nextSpeed(after: 1.5), 2)
        XCTAssertEqual(Waveform.nextSpeed(after: 2), 1)
        XCTAssertEqual(Waveform.nextSpeed(after: 3), 1)
        XCTAssertEqual(Waveform.speedLabel(1.5), "1.5×")
        XCTAssertEqual(Waveform.speedLabel(2), "2×")
        XCTAssertEqual(Waveform.time(65.9), "1:05")
        XCTAssertEqual(Waveform.time(.nan), "0:00")
    }

    func testVoiceNoteQueue() {
        var voice = Attachment(); voice.contentType = "audio/aac"
        var img = Attachment(); img.contentType = "image/png"
        var a = Message(); a.ts = 1; a.attachments = [voice]
        var b = Message(); b.ts = 2; b.attachments = [voice]
        var c = Message(); c.ts = 3; c.text = "hi"
        var d = Message(); d.ts = 4; d.attachments = [voice]; d.deleted = true
        var e = Message(); e.ts = 5; e.attachments = [img, voice]
        XCTAssertEqual(VoiceNoteQueue.next(after: a.id, in: [a, b, c])?.message.id, b.id)
        XCTAssertNil(VoiceNoteQueue.next(after: b.id, in: [a, b, c]))      // a text message breaks the run
        XCTAssertNil(VoiceNoteQueue.next(after: c.id, in: [c, d]))
        XCTAssertNil(VoiceNoteQueue.next(after: b.id, in: [a, b]))         // the last message
        XCTAssertEqual(VoiceNoteQueue.next(after: a.id, in: [a, e])?.index, 1)
    }
}

final class SentMediaQualityTests: XCTestCase {
    func testHighKeepsOriginals() {
        XCTAssertEqual(SentMediaQuality.high.plan(contentType: "image/jpeg", width: 8000, height: 6000, bytes: 20_000_000,
                                                  hasAlpha: false, animated: false), .original)
    }

    func testStandard() {
        let q = SentMediaQuality.standard
        XCTAssertEqual(q.plan(contentType: "image/jpeg", width: 4032, height: 3024, bytes: 3_000_000, hasAlpha: false, animated: false),
                       .reencode(maxSide: 1600, png: false))
        XCTAssertEqual(q.plan(contentType: "image/png", width: 3000, height: 1000, bytes: 900_000, hasAlpha: true, animated: false),
                       .reencode(maxSide: 1600, png: true))
        // Small enough already.
        XCTAssertEqual(q.plan(contentType: "image/jpeg", width: 1200, height: 900, bytes: 300_000, hasAlpha: false, animated: false),
                       .original)
        // Within the size but heavy: re-encoded at its own size.
        XCTAssertEqual(q.plan(contentType: "image/png", width: 1400, height: 900, bytes: 4_000_000, hasAlpha: false, animated: false),
                       .reencode(maxSide: 1400, png: false))
        // HEIC is converted even when small.
        XCTAssertEqual(q.plan(contentType: "image/heic", width: 800, height: 600, bytes: 100_000, hasAlpha: false, animated: false),
                       .reencode(maxSide: 800, png: false))
        // GIFs, animations, videos and unknown sizes are left alone.
        XCTAssertEqual(q.plan(contentType: "image/gif", width: 4000, height: 4000, bytes: 9_000_000, hasAlpha: false, animated: true), .original)
        XCTAssertEqual(q.plan(contentType: "image/webp", width: 4000, height: 4000, bytes: 9_000_000, hasAlpha: false, animated: true), .original)
        XCTAssertEqual(q.plan(contentType: "video/mp4", width: 4000, height: 4000, bytes: 9_000_000, hasAlpha: false, animated: false), .original)
        XCTAssertEqual(q.plan(contentType: "image/jpeg", width: 0, height: 0, bytes: 9_000_000, hasAlpha: false, animated: false), .original)
    }

    func testLoad() {
        let d = UserDefaults(suiteName: "corvus-test-\(UUID().uuidString)")!
        XCTAssertEqual(SentMediaQuality.load(d), .standard)
        d.set("high", forKey: SentMediaQuality.key)
        XCTAssertEqual(SentMediaQuality.load(d), .high)
        d.set("bogus", forKey: SentMediaQuality.key)
        XCTAssertEqual(SentMediaQuality.load(d), .standard)
    }
}

final class FileKindTests: XCTestCase {
    func testKinds() {
        XCTAssertEqual(FileKind.of(filename: "Report.PDF", contentType: ""), .pdf)
        XCTAssertEqual(FileKind.of(filename: "x", contentType: "application/pdf"), .pdf)
        XCTAssertEqual(FileKind.of(filename: "a.tar.gz", contentType: ""), .archive)
        XCTAssertEqual(FileKind.of(filename: "a.zip", contentType: "application/octet-stream"), .archive)
        XCTAssertEqual(FileKind.of(filename: "song.flac", contentType: ""), .audio)
        XCTAssertEqual(FileKind.of(filename: "clip.mkv", contentType: ""), .video)
        XCTAssertEqual(FileKind.of(filename: "main.swift", contentType: ""), .code)
        XCTAssertEqual(FileKind.of(filename: "notes.txt", contentType: ""), .text)
        XCTAssertEqual(FileKind.of(filename: "data.csv", contentType: ""), .spreadsheet)
        XCTAssertEqual(FileKind.of(filename: "cv.docx", contentType: ""), .document)
        XCTAssertEqual(FileKind.of(filename: "", contentType: "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"),
                       .spreadsheet)
        XCTAssertEqual(FileKind.of(filename: "deck.key", contentType: ""), .presentation)
        XCTAssertEqual(FileKind.of(filename: "thing.bin", contentType: "application/octet-stream"), .generic)
        XCTAssertEqual(FileKind.of(filename: "README", contentType: "text/plain"), .text)
    }

    func testDetail() {
        XCTAssertEqual(FileKind.detail(filename: "a.pdf", contentType: "application/pdf", size: 0), "PDF")
        XCTAssertTrue(FileKind.detail(filename: "a.pdf", contentType: "", size: 2048).hasPrefix("PDF · "))
        XCTAssertEqual(FileKind.detail(filename: "README", contentType: "text/plain", size: 0), "TXT")
        XCTAssertEqual(FileKind.detail(filename: "x", contentType: "application/x-unknown-thing", size: 0), "")
        XCTAssertEqual(FileKind.fileExtension(".bashrc"), "")
        XCTAssertEqual(FileKind.fileExtension("dir/a.Tar.GZ"), "gz")
    }
}
