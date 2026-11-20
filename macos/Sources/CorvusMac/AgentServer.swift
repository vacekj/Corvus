import AppKit
import CorvusCore
import Darwin
import Security

// The socket `corvus-agent` (the MCP server / CLI in Contents/MacOS) talks to: one JSON request per line,
// one JSON answer per line. Only processes of this user can connect (socket mode 0600 and a peer uid
// check); who the agent is comes from the code signatures of the connecting process and its parents.

/// The agent behind a connection: the nearest parent process signed by a developer team (Claude Code,
/// Codex, a terminal …), or the nearest non-system executable when nothing up the chain is signed.
struct AgentClient: Sendable {
    var id: String
    var name: String
    var signer: String       // team id; empty when not signed
    var identifier: String
    var path: String         // executable of the agent process
    var appPath: String      // enclosing .app (for the icon); may be empty

    static let knownNames: [String: String] = [
        "com.anthropic.claude-code": "Claude Code",
        "com.anthropic.claudefordesktop": "Claude",
        "com.openai.codex": "Codex",
        "com.openai.chat": "ChatGPT",
        "com.todesktop.230313mzl4w4u92": "Cursor",
    ]
    static let knownTeams: [String: String] = [
        "Q6L2SF6YDW": "Anthropic",
        "2DC432GLL2": "OpenAI",
    ]

    var signerText: String {
        guard !signer.isEmpty else { return "Not signed · " + path }
        return "\(AgentClient.knownTeams[signer] ?? signer) · \(identifier)"
    }

    var icon: NSImage {
        if !appPath.isEmpty { return NSWorkspace.shared.icon(forFile: appPath) }
        return NSWorkspace.shared.icon(forFile: path)
    }
}

enum AgentPeer {
    static func identify(pid peer: pid_t) -> AgentClient {
        let own = signature(getpid())?.team ?? ""
        var pid = peer
        var firstUnsigned: String?
        for _ in 0..<24 {
            guard pid > 1 else { break }
            let path = executablePath(pid)
            if pid != peer, let sig = signature(pid), !sig.team.isEmpty, sig.team != own {
                let app = installedApp(above: pid) ?? enclosingApp(path)
                let name = AgentClient.knownNames[sig.identifier]
                    ?? app.flatMap { Bundle(path: $0)?.object(forInfoDictionaryKey: "CFBundleName") as? String }
                    ?? (path as NSString).lastPathComponent
                return AgentClient(id: "\(sig.team):\(sig.identifier)", name: name, signer: sig.team,
                                   identifier: sig.identifier, path: path, appPath: app ?? "")
            }
            if pid != peer, firstUnsigned == nil, !path.isEmpty, !isSystem(path) { firstUnsigned = path }
            pid = parent(pid)
        }
        let path = firstUnsigned ?? executablePath(peer)
        return AgentClient(id: "path:" + path, name: (path as NSString).lastPathComponent, signer: "", identifier: "",
                           path: path, appPath: enclosingApp(path) ?? "")
    }

    private static func isSystem(_ path: String) -> Bool {
        ["/bin/", "/sbin/", "/usr/bin/", "/usr/sbin/", "/usr/libexec/", "/System/"].contains { path.hasPrefix($0) }
    }

    /// The first app in /Applications up the process chain (Claude, Ghostty …): its icon stands for the agent.
    private static func installedApp(above pid: pid_t) -> String? {
        var p = pid
        for _ in 0..<24 {
            guard p > 1 else { return nil }
            if let app = enclosingApp(executablePath(p)), app.hasPrefix("/Applications/") { return app }
            p = parent(p)
        }
        return nil
    }

    /// The outermost .app bundle the executable is in.
    private static func enclosingApp(_ path: String) -> String? {
        guard let r = path.range(of: ".app/") else { return nil }
        return String(path[..<r.lowerBound]) + ".app"
    }

    static func parent(_ pid: pid_t) -> pid_t {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { return 0 }
        return info.kp_eproc.e_ppid
    }

    static func executablePath(_ pid: pid_t) -> String {
        var buf = [CChar](repeating: 0, count: 4096)
        guard proc_pidpath(pid, &buf, UInt32(buf.count)) > 0 else { return "" }
        return String(cString: buf)
    }

    /// Team and identifier of a running process whose signature is valid.
    static func signature(_ pid: pid_t) -> (team: String, identifier: String)? {
        var code: SecCode?
        let attrs = [kSecGuestAttributePid: NSNumber(value: pid)] as CFDictionary
        guard SecCodeCopyGuestWithAttributes(nil, attrs, [], &code) == errSecSuccess, let code,
              SecCodeCheckValidity(code, [], nil) == errSecSuccess else { return nil }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else { return nil }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let dict = info as? [String: Any] else { return nil }
        return (dict[kSecCodeInfoTeamIdentifier as String] as? String ?? "", dict[kSecCodeInfoIdentifier as String] as? String ?? "")
    }
}

/// One connection's memory: what the user refused during it, so an agent cannot repeat a question.
final class AgentSession: @unchecked Sendable {
    let client: AgentClient
    var deniedAgent = false
    var deniedChats: Set<String> = []
    init(client: AgentClient) { self.client = client }
}

final class AgentServer: @unchecked Sendable {
    let path: String
    private var fd: Int32 = -1
    private let handle: @Sendable (AgentSession, JSON) async -> JSON

    init(path: String, handle: @escaping @Sendable (AgentSession, JSON) async -> JSON) {
        self.path = path
        self.handle = handle
    }

    var isRunning: Bool { fd >= 0 }

    func start() -> Bool {
        guard fd < 0 else { return true }
        unlink(path)
        let s = socket(AF_UNIX, SOCK_STREAM, 0)
        guard s >= 0 else { return false }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: addr.sun_path) else { close(s); return false }
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            for (i, b) in bytes.enumerated() { raw[i] = b }
        }
        let old = umask(0o077)
        let ok = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(s, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        } == 0
        umask(old)
        guard ok, chmod(path, 0o600) == 0, listen(s, 8) == 0 else { close(s); unlink(path); return false }
        fd = s
        let t = Thread { [weak self] in self?.acceptLoop(s) }
        t.name = "corvus.agent.accept"
        t.start()
        return true
    }

    func stop() {
        guard fd >= 0 else { return }
        let s = fd
        fd = -1
        shutdown(s, SHUT_RDWR)
        close(s)
        unlink(path)
    }

    private func acceptLoop(_ s: Int32) {
        while true {
            let c = accept(s, nil, nil)
            if c < 0 {
                if errno == EINTR { continue }
                return
            }
            let t = Thread { [weak self] in self?.serve(c) }
            t.name = "corvus.agent.client"
            t.start()
        }
    }

    private func serve(_ c: Int32) {
        defer { close(c) }
        var uid: uid_t = 0, gid: gid_t = 0
        guard getpeereid(c, &uid, &gid) == 0, uid == getuid() else { return }
        var pid: pid_t = 0
        var len = socklen_t(MemoryLayout<pid_t>.size)
        guard getsockopt(c, SOL_LOCAL, LOCAL_PEERPID, &pid, &len) == 0, pid > 0 else { return }
        let session = AgentSession(client: AgentPeer.identify(pid: pid))
        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 65536)
        while true {
            let n = read(c, &chunk, chunk.count)
            if n <= 0 { return }
            buffer.append(contentsOf: chunk[0..<n])
            if buffer.count > 1 << 20 { return }
            while let nl = buffer.firstIndex(of: 0x0A) {
                let line = buffer[buffer.startIndex..<nl]
                buffer = Data(buffer[buffer.index(after: nl)...])
                guard !line.isEmpty else { continue }
                let request = (try? JSONSerialization.jsonObject(with: line)) as? JSON ?? [:]
                let answer = wait { await self.handle(session, request) }
                guard var out = try? JSONSerialization.data(withJSONObject: answer) else { return }
                out.append(0x0A)
                let sent = out.withUnsafeBytes { write(c, $0.baseAddress, $0.count) }
                if sent != out.count { return }
            }
        }
    }

    /// Runs an async handler from this connection's own thread.
    private func wait(_ body: @escaping @Sendable () async -> JSON) -> JSON {
        final class Box: @unchecked Sendable { var value: JSON = [:] }
        let box = Box(), done = DispatchSemaphore(value: 0)
        Task {
            box.value = await body()
            done.signal()
        }
        done.wait()
        return box.value
    }
}
