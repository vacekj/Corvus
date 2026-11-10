import XCTest
@testable import CorvusCore

/// Synthetic history of about the size of a long-used account, for measuring the cost of loading,
/// holding and scanning it. Runs only with CORVUS_BENCH=1:
///   CORVUS_BENCH=1 swift test -c release -Xswiftc -enable-testing --filter PerfBench
enum BenchHistory {
    static let chats = 150
    static let messages = 90_000

    private static let words = ["ok", "díky", "sounds good", "see you tomorrow at the usual place", "haha", "kde jsi?",
                                "I'll send the invoice later today, need to check the numbers first",
                                "😂", "jo", "Can you call me when you have a minute?", "na cestě", "👍",
                                "That's the one I was talking about last week — the place near the river with the long tables",
                                "ne", "posílám", "thanks!", "Žluťoučký kůň", "let me check", "done", "?"]

    static func uuid(_ i: Int) -> String {
        String(format: "%08x-0000-4000-8000-%012x", i &* 2_654_435_761 & 0xffff_ffff, i)
    }

    /// Deterministic (no random source): the same history in every run.
    static func state() -> ChatState {
        var s = ChatState()
        s.account = "+420600000000"
        var ts: Int64 = 1_600_000_000_000
        var seed: UInt64 = 0x9e37_79b9_7f4a_7c15
        func next() -> Int {
            seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Int(seed >> 33)
        }
        for i in 0..<messages {
            // A few chats hold most of the messages, like real use.
            let r = next() % 100
            let chat = r < 60 ? next() % 8 : (r < 90 ? 8 + next() % 30 : 38 + next() % (chats - 38))
            let group = chat % 5 == 0
            let key = group ? "g:" + String(format: "%032x", chat) : uuid(chat)
            s.ensure(key, title: "Chat \(chat)", group: group)
            var m = Message()
            ts += Int64(1000 + next() % 600_000)
            m.ts = ts
            m.orderTs = ts
            m.outgoing = next() % 2 == 0
            m.text = words[next() % words.count] + (i % 7 == 0 ? " \(i)" : "")
            if m.outgoing {
                m.authorKey = s.account
                m.sender = "You"
                m.receiptStatus = 2
                let recipients = group ? 4 : 1
                for k in 0..<recipients {
                    var rr = RecipientReceipt()
                    rr.status = 2
                    rr.deliveredAtMs = ts + 900
                    rr.readAtMs = ts + 60_000
                    m.recipientReceipts[uuid(group ? 1000 + chat * 10 + k : chat)] = rr
                }
                if group { m.sentToKeys = (0..<recipients).map { uuid(1000 + chat * 10 + $0) } }
            } else {
                let author = group ? 1000 + chat * 10 + next() % 4 : chat
                m.authorKey = uuid(author)
                m.sender = "Person Number \(author)"
            }
            if i % 23 == 0 { m.reactions[uuid(chat)] = "❤️" }
            if i % 31 == 0 {
                m.quote.valid = true
                m.quote.id = ts - 5000
                m.quote.authorKey = uuid(chat)
                m.quote.text = "quoted text"
            }
            if i % 19 == 0 {
                var a = Attachment()
                a.id = "att\(i).jpg"
                a.contentType = "image/jpeg"
                a.filename = "IMG_\(i).jpg"
                a.size = 2_400_000
                a.width = 3024
                a.height = 4032
                m.attachments = [a]
            }
            s.convs[key]!.msgs.append(m)
        }
        return s
    }

    static func footprint() -> Int {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return kr == KERN_SUCCESS ? Int(info.phys_footprint) : 0
    }

    static func ms(_ body: () throws -> Void) rethrows -> Int {
        let t = DispatchTime.now().uptimeNanoseconds
        try body()
        return Int((DispatchTime.now().uptimeNanoseconds - t) / 1_000_000)
    }

    static func mb(_ bytes: Int) -> String { String(format: "%.1f MB", Double(bytes) / 1_048_576) }
}

final class PerfBenchTests: XCTestCase {
    private var enabled: Bool { ProcessInfo.processInfo.environment["CORVUS_BENCH"] != nil }

    func testLegacyStoreLoad() throws {
        try XCTSkipUnless(enabled)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("corvus-bench-\(getpid())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("history.corvus").path

        do {
            let records = BenchHistory.state().allRecords()
            let store = HistoryStore()
            try store.create(path: path, passphrase: "bench secret")
            let t = try BenchHistory.ms { try store.rewrite(records) }
            store.close()
            let size = (try FileManager.default.attributesOfItem(atPath: path)[.size] as? Int) ?? 0
            print("BENCH legacy: \(records.count) records, file \(BenchHistory.mb(size)), rewrite \(t) ms")
        }

        let before = BenchHistory.footprint()
        let store = HistoryStore()
        var records: [JSON] = []
        let open = try BenchHistory.ms { records = try store.open(path: path, passphrase: "bench secret") }
        var state = ChatState()
        let apply = BenchHistory.ms { state.loadHistory(records) }
        records = []
        let after = BenchHistory.footprint()
        print("BENCH legacy: open \(open) ms (unlock+decrypt \(store.lastOpenTimings.decrypt), parse \(store.lastOpenTimings.parse)), apply \(apply) ms, footprint +\(BenchHistory.mb(after - before))")
        print("BENCH Message stride \(MemoryLayout<Message>.stride) B, Attachment \(MemoryLayout<Attachment>.stride) B")

        var hits = 0
        let search = BenchHistory.ms { hits = searchMessages(state.convs, query: "zlut").count }
        var expired = false
        let scan = BenchHistory.ms { for _ in 0..<10 { expired = state.hasExpiredMessages(now: nowMs()) } }
        print("BENCH search \(search) ms (\(hits) hits), expiry scan \(scan / 10) ms (\(expired))")
        XCTAssertEqual(state.convs.values.reduce(0) { $0 + $1.msgs.count }, BenchHistory.messages)
    }
}
