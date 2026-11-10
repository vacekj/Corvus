import XCTest
@testable import CorvusCore

/// The Signal backend running inside the process (no network: nothing here has an account).
@MainActor
final class EmbeddedBackendTests: XCTestCase {
    private var dir: URL!

    override func setUp() async throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("corvus-embedded-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDown() async throws { try? FileManager.default.removeItem(at: dir) }

    private func backend() -> SignalBackend {
        let b = SignalBackend()
        b.dataDir = dir
        b.storeKey = { String(repeating: "5a", count: 32) }
        return b
    }

    func testOneShotCommands() async {
        let b = backend()
        XCTAssertTrue(b.embedded)
        let (r, version) = await b.queryVersion()
        XCTAssertTrue(r.ok, r.describe())
        XCTAssertTrue(version.hasPrefix("corvus-signal "), version)
        let (r2, accounts) = await b.queryAccounts()
        XCTAssertTrue(r2.ok, r2.describe())
        XCTAssertEqual(accounts, [])
        // An error is an exit code and a line on the error stream, as from the process.
        let bad = await b.run(["no-such-command"], timeout: 10)
        XCTAssertFalse(bad.ok)
        XCTAssertEqual(bad.exitCode, 2)
        XCTAssertTrue(bad.err.contains("unknown argument"), bad.err)
    }

    func testJsonRpcAnswersAndStops() async throws {
        let b = backend()
        var stopped: [String] = []
        b.onStopped = { stopped.append($0) }
        b.start(account: "+15550000000")
        XCTAssertTrue(b.isRunning)
        // No account is linked in the empty data folder: every call says so (and proves the round trip).
        do {
            _ = try await b.call("listContacts")
            XCTFail("expected an error")
        } catch {
            XCTAssertTrue(error.localizedDescription.lowercased().contains("link"), error.localizedDescription)
        }
        // Several calls at once come back to their own callers: one unknown method, one known.
        func failure(_ method: String) async -> String {
            do {
                _ = try await b.call(method)
                return ""
            } catch {
                return error.localizedDescription
            }
        }
        async let unknown = failure("noSuchMethod")
        async let known = failure("listGroups")
        let (u, k) = await (unknown, known)
        XCTAssertTrue(u.contains("Method not found: noSuchMethod"), u)
        XCTAssertTrue(k.lowercased().contains("link"), k)
        b.stop()
        XCTAssertFalse(b.isRunning)
        let after = await failure("listGroups")
        XCTAssertTrue(after.contains("not running"), after)
        XCTAssertEqual(stopped, []) // stopping on purpose is not reported as a failure
        // It can be started again in the same process.
        b.start(account: "+15550000000")
        let again = await failure("noSuchMethod")
        XCTAssertTrue(again.contains("Method not found"), again)
        b.stop()
    }

    func testRunEndsWithItsInput() {
        let ended = expectation(description: "exit")
        let run = EmbeddedRun(arguments: ["--config", dir.path, "--store-key-stdin", "-a", "+1555", "jsonRpc"],
                              onLine: { _, _ in }, onExit: { code in
            XCTAssertEqual(code, 0)
            ended.fulfill()
        })
        XCTAssertNotNil(run)
        run?.send(String(repeating: "5a", count: 32))
        run?.closeInput()
        XCTAssertEqual(run?.send("{}"), false)
        wait(for: [ended], timeout: 20)
    }
}
