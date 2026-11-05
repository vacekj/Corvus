import Foundation

/// Result of a one-shot signal-cli call.
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
        if !startError.isEmpty { return "signal-cli could not be started: \(startError)" }
        if timedOut { return "signal-cli did not answer in time." }
        var text = "signal-cli exited with code \(exitCode)."
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

/// Thin layer around the externally installed signal-cli.
/// Only the CLI program is invoked (one-shot commands and "signal-cli -a <account> jsonRpc" as a
/// long-running process). There is no dependency on signal-cli internals, so signal-cli can be
/// updated independently of this GUI.
@MainActor
public final class SignalCli {
    public var executable = ""

    public var onEnvelope: ((JSON) -> Void)?
    public var onCallEvent: ((JSON) -> Void)?
    public var onStopped: ((String) -> Void)?
    public var onLogLine: ((String) -> Void)?

    private var proc: Process?
    private var stdinPipe: Pipe?
    private var buffer = Data()
    private var lastErrLine = ""
    /// Keeps App Nap away while connected: a napping app throttles signal-cli too, its websocket keepalives
    /// stall, the server drops the connection and messages only arrive after the next reconnect.
    private var activity: NSObjectProtocol?
    private var nextId = 1
    private var pending: [Int: CheckedContinuation<Any, Error>] = [:]

    public init() {}

    public var isRunning: Bool { proc != nil }

    // MARK: - Helpers

    nonisolated public static func autodetect(environment: [String: String] = ProcessInfo.processInfo.environment) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        var dirs = (environment["PATH"] ?? "").split(separator: ":").map(String.init)
        dirs += ["/opt/homebrew/bin", "/usr/local/bin", "/opt/signal-cli/bin", home + "/.local/bin", home + "/bin"]
        for d in dirs {
            let p = (d as NSString).appendingPathComponent("signal-cli")
            if FileManager.default.isExecutableFile(atPath: p) { return p }
        }
        return ""
    }

    /// Points `p` at signal-cli; inside the app bundle through the helper app (src/SignalCliHelper.cpp).
    nonisolated public static func configure(_ p: Process, executable: String, arguments: [String]) {
        let helper = Bundle.main.bundleURL
            .appendingPathComponent("Contents/Helpers/corvus-signal-cli.app/Contents/MacOS/corvus-signal-cli")
        // A missing signal-cli is started directly, so run() throws right away.
        if FileManager.default.isExecutableFile(atPath: helper.path), FileManager.default.isExecutableFile(atPath: executable) {
            p.executableURL = helper
            p.arguments = [executable] + arguments
        } else {
            p.executableURL = URL(fileURLWithPath: executable)
            p.arguments = arguments
        }
    }

    /// Environment for child processes. Apps started from Finder get a minimal PATH; signal-cli
    /// (a shell script that starts Java) needs the usual Homebrew locations to find `java`.
    nonisolated public static func childEnvironment(_ base: [String: String] = ProcessInfo.processInfo.environment) -> [String: String] {
        var env = base
        var path = (env["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin").split(separator: ":").map(String.init)
        // ~/.cargo/bin: `cargo install` puts signal-call-tunnel (needed for voice calls) there.
        let cargo = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".cargo/bin").path
        for extra in ["/opt/homebrew/bin", "/usr/local/bin", cargo] where !path.contains(extra) {
            path.append(extra)
        }
        env["PATH"] = path.joined(separator: ":")
        return env
    }

    /// The Java build of signal-cli is a shell script; the native build is a Mach-O binary.
    nonisolated public static func isJavaLauncher(_ executable: String) -> Bool {
        guard let h = FileHandle(forReadingAtPath: executable) else { return false }
        defer { try? h.close() }
        return h.readData(ofLength: 2) == Data("#!".utf8)
    }

    /// Faster JVM start for the long-running jsonRpc process: the classes signal-cli loads are kept in a
    /// class-data-sharing archive that the JVM creates on the first run and maps on later ones (~25 % faster
    /// to the first answer). JVM log output goes to stderr so stdout stays JSON only.
    nonisolated public static func javaEnvironment(_ env: [String: String], executable: String) -> [String: String] {
        guard isJavaLauncher(executable), env["CORVUS_NO_CDS"] == nil else { return env }
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("io.github.corvus.mac", isDirectory: true)
        try? FileManager.default.createDirectory(at: caches, withIntermediateDirectories: true)
        // One archive per signal-cli installation (an upgrade makes the JVM rebuild it anyway).
        let stable = executable.utf8.reduce(UInt64(1469598103934665603)) { ($0 ^ UInt64($1)) &* 1099511628211 }
        let archive = caches.appendingPathComponent("signal-cli-\(String(stable, radix: 36)).jsa").path
        var env = env
        let opts = "-Xlog:disable -Xlog:all=warning:stderr -XX:+AutoCreateSharedArchive -XX:SharedArchiveFile=\(archive)"
        env["JAVA_OPTS"] = [env["JAVA_OPTS"], opts].compactMap { $0 }.joined(separator: " ")
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

    nonisolated static func log(_ line: String) {
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
        var line = "signal-cli: \((exe as NSString).lastPathComponent) \(args.joined(separator: " ")) -> \(status) (\(r.ms) ms)"
        if !r.out.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { line += " | stdout: " + show(r.out) }
        if !r.err.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { line += " | stderr: " + show(r.err) }
        log(line)
    }

    // MARK: - One-shot calls (never block the GUI)

    public func run(_ args: [String], timeout: TimeInterval) async -> CliResult {
        let exe = executable
        return await Task.detached { SignalCli.runBlocking(exe: exe, args: args, timeout: timeout) }.value
    }

    nonisolated static func runBlocking(exe: String, args: [String], timeout: TimeInterval) -> CliResult {
        var r = CliResult()
        r.command = exe + " " + args.joined(separator: " ")
        let start = Date()
        let p = Process()
        configure(p, executable: exe, arguments: args)
        p.environment = childEnvironment()
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        p.standardInput = FileHandle.nullDevice // signal-cli never needs stdin for these commands
        do {
            try p.run()
        } catch {
            r.startError = error.localizedDescription
            r.ms = Int64(Date().timeIntervalSince(start) * 1000)
            logResult(exe: exe, args: args, r)
            return r
        }
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

    /// "signal-cli 0.13.12" -> (result, first output line)
    public func queryVersion() async -> (CliResult, String) {
        let r = await run(["--version"], timeout: 60)
        let first = r.out.split(separator: "\n", omittingEmptySubsequences: false).first.map(String.init) ?? ""
        return (r, first.trimmingCharacters(in: .whitespaces))
    }

    public func queryAccounts() async -> (CliResult, [String]) {
        let r = await run(["-o", "json", "listAccounts"], timeout: 60)
        return (r, SignalCli.parseAccounts(r.out))
    }

    // MARK: - Long-running process (JSON-RPC over stdin/stdout)

    public func start(account: String) {
        stop()
        let p = Process()
        SignalCli.configure(p, executable: executable, arguments: ["-a", account, "jsonRpc"])
        p.environment = SignalCli.javaEnvironment(SignalCli.childEnvironment(), executable: executable)
        p.qualityOfService = .userInitiated
        let input = Pipe(), output = Pipe(), errors = Pipe()
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
        guard proc != nil, let input = stdinPipe else { throw RpcError("signal-cli is not running") }
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
            SignalCli.log(SignalCli.maskNumbers(String(l)))
            onLogLine?(String(l))
        }
    }

    private func onExit(_ p: Process, code: Int32) {
        guard p === proc else { return }
        proc = nil
        stdinPipe = nil
        endActivity()
        var reason = "signal-cli exited (exit code \(code))"
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
            // Voice calls (signal-cli 0.14.2+, after subscribeCallEvents): {"subscription": n, "result": {...}}
            let params = jsonObject(o["params"])
            let ev = jsonObject(params["result"])
            if !ev.isEmpty { onCallEvent?(ev) }
        }
    }

    private func failPending(_ reason: String) {
        let all = pending
        pending.removeAll()
        for (_, c) in all { c.resume(throwing: RpcError(reason)) }
    }
}
