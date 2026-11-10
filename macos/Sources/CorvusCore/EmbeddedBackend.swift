import CHistoryStore
import Foundation

/// One run of the Signal backend inside this process: a command line of `corvus-signal` on a thread of
/// its own (the backend is linked into the app, `signal-backend/corvus-core`). Its standard output and
/// error arrive line by line, its standard input is fed with `send`; the end of the input ends a
/// `jsonRpc` run and cancels a `link`, as closing the pipe of the process did.
///
/// The callbacks run on the backend's thread.
public final class EmbeddedRun: @unchecked Sendable {
    public enum Stream: Int32, Sendable {
        case output = 1, error = 2
    }

    private var handle: OpaquePointer?
    private let lock = NSLock()
    private let onLine: @Sendable (Stream, String) -> Void
    private let onExit: @Sendable (Int32) -> Void

    /// Starts the run; nil if its thread could not be started.
    public init?(arguments: [String], onLine: @escaping @Sendable (Stream, String) -> Void,
                 onExit: @escaping @Sendable (Int32) -> Void) {
        self.onLine = onLine
        self.onExit = onExit
        // The run holds on to this object until it has ended.
        let ctx = Unmanaged.passRetained(self).toOpaque()
        var argv: [UnsafePointer<CChar>?] = arguments.map { UnsafePointer(strdup($0)) }
        defer { for p in argv { free(UnsafeMutablePointer(mutating: p)) } }
        handle = argv.withUnsafeMutableBufferPointer { buffer in
            cs_run_start(Int32(arguments.count), buffer.baseAddress, { ctx, stream, line in
                guard let ctx, let line else { return }
                let run = Unmanaged<EmbeddedRun>.fromOpaque(ctx).takeUnretainedValue()
                run.onLine(Stream(rawValue: stream) ?? .error, String(cString: line))
            }, { ctx, code in
                guard let ctx else { return }
                let run = Unmanaged<EmbeddedRun>.fromOpaque(ctx).takeRetainedValue()
                run.onExit(code)
            }, ctx)
        }
        if handle == nil {
            Unmanaged<EmbeddedRun>.fromOpaque(ctx).release()
            return nil
        }
    }

    deinit {
        if let handle {
            cs_run_close_input(handle)
            cs_run_free(handle)
        }
    }

    /// One line of standard input; false if the run is over or its input was closed.
    @discardableResult
    public func send(_ line: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let handle else { return false }
        return cs_run_send(handle, line) == 0
    }

    /// The end of standard input: a `jsonRpc` run shuts down, a `link` run is cancelled.
    public func closeInput() {
        lock.lock()
        defer { lock.unlock() }
        if let handle { cs_run_close_input(handle) }
    }
}

extension SignalBackend {
    /// A one-shot command inside the process: the store key first, then the output until the run ends.
    nonisolated static func runEmbedded(args: [String], storeKey: String?, timeout: TimeInterval) -> CliResult {
        final class Collected: @unchecked Sendable {
            let lock = NSLock()
            var out: [String] = [], err: [String] = []
            var code: Int32 = -1
        }
        var r = CliResult()
        r.command = "corvus-signal " + args.joined(separator: " ")
        let start = Date()
        let collected = Collected()
        let exited = DispatchSemaphore(value: 0)
        let run = EmbeddedRun(arguments: args, onLine: { stream, line in
            collected.lock.lock()
            if stream == .output { collected.out.append(line) } else { collected.err.append(line) }
            collected.lock.unlock()
        }, onExit: { code in
            collected.lock.lock()
            collected.code = code
            collected.lock.unlock()
            exited.signal()
        })
        guard let run else {
            r.startError = "The Signal backend could not be started."
            logResult(exe: "corvus-signal", args: args, r)
            return r
        }
        if let storeKey { run.send(storeKey) }
        if exited.wait(timeout: .now() + timeout) == .timedOut {
            run.closeInput()
            r.timedOut = true
        }
        collected.lock.lock()
        r.out = collected.out.joined(separator: "\n")
        r.err = collected.err.joined(separator: "\n")
        if !r.timedOut {
            r.exitCode = collected.code
            r.ok = collected.code == 0
        }
        collected.lock.unlock()
        r.ms = Int64(Date().timeIntervalSince(start) * 1000)
        logResult(exe: "corvus-signal", args: args, r)
        return r
    }
}
