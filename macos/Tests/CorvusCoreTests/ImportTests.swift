import CommonCrypto
import CryptoKit
import XCTest
@testable import CorvusCore

final class DesktopImportTests: XCTestCase {
    private func record(_ c: String, _ ts: Int64, _ au: String, _ x: String, out: Bool = false) -> JSON {
        ["t": "m", "c": c, "ts": ts, "s": "", "x": x, "o": out, "au": au]
    }

    func testMergeSkipsKnownMessagesAndIsIdempotent() {
        var s = ChatState()
        s.account = "+49100"
        s.loadHistory([record("+49111", 2000, "+49111", "already here")])
        let imported: [JSON] = [
            ["t": "n", "c": "+49111", "n": "Alice"],
            record("+49111", 1000, "+49111", "older"),
            record("+49111", 2000, "+49111", "already here"),
            record("+49111", 1500, "+49100", "mine", out: true),
            ["t": "r", "c": "+49111", "ts": 1000, "au": "+49111", "by": "+49100", "e": "👍"],
            record("g:R1JPVVA=", 1200, "+49222", "group msg"),
        ]
        let sum = s.mergeImported(imported)
        XCTAssertEqual(sum.messagesAdded, 3)
        XCTAssertEqual(sum.messagesKnown, 1)
        XCTAssertEqual(sum.reactionsAdded, 1)
        XCTAssertEqual(s.convs["+49111"]!.msgs.map(\.text), ["older", "mine", "already here"])
        XCTAssertEqual(s.convs["+49111"]!.title, "Alice")
        XCTAssertTrue(s.convs["g:R1JPVVA="]!.isGroup)
        let again = s.mergeImported(imported)
        XCTAssertEqual(again.messagesAdded, 0)
        XCTAssertEqual(again.reactionsAdded, 0)
        // Survives a history rewrite.
        var t = ChatState()
        t.loadHistory(s.allRecords())
        XCTAssertEqual(t.convs["+49111"]!.msgs.count, 3)
        XCTAssertEqual(t.convs["+49111"]!.msgs[0].reactions["+49100"], "👍")
    }

    func testMergeUsesAliasForUuidKeys() {
        var s = ChatState()
        s.alias["11111111-2222-3333-4444-555555555555"] = "+49111"
        s.mergeImported([record("11111111-2222-3333-4444-555555555555", 1000, "11111111-2222-3333-4444-555555555555", "hi")])
        XCTAssertNotNil(s.convs["+49111"])
        XCTAssertEqual(s.convs["+49111"]!.msgs.first?.authorKey, "+49111")
    }

    func testImportedAttachmentRoundTripAndDecrypt() throws {
        var a = Attachment()
        a.contentType = "image/png"
        a.encPath = "ab_cdef"
        a.localKey = "k"
        var m = Message()
        m.ts = 5
        m.attachments = [a]
        let back = Records.messageFromRecord(Records.message("+49111", m))
        XCTAssertEqual(back.attachments.first?.encPath, "ab_cdef")
        XCTAssertEqual(back.attachments.first?.localKey, "k")
        XCTAssertTrue(DesktopAttachment.isSafeName("ab_cdef09"))
        XCTAssertFalse(DesktopAttachment.isSafeName("../x"))
        XCTAssertFalse(DesktopAttachment.isSafeName("a/b"))

        // Encrypt like Signal Desktop: IV || AES-256-CBC || HMAC-SHA256(IV || CT).
        let key = Data((0..<64).map { UInt8($0) })
        let iv = Data(repeating: 9, count: 16)
        let plain = Data("hello attachment".utf8)
        var ct = Data(count: plain.count + 16)
        var moved = 0
        let ctCount = ct.count
        _ = ct.withUnsafeMutableBytes { o in
            plain.withUnsafeBytes { p in key.withUnsafeBytes { k in iv.withUnsafeBytes { i in
                CCCrypt(CCOperation(kCCEncrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionPKCS7Padding),
                        k.baseAddress, 32, i.baseAddress, p.baseAddress, plain.count, o.baseAddress, ctCount, &moved)
            } } }
        }
        ct.count = moved
        var file = iv + ct
        file += Data(HMAC<SHA256>.authenticationCode(for: file, using: SymmetricKey(data: key.suffix(32))))
        XCTAssertEqual(try DesktopAttachment.decrypt(file, localKey: key.base64EncodedString(), size: 5), Data("hello".utf8))
        var bad = file
        bad[20] ^= 1
        XCTAssertThrowsError(try DesktopAttachment.decrypt(bad, localKey: key.base64EncodedString(), size: 0))
    }
}
