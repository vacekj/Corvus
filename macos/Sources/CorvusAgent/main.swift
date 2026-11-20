import Darwin
import Foundation

// corvus-agent: read access to Corvus chats for AI agents, as an MCP server (`corvus-agent mcp`) or a CLI.
// It only relays requests to the running Corvus app over its socket; Corvus asks the user which agent
// may read which chats and enforces that. Nothing here can send messages or mark chats as read.

typealias JSON = [String: Any]

let usage = """
usage: corvus-agent <command> [arguments]
  mcp                                   run as an MCP server on stdin/stdout
  chats [query] [--limit N]             chats this agent may read
  read <chat> [--limit N] [--before T] [--after T]
                                        messages of a chat (T: ISO date/time or ms)
  search <text> [--chat C] [--limit N]  messages containing text
  contacts [query] [--limit N]          look up contacts
  whoami                                which agent Corvus sees and its access
"""

// MARK: - Socket client

struct AgentFailure: Error { let code: String; let message: String }

final class CorvusConnection {
    private var fd: Int32 = -1
    private var buffer = Data()
    private var nextId = 1

    static var socketPath: String {
        if let p = ProcessInfo.processInfo.environment["CORVUS_AGENT_SOCKET"], !p.isEmpty { return p }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("corvus/corvus/agent.sock").path
    }

    private func connectSocket() throws {
        let path = Self.socketPath
        let s = socket(AF_UNIX, SOCK_STREAM, 0)
        guard s >= 0 else { throw AgentFailure(code: "unavailable", message: "Cannot create a socket.") }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in for (i, b) in bytes.prefix(raw.count - 1).enumerated() { raw[i] = b } }
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(s, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard rc == 0 else {
            close(s)
            throw AgentFailure(code: "unavailable",
                               message: "Corvus is not running, or agent access is off (Corvus Settings → Agents).")
        }
        fd = s
        buffer = Data()
    }

    func call(_ method: String, _ params: JSON) throws -> Any {
        for attempt in 0..<2 {
            if fd < 0 { try connectSocket() }
            let id = nextId
            nextId += 1
            var out = try JSONSerialization.data(withJSONObject: ["id": id, "method": method, "params": params] as JSON)
            out.append(0x0A)
            let sent = out.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
            guard sent == out.count, let line = readLine() else {
                close(fd)
                fd = -1
                if attempt == 0 { continue }
                throw AgentFailure(code: "unavailable", message: "Corvus closed the connection.")
            }
            let answer = (try? JSONSerialization.jsonObject(with: line)) as? JSON ?? [:]
            if let e = answer["error"] as? JSON {
                throw AgentFailure(code: e["code"] as? String ?? "failed", message: e["message"] as? String ?? "Request failed.")
            }
            return answer["result"] ?? NSNull()
        }
        throw AgentFailure(code: "unavailable", message: "Corvus closed the connection.")
    }

    private func readLine() -> Data? {
        var chunk = [UInt8](repeating: 0, count: 65536)
        while true {
            if let nl = buffer.firstIndex(of: 0x0A) {
                let line = Data(buffer[buffer.startIndex..<nl])
                buffer = Data(buffer[buffer.index(after: nl)...])
                return line
            }
            let n = read(fd, &chunk, chunk.count)
            if n <= 0 { return nil }
            buffer.append(contentsOf: chunk[0..<n])
        }
    }
}

func pretty(_ v: Any) -> String {
    guard JSONSerialization.isValidJSONObject(v) || v is NSNull == false,
          let d = try? JSONSerialization.data(withJSONObject: v, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes, .fragmentsAllowed])
    else { return "\(v)" }
    return String(decoding: d, as: UTF8.self)
}

// MARK: - MCP

let tools: [JSON] = [
    [
        "name": "list_chats",
        "description": "List the Signal chats (direct and group) in Corvus that you are allowed to read, newest activity first. Each has an id usable as `chat` in the other tools.",
        "inputSchema": ["type": "object", "properties": [
            "query": ["type": "string", "description": "Filter by chat name (fuzzy, ignores case and diacritics)."],
            "limit": ["type": "integer", "description": "Maximum chats to return (default 50)."],
        ] as JSON] as JSON,
        "annotations": ["readOnlyHint": true] as JSON,
    ],
    [
        "name": "read_chat",
        "description": "Read messages of one chat, oldest first. Returns the newest `limit` messages, or those before/after a time for paging. If the chat is not shared with you yet, Corvus asks the user, so naming a chat the user mentioned is fine.",
        "inputSchema": ["type": "object", "properties": [
            "chat": ["type": "string", "description": "Chat id from list_chats, or the chat's name."],
            "limit": ["type": "integer", "description": "Number of messages (default 50, at most 500)."],
            "before": ["type": "string", "description": "Only messages before this time (ISO 8601 date/time, or ms since 1970). Use the oldest returned `ts` to page back."],
            "after": ["type": "string", "description": "Only messages after this time (ISO 8601, or ms); returns the oldest `limit` after it."],
        ] as JSON, "required": ["chat"]] as JSON,
        "annotations": ["readOnlyHint": true] as JSON,
    ],
    [
        "name": "search_messages",
        "description": "Find messages containing a text (ignores case and diacritics), newest first, across your allowed chats or in one chat.",
        "inputSchema": ["type": "object", "properties": [
            "query": ["type": "string", "description": "Text to find (at least 2 characters)."],
            "chat": ["type": "string", "description": "Optional chat id or name to search in."],
            "limit": ["type": "integer", "description": "Maximum results (default 30)."],
        ] as JSON, "required": ["query"]] as JSON,
        "annotations": ["readOnlyHint": true] as JSON,
    ],
    [
        "name": "search_contacts",
        "description": "Look up Signal contacts by name or phone number. Returns names, numbers and, when you may read it, the chat id.",
        "inputSchema": ["type": "object", "properties": [
            "query": ["type": "string", "description": "Name or number (fuzzy). Empty lists all contacts."],
            "limit": ["type": "integer", "description": "Maximum results (default 20)."],
        ] as JSON] as JSON,
        "annotations": ["readOnlyHint": true] as JSON,
    ],
]

let toolMethods = ["list_chats": "listChats", "read_chat": "readChat", "search_messages": "searchMessages",
                   "search_contacts": "searchContacts"]

func runMCP() {
    let conn = CorvusConnection()
    setvbuf(stdout, nil, _IOLBF, 0)
    func send(_ o: JSON) {
        guard let d = try? JSONSerialization.data(withJSONObject: o, options: [.withoutEscapingSlashes]) else { return }
        FileHandle.standardOutput.write(d + Data([0x0A]))
    }
    while let line = Swift.readLine(strippingNewline: true) {
        guard let d = line.data(using: .utf8), let msg = (try? JSONSerialization.jsonObject(with: d)) as? JSON else { continue }
        let method = msg["method"] as? String ?? ""
        guard let id = msg["id"] else { continue } // notifications
        let p = msg["params"] as? JSON ?? [:]
        switch method {
        case "initialize":
            send(["jsonrpc": "2.0", "id": id, "result": [
                "protocolVersion": p["protocolVersion"] as? String ?? "2025-06-18",
                "capabilities": ["tools": [:] as JSON] as JSON,
                "serverInfo": ["name": "corvus", "version": "1.0"] as JSON,
                "instructions": "Read-only access to the user's Signal chats in the Corvus app. The user decides in Corvus which chats you may read; asking for another chat shows them a prompt. Do not quote more of private messages than the task needs.",
            ] as JSON])
        case "ping":
            send(["jsonrpc": "2.0", "id": id, "result": [:] as JSON])
        case "tools/list":
            send(["jsonrpc": "2.0", "id": id, "result": ["tools": tools] as JSON])
        case "tools/call":
            let name = p["name"] as? String ?? ""
            let args = p["arguments"] as? JSON ?? [:]
            var result: JSON
            if let m = toolMethods[name] {
                do {
                    let r = try conn.call(m, args)
                    result = ["content": [["type": "text", "text": pretty(r)] as JSON]]
                } catch let e as AgentFailure {
                    result = ["content": [["type": "text", "text": e.message] as JSON], "isError": true]
                } catch {
                    result = ["content": [["type": "text", "text": "\(error)"] as JSON], "isError": true]
                }
            } else {
                result = ["content": [["type": "text", "text": "Unknown tool \(name)."] as JSON], "isError": true]
            }
            send(["jsonrpc": "2.0", "id": id, "result": result])
        default:
            send(["jsonrpc": "2.0", "id": id, "error": ["code": -32601, "message": "Method not found: \(method)"] as JSON])
        }
    }
}

// MARK: - CLI

func runCLI(_ args: [String]) -> Int32 {
    var positional: [String] = []
    var opts: [String: String] = [:]
    var i = 1
    while i < args.count {
        let a = args[i]
        if a.hasPrefix("--"), i + 1 < args.count {
            opts[String(a.dropFirst(2))] = args[i + 1]
            i += 2
        } else {
            positional.append(a)
            i += 1
        }
    }
    let command = positional.first ?? ""
    let rest = positional.dropFirst().joined(separator: " ")
    var params: JSON = [:]
    if let l = opts["limit"], let n = Int(l) { params["limit"] = n }
    let method: String
    switch command {
    case "chats": method = "listChats"; params["query"] = rest
    case "read":
        guard !rest.isEmpty else { FileHandle.standardError.write(Data((usage + "\n").utf8)); return 2 }
        method = "readChat"; params["chat"] = rest
        if let b = opts["before"] { params["before"] = b }
        if let a = opts["after"] { params["after"] = a }
    case "search":
        guard !rest.isEmpty else { FileHandle.standardError.write(Data((usage + "\n").utf8)); return 2 }
        method = "searchMessages"; params["query"] = rest
        if let c = opts["chat"] { params["chat"] = c }
    case "contacts": method = "searchContacts"; params["query"] = rest
    case "whoami": method = "hello"
    default:
        FileHandle.standardError.write(Data((usage + "\n").utf8))
        return command.isEmpty || command == "help" || command == "--help" ? 0 : 2
    }
    do {
        print(pretty(try CorvusConnection().call(method, params)))
        return 0
    } catch let e as AgentFailure {
        FileHandle.standardError.write(Data("corvus-agent: \(e.message)\n".utf8))
        return e.code == "denied" ? 3 : 1
    } catch {
        FileHandle.standardError.write(Data("corvus-agent: \(error)\n".utf8))
        return 1
    }
}

signal(SIGPIPE, SIG_IGN)
let argv = CommandLine.arguments
if argv.count > 1 && argv[1] == "mcp" {
    runMCP()
} else {
    exit(runCLI(argv))
}
