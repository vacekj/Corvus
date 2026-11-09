import XCTest
@testable import CorvusCore

final class SignalCliUpdateTests: XCTestCase {
    private func asset(_ name: String, digest: String? = "sha256:" + String(repeating: "ab", count: 32),
                       host: String = "github.com") -> [String: Any] {
        var a: [String: Any] = ["name": name, "browser_download_url": "https://\(host)/AsamK/signal-cli/releases/download/x/\(name)"]
        if let digest { a["digest"] = digest }
        return a
    }

    func testPicksTheJvmArchiveWithItsDigest() {
        let o: [String: Any] = ["tag_name": "v0.14.10", "assets": [asset("signal-cli-0.14.10-Linux-native.tar.gz"),
                                                                    asset("signal-cli-0.14.10.tar.gz.asc"),
                                                                    asset("signal-cli-0.14.10.tar.gz")]]
        let r = SignalCliUpdate.release(fromGitHub: o)
        XCTAssertEqual(r?.version, "0.14.10")
        XCTAssertEqual(r?.archiveURL.lastPathComponent, "signal-cli-0.14.10.tar.gz")
        XCTAssertEqual(r?.sha256, String(repeating: "ab", count: 32))
    }

    func testRefusesUncheckableOrOddReleases() {
        XCTAssertNil(SignalCliUpdate.release(fromGitHub: ["tag_name": "v0.14.10", "assets": [asset("signal-cli-0.14.10.tar.gz", digest: nil)]]))
        XCTAssertNil(SignalCliUpdate.release(fromGitHub: ["tag_name": "v0.14.10", "assets": [asset("signal-cli-0.14.10.tar.gz", host: "example.com")]]))
        XCTAssertNil(SignalCliUpdate.release(fromGitHub: ["tag_name": "v0.14.10", "prerelease": true, "assets": [asset("signal-cli-0.14.10.tar.gz")]]))
        XCTAssertNil(SignalCliUpdate.release(fromGitHub: ["tag_name": "v../../x", "assets": [asset("signal-cli-../../x.tar.gz")]]))
        XCTAssertNil(SignalCliUpdate.release(fromGitHub: ["tag_name": "v0.14.10", "assets": [asset("signal-cli-0.14.10.tar.gz", digest: "sha256:xyz")]]))
    }

    func testManagedInstallLayout() {
        let m = SignalCliUpdate.managedInstall("/Users/me/.local/share/signal-cli-jvm/signal-cli-0.14.9/bin/signal-cli")
        XCTAssertEqual(m?.root.path, "/Users/me/.local/share/signal-cli-jvm")
        XCTAssertEqual(m?.version, "0.14.9")
        XCTAssertEqual(SignalCliUpdate.executable(root: m!.root, version: "0.14.10").path,
                       "/Users/me/.local/share/signal-cli-jvm/signal-cli-0.14.10/bin/signal-cli")
        XCTAssertNil(SignalCliUpdate.managedInstall("/opt/homebrew/bin/signal-cli"))
        XCTAssertNil(SignalCliUpdate.managedInstall("/x/signal-cli-latest/bin/signal-cli"))
    }

    func testOldVersionsToDelete() {
        XCTAssertEqual(SignalCliUpdate.obsoleteVersions(["0.14.8", "0.14.9", "0.14.10", "junk"], current: "0.14.10", previous: "0.14.9"),
                       ["0.14.8"])
    }
}
