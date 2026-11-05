import Foundation
import os

/// Startup timing marks ("log stream --predicate 'subsystem == "io.github.corvus.mac"'" shows them).
enum Perf {
    static let t0 = Date()
    private static let log = Logger(subsystem: "io.github.corvus.mac", category: "perf")
    static func mark(_ what: String) {
        let ms = Int(Date().timeIntervalSince(t0) * 1000)
        log.info("\(ms, privacy: .public) ms: \(what, privacy: .public)")
    }
}
