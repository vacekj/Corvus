import Foundation

/// Result of a one-shot backend call.
public struct CliResult: Sendable {
    public var ok = false          // started, exited normally with code 0
    public var timedOut = false
    public var exitCode: Int32 = -1
    public var out = ""
    public var err = ""
    public var startError = ""     // set when the process could not be started at all
    public var command = ""        // for diagnostics
    public var ms: Int64 = 0

    public init() {}

    /// Human-readable description of what went wrong ("" if ok).
    public func describe() -> String {
        if ok { return "" }
        if !startError.isEmpty { return "The Signal backend could not be started: \(startError)" }
        if timedOut { return "The Signal backend did not answer in time." }
        var text = "The Signal backend exited with code \(exitCode)."
        let e = err.trimmingCharacters(in: .whitespacesAndNewlines)
        if !e.isEmpty { text += "\n\n" + (e.count > 700 ? String(e.prefix(700)) + "…" : e) }
        return text
    }
}

public struct RpcError: Error, LocalizedError {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

/// The Signal backend: `corvus-signal` (signal-backend/ in the repository), bundled as
/// `Contents/MacOS/corvus-signal` next to the app's executable. It is started for one-shot commands
/// (`--version`, `listAccounts`, `link`, `deleteLocalAccountData`) and as the long-running
/// `-a <account> jsonRpc` process, and speaks signal-cli's JSON-RPC protocol.
///
/// Every command except `--version` gets `--config <data dir> --store-key-stdin`: the first line Corvus
/// writes to its stdin is the key of the encrypted store (kept in the keychain, `SignalStoreKey`).
@MainActor
public final class SignalBackend {
    public var executable = SignalBackend.bundledExecutable()
    /// `--config`: where the backend keeps its store, attachments and avatars.
    public var dataDir = SignalDataDir.root
    /// The store key written as the first stdin line (tests use a fixed one instead of the keychain).
    public lazy var storeKey: () throws -> String = { [dataDir] in try SignalStoreKey.loadOrCreate(dataDir: dataDir) }
    /// Global options put after `--config` before every command except `--version` (e.g. `--tls-proxy host`).
    public var globalOptions: [String] = []

    public var onEnvelope: ((JSON) -> Void)?
    public var onCallEvent: ((JSON) -> Void)?
    /// Contacts or groups changed outside a message (sync from the phone): list them again.
    public var onRosterChanged: (() -> Void)?
    public var onStopped: ((String) -> Void)?
    public var onLogLine: ((String) -> Void)?

    private var proc: Process?
    private var stdinPipe: Pipe?
    private var buffer = Data()
    private var lastErrLine = ""
    /// Keeps App Nap away while connected: a napping app throttles the backend too, its websocket keepalives
    /// stall, the server drops the connection and messages only arrive after the next reconnect.
    private var activity: NSObjectProtocol?
    private var nextId = 1
    private var pending: [Int: CheckedContinuation<Any, Error>] = [:]

    public init() {}

    public var isRunning: Bool { proc != nil }

    // MARK: - Helpers

    nonisolated public static let binaryName = "corvus-signal"

    /// `Contents/MacOS/corvus-signal` next to the app's executable (with `swift run`: next to the built
    /// binary); `CORVUS_SIGNAL_BIN` points elsewhere (development).
    nonisolated public static func bundledExecutable(environment: [String: String] = ProcessInfo.processInfo.environment,
                                                     mainExecutable: URL? = Bundle.main.executableURL) -> String {
        if let dev = environment["CORVUS_SIGNAL_BIN"], !dev.isEmpty { return dev }
        let dir = mainExecutable?.deletingLastPathComponent() ?? Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS")
        return dir.appendingPathComponent(binaryName).path
    }

    /// The full argv after the executable: `--version` alone, everything else with the data dir, the store key
    /// on stdin and the global options first.
    nonisolated public static func arguments(_ args: [String], dataDir: URL, globalOptions: [String]) -> [String] {
        if args == ["--version"] { return args }
        return ["--config", dataDir.path, "--store-key-stdin"] + globalOptions + args
    }

    /// `arguments` for this backend's settings.
    public func arguments(_ args: [String]) -> [String] {
        SignalBackend.arguments(args, dataDir: dataDir, globalOptions: globalOptions)
    }

    /// A process for `args` (see `arguments`), not started yet. After `run()` the caller writes the store key
    /// with `sendStoreKey` (unless it is `--version`).
    public func makeProcess(_ args: [String]) -> Process {
        SignalBackend.makeProcess(exe: executable, arguments: arguments(args), dataDir: dataDir)
    }

    nonisolated static func makeProcess(exe: String, arguments: [String], dataDir: URL) -> Process {
        try? FileManager.default.createDirectory(at: dataDir, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = arguments
        p.environment = childEnvironment()
        return p
    }

    /// A pipe for the child's stdin that reports a closed reader as an error instead of killing Corvus with SIGPIPE.
    nonisolated public static func inputPipe() -> Pipe {
        let pipe = Pipe()
        _ = fcntl(pipe.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
        return pipe
    }

    /// Writes the store key as the first line of the child's stdin.
    nonisolated public static func sendStoreKey(_ key: String, to pipe: Pipe) throws {
        try pipe.fileHandleForWriting.write(contentsOf: Data((key + "\n").utf8))
    }

    /// Environment for child processes. Apps started from Finder get a minimal PATH; voice calls need
    /// `signal-call-tunnel`, which `cargo install` puts into ~/.cargo/bin.
    nonisolated public static func childEnvironment(_ base: [String: String] = ProcessInfo.processInfo.environment) -> [String: String] {
        var env = base
        var path = (env["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin").split(separator: ":").map(String.init)
        let cargo = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".cargo/bin").path
        for extra in ["/opt/homebrew/bin", "/usr/local/bin", cargo] where !path.contains(extra) {
            path.append(extra)
        }
        env["PATH"] = path.joined(separator: ":")
        return env
    }

    /// Phone numbers are masked in diagnostics unless CORVUS_DEBUG is set.
    nonisolated public static func maskNumbers(_ text: String) -> String {
        if ProcessInfo.processInfo.environment["CORVUS_DEBUG"] != nil { return text }
        let re = try! NSRegularExpression(pattern: #"\+?(\d{2})\d{5,}(\d{2})"#)
        return re.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: "+$1…$2")
    }

    nonisolated public static func parseAccounts(_ out: String) -> [String] {
        var result: [String] = []
        func add(_ n: String) {
            if !n.isEmpty && !result.contains(n) { result.append(n) }
        }
        if let data = out.data(using: .utf8),
           let arr = (try? JSONSerialization.jsonObject(with: data)) as? [Any] {
            for v in arr {
                if let s = v as? String { add(s) } else { add(jsonString(jsonObject(v)["number"])) }
            }
            return result
        }
        // Fallback: plain text ("Number: +49…") or JSON preceded by warnings
        let re = try! NSRegularExpression(pattern: #"(\+\d{5,})"#)
        for m in re.matches(in: out, range: NSRange(out.startIndex..., in: out)) {
            if let r = Range(m.range(at: 1), in: out) { add(String(out[r])) }
        }
        return result
    }

    nonisolated public static func log(_ line: String) {
        FileHandle.standardError.write(Data((line + "\n").utf8))
    }

    nonisolated private static func logResult(exe: String, args: [String], _ r: CliResult) {
        func show(_ t: String) -> String {
            var t = maskNumbers(t.trimmingCharacters(in: .whitespacesAndNewlines))
            t = t.replacingOccurrences(of: "\n", with: " ⏎ ")
            return t.count > 300 ? String(t.prefix(300)) + "…" : t
        }
        let status = r.ok ? "ok" : !r.startError.isEmpty ? "START FAILED: " + r.startError
            : r.timedOut ? "TIMEOUT" : "exit code \(r.exitCode)"
        var line = "backend: \((exe as NSString).lastPathComponent) \(args.joined(separator: " ")) -> \(status) (\(r.ms) ms)"
        if !r.out.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { line += " | stdout: " + show(r.out) }
        if !r.err.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { line += " | stderr: " + show(r.err) }
        log(line)
    }

    // MARK: - One-shot calls (never block the GUI)

    public func run(_ args: [String], timeout: TimeInterval) async -> CliResult {
        let exe = executable, dir = dataDir
        let full = arguments(args)
        var key: String?
        if args != ["--version"] {
            do {
                key = try storeKey()
            } catch {
                var r = CliResult()
                r.command = exe + " " + full.joined(separator: " ")
                r.startError = "The store key could not be read from the keychain: \(error.localizedDescription)"
                return r
            }
        }
        return await Task.detached { SignalBackend.runBlocking(exe: exe, args: full, dataDir: dir, storeKey: key, timeout: timeout) }.value
    }

    nonisolated static func runBlocking(exe: String, args: [String], dataDir: URL, storeKey: String?, timeout: TimeInterval) -> CliResult {
        var r = CliResult()
        r.command = exe + " " + args.joined(separator: " ")
        let start = Date()
        let p = makeProcess(exe: exe, arguments: args, dataDir: dataDir)
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        // The store key is the first stdin line; stdin stays open until the command has finished.
        let input = storeKey == nil ? nil : inputPipe()
        p.standardInput = input ?? FileHandle.nullDevice
        defer { try? input?.fileHandleForWriting.close() }
        do {
            try p.run()
        } catch {
            r.startError = error.localizedDescription
            r.ms = Int64(Date().timeIntervalSince(start) * 1000)
            logResult(exe: exe, args: args, r)
            return r
        }
        if let input, let storeKey { try? sendStoreKey(storeKey, to: input) }
        // Read both pipes concurrently so a chatty process can never block on a full pipe.
        var outData = Data(), errData = Data()
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global().async { outData = out.fileHandleForReading.readDataToEndOfFile(); group.leave() }
        group.enter()
        DispatchQueue.global().async { errData = err.fileHandleForReading.readDataToEndOfFile(); group.leave() }

        let exited = DispatchSemaphore(value: 0)
        DispatchQueue.global().async { p.waitUntilExit(); exited.signal() }
        if exited.wait(timeout: .now() + timeout) == .timedOut {
            p.terminate()
            if exited.wait(timeout: .now() + 1) == .timedOut { kill(p.processIdentifier, SIGKILL) }
            r.timedOut = true
        }
        if group.wait(timeout: .now() + 2) == .success { // otherwise the readers may still be writing
            r.out = String(decoding: outData, as: UTF8.self)
            r.err = String(decoding: errData, as: UTF8.self)
        }
        if !r.timedOut {
            r.exitCode = p.terminationStatus
            r.ok = p.terminationReason == .exit && r.exitCode == 0
        }
        r.ms = Int64(Date().timeIntervalSince(start) * 1000)
        logResult(exe: exe, args: args, r)
        return r
    }

    /// "corvus-signal 0.1.0" -> (result, first output line)
    public func queryVersion() async -> (CliResult, String) {
        let r = await run(["--version"], timeout: 60)
        let first = r.out.split(separator: "\n", omittingEmptySubsequences: false).first.map(String.init) ?? ""
        return (r, first.trimmingCharacters(in: .whitespaces))
    }

    public func queryAccounts() async -> (CliResult, [String]) {
        let r = await run(["-o", "json", "listAccounts"], timeout: 60)
        return (r, SignalBackend.parseAccounts(r.out))
    }

    // MARK: - Long-running process (JSON-RPC over stdin/stdout)

    public func start(account: String) {
        stop()
        let key: String
        do {
            key = try storeKey()
        } catch {
            let reason = "The store key could not be read from the keychain: \(error.localizedDescription)"
            failPending(reason)
            onStopped?(reason)
            return
        }
        let p = makeProcess(["-a", account, "jsonRpc"])
        p.qualityOfService = .userInitiated
        let input = SignalBackend.inputPipe(), output = Pipe(), errors = Pipe()
        p.standardInput = input
        p.standardOutput = output
        p.standardError = errors
        buffer.removeAll()
        lastErrLine = ""

        output.fileHandleForReading.readabilityHandler = { [weak self] h in
            let data = h.availableData
            if data.isEmpty { h.readabilityHandler = nil; return }
            Task { @MainActor in self?.onStdout(data, from: p) }
        }
        errors.fileHandleForReading.readabilityHandler = { [weak self] h in
            let data = h.availableData
            if data.isEmpty { h.readabilityHandler = nil; return }
            Task { @MainActor in self?.onStderr(data, from: p) }
        }
        p.terminationHandler = { [weak self] proc in
            let code = proc.terminationStatus
            Task { @MainActor in self?.onExit(proc, code: code) }
        }

        do {
            try p.run()
        } catch {
            output.fileHandleForReading.readabilityHandler = nil
            errors.fileHandleForReading.readabilityHandler = nil
            failPending(error.localizedDescription)
            onStopped?(error.localizedDescription)
            return
        }
        proc = p
        stdinPipe = input
        do {
            try SignalBackend.sendStoreKey(key, to: input) // first line, before any request
        } catch {
            stop()
            onStopped?(error.localizedDescription)
            return
        }
        activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiatedAllowingIdleSystemSleep],
                                                         reason: "Receiving Signal messages")
    }

    private func endActivity() {
        if let a = activity { ProcessInfo.processInfo.endActivity(a) }
        activity = nil
    }

    public func stop() {
        guard let p = proc else { return }
        proc = nil
        endActivity()
        p.terminationHandler = nil
        try? stdinPipe?.fileHandleForWriting.close()
        stdinPipe = nil
        if p.isRunning {
            p.terminate()
            let pid = p.processIdentifier
            DispatchQueue.global().asyncAfter(deadline: .now() + 3) {
                if p.isRunning { kill(pid, SIGKILL) }
            }
        }
        failPending("Disconnected")
    }

    /// Sends a JSON-RPC request; returns its "result" or throws its error message.
    @discardableResult
    public func call(_ method: String, _ params: JSON = [:]) async throws -> Any {
        guard proc != nil, let input = stdinPipe else { throw RpcError("The Signal backend is not running") }
        let id = nextId
        nextId += 1
        var req: JSON = ["jsonrpc": "2.0", "method": method, "id": id]
        if !params.isEmpty { req["params"] = params }
        var data = try JSONSerialization.data(withJSONObject: req)
        data.append(0x0A)
        return try await withCheckedThrowingContinuation { cont in
            pending[id] = cont
            do {
                try input.fileHandleForWriting.write(contentsOf: data)
            } catch {
                pending.removeValue(forKey: id)
                cont.resume(throwing: RpcError(error.localizedDescription))
            }
        }
    }

    private func onStdout(_ data: Data, from p: Process) {
        guard p === proc else { return }
        buffer.append(data)
        while let nl = buffer.firstIndex(of: 0x0A) {
            let line = buffer[buffer.startIndex..<nl]
            buffer.removeSubrange(buffer.startIndex...nl)
            let trimmed = line.drop(while: { $0 == 0x20 || $0 == 0x0D })
            if !trimmed.isEmpty { handleLine(Data(trimmed)) }
        }
    }

    private func onStderr(_ data: Data, from p: Process) {
        let s = String(decoding: data, as: UTF8.self)
        for l in s.split(separator: "\n") where !l.trimmingCharacters(in: .whitespaces).isEmpty {
            if p === proc { lastErrLine = l.trimmingCharacters(in: .whitespaces) }
            SignalBackend.log(SignalBackend.maskNumbers(String(l)))
            onLogLine?(String(l))
        }
    }

    private func onExit(_ p: Process, code: Int32) {
        guard p === proc else { return }
        proc = nil
        stdinPipe = nil
        endActivity()
        var reason = "The Signal backend exited (exit code \(code))"
        if !lastErrLine.isEmpty { reason += ": " + lastErrLine }
        failPending(reason)
        onStopped?(reason)
    }

    private func handleLine(_ line: Data) {
        guard let o = (try? JSONSerialization.jsonObject(with: line)) as? JSON else {
            onLogLine?(String(decoding: line, as: UTF8.self))
            return
        }
        // Response to a call
        if let idv = o["id"] as? NSNumber, o["method"] == nil {
            guard let cont = pending.removeValue(forKey: idv.intValue) else { return }
            if let e = o["error"] {
                let msg = (e as? JSON)?["message"] as? String ?? "Unknown error"
                cont.resume(throwing: RpcError(msg))
            } else {
                cont.resume(returning: o["result"] ?? NSNull())
            }
            return
        }
        // Notification (incoming message)
        if jsonString(o["method"]) == "receive" {
            let params = jsonObject(o["params"])
            var env = jsonObject(params["envelope"])
            if env.isEmpty { env = jsonObject(jsonObject(params["result"])["envelope"]) }
            if !env.isEmpty { onEnvelope?(env) }
        } else if jsonString(o["method"]) == "callEvent" {
            // Voice calls (after subscribeCallEvents): {"subscription": n, "result": {...}}
            let params = jsonObject(o["params"])
            let ev = jsonObject(params["result"])
            if !ev.isEmpty { onCallEvent?(ev) }
        } else if jsonString(o["method"]) == "rosterChanged" {
            onRosterChanged?()
        }
    }

    private func failPending(_ reason: String) {
        let all = pending
        pending.removeAll()
        for (_, c) in all { c.resume(throwing: RpcError(reason)) }
    }
}
