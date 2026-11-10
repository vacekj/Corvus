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

/// The Signal backend: `corvus-signal` (signal-backend/ in the repository). It is linked into the app
/// and runs inside it (`EmbeddedRun`): one-shot commands (`--version`, `listAccounts`, `link`,
/// `deleteLocalAccountData`) and the long-running `-a <account> jsonRpc`, which speaks signal-cli's
/// JSON-RPC protocol, line by line as the process did over its pipes. With another executable set
/// (`CORVUS_SIGNAL_BIN`, or `executable` in tests with a mock) it is started as a process instead.
///
/// Every command except `--version` gets `--config <data dir> --store-key-stdin`: the first line Corvus
/// gives it as input is the key of the encrypted store (kept in the keychain, `SignalStoreKey`).
@MainActor
public final class SignalBackend {
    /// Where the backend is: the app's own executable while it runs inside the app, else the process to start.
    public var executable = SignalBackend.bundledExecutable() { didSet { embedded = false } }
    /// The backend runs inside this process (the default; not with another executable set).
    public private(set) var embedded = SignalBackend.embeddedByDefault()
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
    private var embeddedRun: EmbeddedRun?
    /// Signalled when the current embedded run has ended (it closes its store on the way out).
    private var embeddedEnded: DispatchSemaphore?
    private var stdinPipe: Pipe?
    private var buffer = Data()
    private var lastErrLine = ""
    /// Keeps App Nap away while connected: a napping app throttles the backend too, its websocket keepalives
    /// stall, the server drops the connection and messages only arrive after the next reconnect.
    private var activity: NSObjectProtocol?
    private var nextId = 1
    private var pending: [Int: CheckedContinuation<Any, Error>] = [:]

    public init() {}

    public var isRunning: Bool { proc != nil || embeddedRun != nil }

    // MARK: - Helpers

    nonisolated public static let binaryName = "corvus-signal"

    /// The backend is part of the app's executable; `CORVUS_SIGNAL_BIN` points to a backend to start as a
    /// process instead (development, tests with a mock).
    nonisolated public static func bundledExecutable(environment: [String: String] = ProcessInfo.processInfo.environment,
                                                     mainExecutable: URL? = Bundle.main.executableURL) -> String {
        if let dev = environment["CORVUS_SIGNAL_BIN"], !dev.isEmpty { return dev }
        return (mainExecutable ?? Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/corvus")).path
    }

    nonisolated public static func embeddedByDefault(environment: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
        (environment["CORVUS_SIGNAL_BIN"] ?? "").isEmpty
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

    nonisolated static func logResult(exe: String, args: [String], _ r: CliResult) {
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
        if embedded {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            return await Task.detached { SignalBackend.runEmbedded(args: full, storeKey: key, timeout: timeout) }.value
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
        if embedded {
            startEmbedded(account: account, key: key)
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

    /// The JSON-RPC run inside this process: the same lines as over the pipes of the process.
    private func startEmbedded(account: String, key: String) {
        try? FileManager.default.createDirectory(at: dataDir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        buffer.removeAll()
        lastErrLine = ""
        // The callbacks only know the run by this token: a run that was stopped must not be heard any more.
        final class Token: @unchecked Sendable { var run: EmbeddedRun? }
        let token = Token()
        let ended = DispatchSemaphore(value: 0)
        let run = EmbeddedRun(arguments: arguments(["-a", account, "jsonRpc"]), onLine: { [weak self] stream, line in
            Task { @MainActor in
                guard let self, let run = token.run, run === self.embeddedRun else { return }
                if stream == .output {
                    let trimmed = line.drop(while: { $0 == " " || $0 == "\r" })
                    if !trimmed.isEmpty { self.handleLine(Data(trimmed.utf8)) }
                } else {
                    self.errorLine(line, current: true)
                }
            }
        }, onExit: { [weak self] code in
            ended.signal()
            Task { @MainActor in
                guard let self, let run = token.run, run === self.embeddedRun else { return }
                self.embeddedRun = nil
                self.endActivity()
                var reason = "The Signal backend stopped (exit code \(code))"
                if !self.lastErrLine.isEmpty { reason += ": " + self.lastErrLine }
                self.failPending(reason)
                self.onStopped?(reason)
            }
        })
        guard let run else {
            failPending("The Signal backend could not be started.")
            onStopped?("The Signal backend could not be started.")
            return
        }
        token.run = run
        embeddedRun = run
        embeddedEnded = ended
        run.send(key) // first line, before any request
        activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiatedAllowingIdleSystemSleep],
                                                         reason: "Receiving Signal messages")
    }

    private func endActivity() {
        if let a = activity { ProcessInfo.processInfo.endActivity(a) }
        activity = nil
    }

    /// Stops the backend. `wait` (seconds) gives a backend inside the app that long to close its store
    /// before this returns: when the app quits, nothing else would wait for it.
    public func stop(wait: TimeInterval = 0) {
        if let run = embeddedRun {
            embeddedRun = nil
            endActivity()
            run.closeInput() // the backend closes its store and ends; its last lines are not heard
            if wait > 0 { _ = embeddedEnded?.wait(timeout: .now() + wait) }
            embeddedEnded = nil
            failPending("Disconnected")
            return
        }
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
        let id = nextId
        var req: JSON = ["jsonrpc": "2.0", "method": method, "id": id]
        if !params.isEmpty { req["params"] = params }
        var data = try JSONSerialization.data(withJSONObject: req)
        if let run = embeddedRun {
            nextId += 1
            return try await withCheckedThrowingContinuation { cont in
                pending[id] = cont
                if !run.send(String(decoding: data, as: UTF8.self)) {
                    pending.removeValue(forKey: id)
                    cont.resume(throwing: RpcError("The Signal backend is not running"))
                }
            }
        }
        guard proc != nil, let input = stdinPipe else { throw RpcError("The Signal backend is not running") }
        nextId += 1
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
            errorLine(String(l), current: p === proc)
        }
    }

    /// A line the backend wrote for the user (standard error).
    private func errorLine(_ l: String, current: Bool) {
        guard !l.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        if current { lastErrLine = l.trimmingCharacters(in: .whitespaces) }
        SignalBackend.log(SignalBackend.maskNumbers(l))
        onLogLine?(l)
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
