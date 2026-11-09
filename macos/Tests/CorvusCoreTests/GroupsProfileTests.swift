import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import CorvusCore

final class GroupSettingsTests: XCTestCase {
    private let me = "+15550100"

    private func group(sendPermission: String = "EVERY_MEMBER", meAdmin: Bool = false) -> JSON {
        ["id": "R1JPVVA=", "name": "Team", "isMember": true,
         "members": [["number": me, "uuid": "u-me", "isAdmin": meAdmin, "label": "", "labelEmoji": ""],
                     ["number": "+15550101", "uuid": "u-ann", "isAdmin": true, "label": "Organiser", "labelEmoji": "🎸"],
                     ["number": "+15550102", "uuid": "u-bo", "isAdmin": false, "label": "", "labelEmoji": "🌵"]],
         "permissionAddMember": "ONLY_ADMINS", "permissionEditDetails": "EVERY_MEMBER",
         "permissionSendMessage": sendPermission, "groupInviteLink": ""]
    }

    func testMemberLabelsAreParsed() {
        let g = GroupInfo(json: group())
        XCTAssertEqual(g.member("+15550101")?.label, "Organiser")
        XCTAssertEqual(g.member("u-ann")?.labelText, "🎸 Organiser")
        XCTAssertEqual(g.member("+15550102")?.labelText, "🌵")
        XCTAssertEqual(g.member(me)?.labelText, "")
        XCTAssertEqual(g.memberLabels, ["+15550101": "🎸 Organiser", "u-ann": "🎸 Organiser", "+15550102": "🌵", "u-bo": "🌵"])
        // Older signal-cli without labels.
        XCTAssertEqual(GroupInfo(json: ["id": "x", "members": [["number": me]]]).memberLabels, [:])
    }

    func testPermissionParams() {
        let g = GroupInfo(json: group())
        XCTAssertEqual(GroupPermissionKind.addMembers.value(in: g), .onlyAdmins)
        XCTAssertTrue(GroupParams.permission(.addMembers, .onlyAdmins, in: g).isEmpty, "unchanged: nothing to send")
        XCTAssertEqual(GroupParams.permission(.addMembers, .everyMember, in: g) as? [String: String],
                       ["setPermissionAddMember": "every-member"])
        XCTAssertEqual(GroupParams.permission(.sendMessages, .onlyAdmins, in: g) as? [String: String],
                       ["setPermissionSendMessages": "only-admins"])
        XCTAssertEqual(GroupParams.permission(.editDetails, .onlyAdmins, in: g) as? [String: String],
                       ["setPermissionEditDetails": "only-admins"])
        var h = g
        GroupPermissionKind.sendMessages.set(.onlyAdmins, in: &h)
        XCTAssertTrue(h.isAnnouncementOnly)
    }

    func testOtherGroupParams() {
        XCTAssertEqual(GroupParams.avatar("/tmp/a.png") as? [String: String], ["avatar": "/tmp/a.png"])
        XCTAssertEqual(GroupParams.memberLabel(" Lead ", emoji: "⭐️ ") as? [String: String],
                       ["memberLabel": "Lead", "memberLabelEmoji": "⭐️"])
        XCTAssertEqual(GroupParams.memberLabel("", emoji: "") as? [String: String], ["memberLabel": "", "memberLabelEmoji": ""])
        XCTAssertEqual(GroupParams.ban(["+15550102"]) as? [String: [String]], ["ban": ["+15550102"]])
        XCTAssertEqual(GroupParams.unban(["u-bo"]) as? [String: [String]], ["unban": ["u-bo"]])
        XCTAssertEqual(GroupParams.link(.enabledWithApproval) as? [String: String], ["link": "enabled-with-approval"])
        let link = GroupInviteLink.parse("https://signal.group/#" + String(repeating: "Ab-_", count: 12))!
        XCTAssertEqual(GroupParams.join(link) as? [String: String], ["uri": link.url])
    }

    func testAnnouncementGroupLocksTheComposerForMembersOnly() {
        var r = Roster()
        r.account = me
        r.update(contacts: [])
        r.update(groups: [group(sendPermission: "ONLY_ADMINS")])
        r.baselineContacts(existing: [])
        r.baselineGroups()
        let c = Conversation(key: "g:R1JPVVA=", title: "Team", isGroup: true)
        let g = r.groups[c.key]!
        XCTAssertFalse(g.canSendMessages(me))
        XCTAssertTrue(g.canSendMessages("+15550101"))
        XCTAssertTrue(r.isAdminOnlyForUs(g))
        XCTAssertTrue(r.isSendLocked(c))
        XCTAssertFalse(r.isRequest(c), "announcement groups are not requests")

        r.update(groups: [group(sendPermission: "ONLY_ADMINS", meAdmin: true)])
        XCTAssertFalse(r.isSendLocked(c), "admins may send")
        r.update(groups: [group()])
        XCTAssertFalse(r.isSendLocked(c), "everyone may send")
    }
}

final class GroupInviteLinkTests: XCTestCase {
    private let code = "CjQKIAbcDEF0123456789-_abcdefghijklmnopqrstuvwxyzAB" // fake

    func testParsesTheLinkForms() {
        XCTAssertEqual(GroupInviteLink.parse("https://signal.group/#" + code)?.url, "https://signal.group/#" + code)
        XCTAssertEqual(GroupInviteLink.parse("  https://signal.group/#\(code)\n")?.code, code)
        XCTAssertEqual(GroupInviteLink.parse("sgnl://signal.group/#" + code)?.url, "https://signal.group/#" + code)
        XCTAssertEqual(GroupInviteLink.parse("HTTPS://SIGNAL.GROUP/#" + code)?.url, "https://signal.group/#" + code)
        XCTAssertEqual(GroupInviteLink.parse("http://signal.group#" + code)?.url, "https://signal.group/#" + code)
    }

    func testRejectsOtherLinks() {
        XCTAssertNil(GroupInviteLink.parse("https://signal.group/"))
        XCTAssertNil(GroupInviteLink.parse("https://signal.group/#short"))
        XCTAssertNil(GroupInviteLink.parse("https://signal.group/path/#" + code))
        XCTAssertNil(GroupInviteLink.parse("https://signal.groups.example/#" + code))
        XCTAssertNil(GroupInviteLink.parse("https://signal.group/#" + code + "<script>"))
        XCTAssertNil(GroupInviteLink.parse("https://signal.art/addstickers/#pack_id=1"))
        XCTAssertNil(GroupInviteLink.parse("https://example.com/#" + code))
    }

    func testFindsTheLinkInAMessage() {
        let text = "Join us: <https://signal.group/#\(code)> see you"
        XCTAssertEqual(GroupInviteLink.find(in: text)?.code, code)
        XCTAssertNil(GroupInviteLink.find(in: "no link here"))
    }

    func testJoinResult() {
        let r = GroupJoinResult(json: ["groupId": "R1JPVVA=", "onlyRequested": true, "timestamp": 1, "results": []])
        XCTAssertEqual(r, GroupJoinResult(groupId: "R1JPVVA=", onlyRequested: true))
        XCTAssertEqual(GroupJoinResult(json: nil), GroupJoinResult())
    }
}

final class ProfileTests: XCTestCase {
    private let me = "+15550100"

    func testOwnProfileFromListContacts() {
        let res: [Any] = [
            ["number": "+15550101", "uuid": "u-x", "profile": ["givenName": "Other"]],
            ["number": me, "uuid": "u-me", "username": "jo.42",
             "profile": ["givenName": "Jo", "familyName": "Doe", "about": "Hiking", "aboutEmoji": "🏔️", "hasAvatar": true]],
        ]
        let p = OwnProfile.find(in: res, account: me)
        XCTAssertEqual(p, OwnProfile(givenName: "Jo", familyName: "Doe", about: "Hiking", aboutEmoji: "🏔️",
                                     username: "jo.42", hasAvatar: true))
        XCTAssertEqual(p?.name, "Jo Doe")
        XCTAssertEqual(p?.aboutLine, "🏔️ Hiking")
        XCTAssertEqual(OwnProfile.find(in: res, account: "u-me")?.givenName, "Jo")
        XCTAssertNil(OwnProfile.find(in: res, account: "+15550199"))
        XCTAssertNil(OwnProfile.find(in: res, account: ""))
    }

    func testUpdateSendsOnlyChangesAndKeepsTheFamilyName() {
        let before = OwnProfile(givenName: "Jo", familyName: "Doe", about: "Hiking", aboutEmoji: "🏔️")
        XCTAssertTrue(ProfileParams.update(from: before, givenName: "Jo ", familyName: "Doe", about: "Hiking", aboutEmoji: "🏔️").isEmpty)
        XCTAssertEqual(ProfileParams.update(from: before, givenName: "Jo", familyName: "Doe", about: "Climbing", aboutEmoji: "🏔️")
            as? [String: String], ["about": "Climbing"])
        XCTAssertEqual(ProfileParams.update(from: before, givenName: "Jo", familyName: "", about: "", aboutEmoji: "")
            as? [String: String], ["familyName": "", "about": "", "aboutEmoji": ""], "clearing sends empty strings")
        XCTAssertTrue(ProfileParams.update(from: before, givenName: "  ", familyName: "Doe", about: "Hiking", aboutEmoji: "🏔️").isEmpty,
                      "the given name cannot be cleared")
        var p = before
        ProfileParams.apply(["givenName": "Joanna", "about": ""], to: &p)
        XCTAssertEqual(p, OwnProfile(givenName: "Joanna", familyName: "Doe", about: "", aboutEmoji: "🏔️"))
        XCTAssertEqual(ProfileParams.removeAvatar as? [String: Bool], ["removeAvatar": true])
    }

    func testUsernameRules() {
        XCTAssertNil(Username.problem("jo_doe"))
        XCTAssertNil(Username.problem("jo_doe.42"))
        XCTAssertNil(Username.problem("JoDoe.123"))
        XCTAssertNotNil(Username.problem(""))
        XCTAssertNotNil(Username.problem("jo"))
        XCTAssertNotNil(Username.problem("1jo"))
        XCTAssertNotNil(Username.problem("jo doe"))
        XCTAssertNotNil(Username.problem("jö_doe"))
        XCTAssertNotNil(Username.problem(String(repeating: "a", count: 33)))
        XCTAssertNotNil(Username.problem("jo_doe.4"))
        XCTAssertNotNil(Username.problem("jo_doe.00"))
        XCTAssertNotNil(Username.problem("jo_doe.012"))
        XCTAssertNotNil(Username.problem("jo_doe.4a"))
        XCTAssertNotNil(Username.problem("jo.doe.42"))
        XCTAssertEqual(Username.set(" jo.42 ") as? [String: String], ["username": "jo.42"])
        XCTAssertEqual(Username.delete as? [String: Bool], ["deleteUsername": true])
    }

    func testUsernameResult() {
        let r = UsernameResult(json: ["username": "jo.42", "usernameLink": "https://signal.me/#eu/abc"])
        XCTAssertEqual(r, UsernameResult(username: "jo.42", link: "https://signal.me/#eu/abc"))
        XCTAssertEqual(UsernameResult(json: ["username": "jo.42", "usernameLink": NSNull()]).link, "")
    }
}

final class ContactDetailsTests: XCTestCase {
    func testNicknameAndNoteAreParsedAndUpdated() {
        var r = Roster()
        r.account = "+15550100"
        r.update(contacts: [["number": "+15550101", "uuid": "u-ann", "name": "Ann", "nickGivenName": "Annie",
                             "nickFamilyName": "B", "note": "Met at the climbing gym"]])
        let c = r.contact("u-ann")!
        XCTAssertEqual(c.nickname, "Annie B")
        XCTAssertEqual(c.note, "Met at the climbing gym")

        XCTAssertTrue(r.setContactDetails("+15550101", nickGivenName: "Ann", nickFamilyName: ""))
        XCTAssertEqual(r.contact("u-ann")?.nickname, "Ann", "both keys see the change")
        XCTAssertEqual(r.contacts.first?.nickname, "Ann")
        XCTAssertEqual(r.contact("+15550101")?.note, "Met at the climbing gym", "nil leaves the note alone")
        r.setContactDetails("u-ann", note: "")
        XCTAssertEqual(r.contact("+15550101")?.note, "")
        XCTAssertFalse(r.setContactDetails("+15550199", note: "x"), "unknown people are not added")
        XCTAssertNil(r.contact("+15550199"))
    }

    func testParams() {
        XCTAssertEqual(ContactParams.nickname(recipient: "+15550101", given: " Annie ", family: "") as? [String: String],
                       ["recipient": "+15550101", "nickGivenName": "Annie", "nickFamilyName": ""])
        XCTAssertEqual(ContactParams.note(recipient: "+15550101", note: "hi\n") as? [String: String],
                       ["recipient": "+15550101", "note": "hi"])
        XCTAssertEqual(ContactParams.join(given: "Annie", family: " B "), "Annie B")
        XCTAssertEqual(ContactParams.join(given: "", family: "B"), "B")
    }
}

final class StickerPackCreatorTests: XCTestCase {
    func testManifest() throws {
        let m = StickerManifest(title: " Cats ", author: "Jo", stickers: [
            StickerDraft(file: "0.png", emoji: "🐱"), StickerDraft(file: "1.png", emoji: "😺", animated: true),
        ], cover: 1)
        XCTAssertNil(m.problem)
        let o = try XCTUnwrap(JSONSerialization.jsonObject(with: m.data()) as? JSON)
        XCTAssertEqual(o["title"] as? String, "Cats")
        XCTAssertEqual(o["author"] as? String, "Jo")
        XCTAssertEqual(o["cover"] as? [String: String], ["file": "1.png", "emoji": "😺", "contentType": "image/png"])
        XCTAssertEqual(o["stickers"] as? [[String: String]], [
            ["file": "0.png", "emoji": "🐱", "contentType": "image/png"],
            ["file": "1.png", "emoji": "😺", "contentType": "image/png"],
        ])
    }

    func testManifestProblems() {
        let s = [StickerDraft(file: "0.png", emoji: "🐱")]
        XCTAssertNotNil(StickerManifest(title: "T", author: "A", stickers: []).problem)
        XCTAssertNotNil(StickerManifest(title: "T", author: "A", stickers: [StickerDraft(file: "0.png", emoji: " ")]).problem)
        XCTAssertNotNil(StickerManifest(title: "", author: "A", stickers: s).problem)
        XCTAssertNotNil(StickerManifest(title: "T", author: " ", stickers: s).problem)
        XCTAssertNotNil(StickerManifest(title: String(repeating: "t", count: 41), author: "A", stickers: s).problem)
        XCTAssertNotNil(StickerManifest(title: "T", author: "A",
                                        stickers: Array(repeating: s[0], count: StickerRules.maxStickers + 1)).problem)
        // A cover index out of range: no cover entry (signal-cli then uses the first sticker).
        XCTAssertNil(StickerManifest(title: "T", author: "A", stickers: s, cover: 5).json["cover"])
    }

    func testUploadResultLink() {
        let url = "https://signal.art/addstickers/#pack_id=\(String(repeating: "a", count: 32))&pack_key=\(String(repeating: "b", count: 64))"
        XCTAssertEqual(StickerUploadResult.link(["url": url])?.uri, url)
        XCTAssertEqual(StickerUploadResult.link(url)?.packId, String(repeating: "a", count: 32))
        XCTAssertNil(StickerUploadResult.link(["url": "nope"]))
        XCTAssertNil(StickerUploadResult.link(nil))
    }

    func testFitRect() {
        XCTAssertEqual(StickerRules.fitRect(CGSize(width: 1024, height: 512)), CGRect(x: 0, y: 128, width: 512, height: 256))
        XCTAssertEqual(StickerRules.fitRect(CGSize(width: 100, height: 200)), CGRect(x: 128, y: 0, width: 256, height: 512))
        XCTAssertEqual(StickerRules.fitRect(CGSize(width: 512, height: 512)), CGRect(x: 0, y: 0, width: 512, height: 512))
        XCTAssertEqual(StickerRules.fitRect(.zero), CGRect(x: 0, y: 0, width: 512, height: 512))
    }

    // MARK: Images

    /// An RGBA image; `noise` makes it hard to compress.
    private func image(width: Int, height: Int, noise: Bool, seed: UInt32 = 1) -> CGImage {
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let p = ctx.data!.bindMemory(to: UInt8.self, capacity: width * height * 4)
        var x = seed
        for i in 0..<(width * height) {
            x = x &* 1_664_525 &+ 1_013_904_223
            let v = noise ? UInt8(truncatingIfNeeded: x >> 24) : UInt8(i % 256)
            p[i * 4] = v
            p[i * 4 + 1] = noise ? UInt8(truncatingIfNeeded: x >> 16) : 80
            p[i * 4 + 2] = noise ? UInt8(truncatingIfNeeded: x >> 8) : 200
            p[i * 4 + 3] = 255
        }
        return ctx.makeImage()!
    }

    private func encode(_ frames: [CGImage], type: UTType, delay: Double = 0.1) -> Data {
        let out = NSMutableData()
        let dest = CGImageDestinationCreateWithData(out, type.identifier as CFString, frames.count, nil)!
        for f in frames {
            let props: [CFString: Any] = type == .gif
                ? [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: delay]] : [:]
            CGImageDestinationAddImage(dest, f, props as CFDictionary)
        }
        XCTAssertTrue(CGImageDestinationFinalize(dest))
        return out as Data
    }

    private func info(_ data: Data) -> (count: Int, width: Int, height: Int) {
        let src = CGImageSourceCreateWithData(data as CFData, nil)!
        let img = CGImageSourceCreateImageAtIndex(src, 0, nil)!
        return (CGImageSourceGetCount(src), img.width, img.height)
    }

    func testStillImageBecomesA512PNG() throws {
        let out = try StickerImageConverter.convert(encode([image(width: 300, height: 150, noise: false)], type: .jpeg))
        XCTAssertFalse(out.animated)
        XCTAssertTrue(out.data.starts(with: [0x89, 0x50, 0x4E, 0x47]), "PNG")
        let i = info(out.data)
        XCTAssertEqual(i.width, 512)
        XCTAssertEqual(i.height, 512)
        XCTAssertLessThanOrEqual(out.data.count, StickerRules.maxBytes)
    }

    func testNoisyImageIsReducedBelowTheLimit() throws {
        let input = encode([image(width: 512, height: 512, noise: true)], type: .png)
        XCTAssertGreaterThan(input.count, StickerRules.maxBytes, "the test image must start too large")
        let out = try StickerImageConverter.convert(input)
        XCTAssertLessThanOrEqual(out.data.count, StickerRules.maxBytes)
        XCTAssertEqual(info(out.data).width, 512)
    }

    func testTooLargeEvenAfterReducing() {
        let input = encode([image(width: 512, height: 512, noise: true)], type: .png)
        XCTAssertThrowsError(try StickerImageConverter.convert(input, maxBytes: 1000)) { e in
            guard case StickerImageError.tooLarge = e else { return XCTFail("\(e)") }
        }
    }

    func testAnimatedGIFBecomesAPNG() throws {
        let frames = (0..<4).map { image(width: 64, height: 64, noise: false, seed: UInt32($0)) }
        let out = try StickerImageConverter.convert(encode(frames, type: .gif, delay: 0.25))
        XCTAssertTrue(out.animated)
        let i = info(out.data)
        XCTAssertEqual(i.count, 4)
        XCTAssertEqual(i.width, 512)
        let src = CGImageSourceCreateWithData(out.data as CFData, nil)!
        XCTAssertEqual(CGImageSourceGetType(src) as String?, UTType.png.identifier)
        XCTAssertEqual(StickerImageConverter.delay(src, 0), 0.25, accuracy: 0.01)
    }

    func testAnimationLongerThanThreeSecondsIsRefused() {
        let frames = (0..<4).map { image(width: 32, height: 32, noise: false, seed: UInt32($0)) }
        XCTAssertThrowsError(try StickerImageConverter.convert(encode(frames, type: .gif, delay: 1.0))) { e in
            guard case StickerImageError.tooLong = e else { return XCTFail("\(e)") }
        }
    }

    func testUnreadableInput() {
        XCTAssertThrowsError(try StickerImageConverter.convert(Data("not an image".utf8))) { e in
            XCTAssertEqual(e as? StickerImageError, .unreadable)
        }
    }
}
