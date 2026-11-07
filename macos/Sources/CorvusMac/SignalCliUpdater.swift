import AppKit
import CorvusCore
import CryptoKit
import Foundation

/// Keeps signal-cli up to date: a self-managed install (`…/signal-cli-<version>/bin/signal-cli`) gets the
/// new release archive unpacked next to it (checked against the SHA-256 that GitHub publishes, and tried
/// with `--version` before it is used); a Homebrew install is upgraded with brew. The switch waits for the
/// end of a call. The previous version is kept; older ones are deleted.
extension AppModel {
    static let autoUpdateKey = "signalCliAutoUpdate"

    var signalCliAutoUpdate: Bool {
        get { UserDefaults.standard.object(forKey: Self.autoUpdateKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: Self.autoUpdateKey) }
    }

    /// Checks now and then every 12 hours while the app runs.
    func startUpdateChecks() {
        guard !updateChecksStarted else { return }
        updateChecksStarted = true
        Task { [weak self] in
            while true {
                self?.checkForUpdates(silent: true)
                try? await Task.sleep(for: .seconds(12 * 3600))
                if self == nil { return }
            }
        }
    }

    func checkForUpdates(silent: Bool) {
        guard !updatingCli else {
            if !silent { showFlash("signal-cli is being updated …", seconds: 3) }
            return
        }
        Task {
            var req = URLRequest(url: URL(string: "https://api.github.com/repos/AsamK/signal-cli/releases/latest")!)
            req.setValue("corvus", forHTTPHeaderField: "User-Agent")
            req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            let o: JSON
            do {
                let (data, _) = try await URLSession.shared.data(for: req)
                o = (try JSONSerialization.jsonObject(with: data)) as? JSON ?? [:]
            } catch {
                if !silent { await Dialogs.warn("Update check", "Could not reach GitHub:\n\(error.localizedDescription)") }
                return
            }
            guard let release = SignalCliUpdate.release(fromGitHub: o) else {
                if !silent { await Dialogs.info("Update check", "No installable signal-cli release was found.") }
                return
            }
            let page = URL(string: jsonString(o["html_url"])) ?? URL(string: "https://github.com/AsamK/signal-cli/releases")!
            guard !version.isEmpty, AppModel.compareVersions(release.version, version) == .orderedDescending else {
                updateHint = nil
                if !silent {
                    await Dialogs.info("Update check", version.isEmpty ? "The installed signal-cli version is not known yet."
                                           : "signal-cli \(version) is up to date.")
                }
                return
            }
            let exe = cli.executable
            let updatable = SignalCliUpdate.managedInstall(exe) != nil || SignalCliUpdate.homebrew(exe) != nil
            if updatable && (!silent || signalCliAutoUpdate) {
                await installSignalCliUpdate(release, page: page, interactive: !silent)
                return
            }
            updateHint = UpdateHint(version: release.version, url: page)
            guard !silent else { return }
            let r = await Dialogs.ask("Update available",
                                      "Installed: signal-cli \(version)\nLatest version: signal-cli \(release.version)\n\n"
                                          + "This signal-cli was not installed in a way Corvus can update (\(exe)). Update it the way "
                                          + "you installed it, then choose “File → Reconnect”.",
                                      buttons: ["Open release page", "Close"])
            if r == 0 { NSWorkspace.shared.open(page) }
        }
    }

    private func installSignalCliUpdate(_ release: SignalCliUpdate.Release, page: URL, interactive: Bool) async {
        updatingCli = true
        defer { updatingCli = false }
        let old = version, oldExe = cli.executable
        if interactive { showFlash("Updating signal-cli to \(release.version) …", seconds: 900) }
        SignalCli.log("update: signal-cli \(old) -> \(release.version)")
        do {
            let newExe: String
            if let m = SignalCliUpdate.managedInstall(oldExe) {
                newExe = try await SignalCliInstaller.install(release, root: m.root)
            } else if let brew = SignalCliUpdate.homebrew(oldExe) {
                try await SignalCliInstaller.brewUpgrade(brew)
                newExe = oldExe
            } else {
                return
            }
            // Restarting signal-cli ends a call: wait for it to end.
            while call?.isActive == true { try? await Task.sleep(for: .seconds(20)) }
            UserDefaults.standard.set(newExe, forKey: "executable")
            cli.executable = newExe
            fullCheckNext = true // read the new version
            await connectAccount()
            if let m = SignalCliUpdate.managedInstall(newExe) {
                SignalCliInstaller.removeOld(root: m.root, current: m.version, previous: SignalCliUpdate.managedInstall(oldExe)?.version ?? "")
            }
            updateHint = nil
            showFlash("signal-cli updated to \(release.version)", seconds: 4)
        } catch {
            SignalCli.log("update failed: \(error.localizedDescription)")
            updateHint = UpdateHint(version: release.version, url: page)
            if interactive {
                clearFlash()
                await Dialogs.warn("signal-cli update", "signal-cli could not be updated to \(release.version); "
                                       + "signal-cli \(old) stays in use.\n\n\(error.localizedDescription)")
            }
        }
    }
}

enum SignalCliInstaller {
    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// Downloads, checks and unpacks the release next to the current version; returns the new executable.
    static func install(_ release: SignalCliUpdate.Release, root: URL) async throws -> String {
        let fm = FileManager.default
        let exe = SignalCliUpdate.executable(root: root, version: release.version)
        if fm.isExecutableFile(atPath: exe.path), try await works(exe.path, version: release.version) { return exe.path }

        let (download, response) = try await URLSession.shared.download(from: release.archiveURL)
        defer { try? fm.removeItem(at: download) }
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw Failure(message: "The download failed.") }
        let digest = try await Task.detached(priority: .utility) { () throws -> String in
            let data = try Data(contentsOf: download, options: .mappedIfSafe)
            return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        }.value
        guard digest == release.sha256 else { throw Failure(message: "The downloaded archive does not match its published checksum.") }

        let staging = root.appendingPathComponent(".update-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: staging) }
        try await run("/usr/bin/tar", ["-xzf", download.path, "-C", staging.path], timeout: 300)
        let unpacked = staging.appendingPathComponent("signal-cli-\(release.version)", isDirectory: true)
        let unpackedExe = unpacked.appendingPathComponent("bin/signal-cli")
        guard fm.isExecutableFile(atPath: unpackedExe.path) else { throw Failure(message: "The archive does not contain signal-cli.") }
        guard try await works(unpackedExe.path, version: release.version) else {
            throw Failure(message: "The new signal-cli did not start (it may need a newer Java).")
        }
        let target = root.appendingPathComponent("signal-cli-\(release.version)", isDirectory: true)
        if fm.fileExists(atPath: target.path) { try fm.removeItem(at: target) }
        try fm.moveItem(at: unpacked, to: target)
        return exe.path
    }

    private static func works(_ exe: String, version: String) async throws -> Bool {
        let (_, line) = await Task.detached(priority: .utility) { SignalCli.versionLine(of: exe) }.value
        return line.split(separator: " ").last.map(String.init) == version
    }

    static func brewUpgrade(_ brew: String) async throws {
        try await run(brew, ["upgrade", "signal-cli"], timeout: 1800)
    }

    /// Deletes `signal-cli-<version>` folders other than the current and the previous version.
    static func removeOld(root: URL, current: String, previous: String) {
        let fm = FileManager.default
        let names = (try? fm.contentsOfDirectory(atPath: root.path)) ?? []
        let versions = names.filter { $0.hasPrefix("signal-cli-") }.map { String($0.dropFirst("signal-cli-".count)) }
        for v in SignalCliUpdate.obsoleteVersions(versions, current: current, previous: previous) {
            try? fm.removeItem(at: root.appendingPathComponent("signal-cli-\(v)", isDirectory: true))
        }
    }

    private static func run(_ tool: String, _ args: [String], timeout: TimeInterval) async throws {
        try await Task.detached(priority: .utility) {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: tool)
            p.arguments = args
            var env = ProcessInfo.processInfo.environment
            env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
            p.environment = env
            p.standardInput = FileHandle.nullDevice
            p.standardOutput = FileHandle.nullDevice
            let err = Pipe()
            p.standardError = err
            try p.run()
            let done = DispatchSemaphore(value: 0)
            DispatchQueue.global().async { p.waitUntilExit(); done.signal() }
            var errData = Data()
            DispatchQueue.global().async { errData = err.fileHandleForReading.readDataToEndOfFile() }
            if done.wait(timeout: .now() + timeout) == .timedOut {
                p.terminate()
                throw Failure(message: "\((tool as NSString).lastPathComponent) took too long.")
            }
            guard p.terminationStatus == 0 else {
                let msg = String(decoding: errData, as: UTF8.self).split(separator: "\n").last.map(String.init) ?? ""
                throw Failure(message: "\((tool as NSString).lastPathComponent) failed (\(p.terminationStatus)). \(msg)")
            }
        }.value
    }
}
