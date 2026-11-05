import AppKit
import CorvusCore
import Foundation

/// "Import from Signal Desktop": runs the bundled `corvus-signal-import` helper, which reads the local
/// Signal Desktop database (key from the "Signal Safe Storage" keychain item) and prints Corvus history
/// records. They are merged into the current history; known messages are skipped, so the import can be
/// repeated safely. Attachments stay encrypted with their Signal Desktop keys in
/// "<data folder>/imported-attachments" and are decrypted only when shown.
enum DesktopImport {
    static var attachmentsDir: URL { AppPaths.dataDir.appendingPathComponent("imported-attachments", isDirectory: true) }

    static var signalDir: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Signal", isDirectory: true)
    }

    static var helperPath: String? {
        #if DEBUG
        if let p = ProcessInfo.processInfo.environment["CORVUS_IMPORT_TOOL"] { return p }
        #endif
        let p = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/corvus-signal-import").path
        return FileManager.default.isExecutableFile(atPath: p) ? p : nil
    }

    /// Runs the helper; returns the parsed records.
    static func run(account: String) async throws -> (records: [JSON], log: String) {
        guard let helper = helperPath else { throw ImportError("The Signal Desktop import helper is missing from this build.") }
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("corvus-import-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: tmp) }
        let outURL = tmp.appendingPathComponent("records.jsonl")
        FileManager.default.createFile(atPath: outURL.path, contents: nil, attributes: [.posixPermissions: 0o600])
        let out = try FileHandle(forWritingTo: outURL)
        let errPipe = Pipe()
        let p = Process()
        p.executableURL = URL(fileURLWithPath: helper)
        p.arguments = ["--account", account, "--attachments-dir", attachmentsDir.path, "--signal-dir", signalDir.path]
        p.standardOutput = out
        p.standardError = errPipe
        let status: Int32 = try await withCheckedThrowingContinuation { cont in
            p.terminationHandler = { cont.resume(returning: $0.terminationStatus) }
            do { try p.run() } catch { cont.resume(throwing: error) }
        }
        try? out.close()
        let log = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        guard status == 0 else {
            let msg = log.split(separator: "\n").last(where: { $0.hasPrefix("error:") }).map { String($0.dropFirst(7)) } ?? log
            throw ImportError(msg.isEmpty ? "The import helper failed (\(status))." : msg)
        }
        return (try parse(outURL), log)
    }

    private static func parse(_ url: URL) throws -> [JSON] {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        var records: [JSON] = []
        records.reserveCapacity(80_000)
        for line in data.split(separator: UInt8(ascii: "\n")) where !line.isEmpty {
            guard var o = (try? JSONSerialization.jsonObject(with: Data(line))) as? JSON else { continue }
            if jsonString(o["t"]) == "m", var d = o["d"] as? JSON, let atts = d["at"] as? [JSON] {
                d["at"] = atts.map { a -> JSON in
                    var a = a
                    // Only stickers keep inline data (it is the sticker); pictures are shown from the file.
                    if !(jsonString(a["fn"]).hasPrefix(Attachment.stickerPrefix)) { a["th"] = nil }
                    if let ep = a["ep"] as? String, !DesktopAttachment.isSafeName(ep) { a["ep"] = nil; a["lk"] = nil }
                    return a
                }
                o["d"] = d
            }
            records.append(o)
        }
        return records
    }

    /// Counts only (no message content): per chat the number of messages and the time range, for
    /// checking an import against Signal Desktop. Written to "<data folder>/import-report.json".
    static func writeReport(_ chats: ChatState) {
        var rows: [JSON] = []
        for (k, c) in chats.convs where !c.msgs.isEmpty {
            rows.append(["c": k, "n": c.msgs.count, "o": c.msgs.filter(\.outgoing).count,
                         "mn": c.msgs.map(\.ts).min() ?? 0, "mx": c.msgs.map(\.ts).max() ?? 0,
                         "at": c.msgs.reduce(0) { $0 + $1.attachments.count }])
        }
        let url = AppPaths.dataDir.appendingPathComponent("import-report.json")
        if let d = try? JSONSerialization.data(withJSONObject: rows, options: [.sortedKeys]) {
            FileManager.default.createFile(atPath: url.path, contents: d, attributes: [.posixPermissions: 0o600])
        }
    }

    /// Decrypted content of an imported attachment.
    static func data(_ att: Attachment) throws -> Data {
        guard DesktopAttachment.isSafeName(att.encPath) else { throw ImportError("The attachment is no longer available.") }
        let url = attachmentsDir.appendingPathComponent(att.encPath)
        guard let raw = FileManager.default.contents(atPath: url.path) else { throw ImportError("The imported attachment file is missing.") }
        return try DesktopAttachment.decrypt(raw, localKey: att.localKey, size: att.size)
    }
}

extension AppModel {
    func importFromSignalDesktop() async {
        guard !chats.account.isEmpty else {
            await Dialogs.error("Import from Signal Desktop", "Link Corvus to your Signal account first.")
            return
        }
        guard FileManager.default.fileExists(atPath: DesktopImport.signalDir.appendingPathComponent("sql/db.sqlite").path) else {
            await Dialogs.error("Import from Signal Desktop", "No Signal Desktop data was found on this Mac.")
            return
        }
        guard await Dialogs.confirm("Import from Signal Desktop",
                                    "Corvus reads the message history of Signal Desktop on this Mac and adds the messages it does not have yet. "
                                    + "Signal Desktop's data is not changed. macOS may ask you to allow access to the \u{201C}Signal Safe Storage\u{201D} keychain item.\n\n"
                                    + "Imported attachments stay encrypted in the Corvus data folder.",
                                    ok: "Import") else { return }
        showFlash("Importing the Signal Desktop history …", seconds: 600)
        do {
            let account = chats.account
            let (records, _) = try await Task.detached(priority: .userInitiated) { try await DesktopImport.run(account: account) }.value
            let sum = chats.mergeImported(records)
            listChanged()
            guard rewriteHistory("save the imported history") else { return }
            DesktopImport.writeReport(chats)
            showFlash("Imported \(sum.messagesAdded) messages", seconds: 4)
            await Dialogs.info("Import finished",
                               "\(sum.messagesAdded) messages and \(sum.reactionsAdded) reactions were added "
                               + "(\(sum.messagesKnown) messages were already in Corvus); \(sum.conversationsAdded) new chats.")
        } catch {
            showFlash("Import failed", seconds: 3)
            await Dialogs.error("Import from Signal Desktop", error.localizedDescription)
        }
    }
}
