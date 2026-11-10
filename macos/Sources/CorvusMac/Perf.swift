import Foundation
import os

/// Startup timing marks ("log stream --predicate 'subsystem == "io.github.corvus.mac"'" shows them).
enum Perf {
    /// Process start (not the first mark): launch time before Swift code runs counts too.
    static let t0: Date = {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0 else { return Date() }
        let tv = info.kp_proc.p_starttime
        return Date(timeIntervalSince1970: Double(tv.tv_sec) + Double(tv.tv_usec) / 1e6)
    }()
    private static let log = Logger(subsystem: "io.github.corvus.mac", category: "perf")
    /// Something that must not go unnoticed (kept in the system log, unlike the marks).
    static func failure(_ what: String) { log.error("\(what, privacy: .public)") }

    static func mark(_ what: String) {
        let ms = Int(Date().timeIntervalSince(t0) * 1000)
        log.info("\(ms, privacy: .public) ms: \(what, privacy: .public)")
    }
}
