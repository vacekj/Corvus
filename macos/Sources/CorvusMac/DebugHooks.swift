#if DEBUG
import AppKit
import CorvusCore
import SwiftUI

/// Debug builds only: a tiny command channel for unattended UI checks against tests/mock-signal-cli.py.
/// Set SIGNAL_CLI_MAC_DEBUG_COMMANDS=<file>; every line appended to it is executed:
///   open <conversation key> | type <text> | send | reply-last | react-last <emoji> | edit-last <text>
///   search <text> | archived on|off | view-image | copy-image | clipboard <file> | snapshot <png path> | quit
@MainActor
enum DebugHooks {
    private static var offset: UInt64 = 0
    /// Messages that got past the catch-up silence in alertIncoming (sound / notification attempts).
    static var alertCount = 0
    private static var timer: Timer?

    static func start(_ model: AppModel) {
        guard let path = ProcessInfo.processInfo.environment["SIGNAL_CLI_MAC_DEBUG_COMMANDS"] else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { _ in
            MainActor.assumeIsolated { poll(path, model) }
        }
    }

    private static func poll(_ path: String, _ model: AppModel) {
        guard let h = FileHandle(forReadingAtPath: path) else { return }
        defer { try? h.close() }
        try? h.seek(toOffset: offset)
        let data = h.readDataToEndOfFile()
        guard let nl = data.lastIndex(of: 0x0A) else { return }
        let chunk = data[data.startIndex...nl]
        offset += UInt64(chunk.count)
        for line in String(decoding: chunk, as: UTF8.self).split(separator: "\n") {
            run(String(line), model)
        }
    }

    private static func run(_ line: String, _ model: AppModel) {
        let parts = line.split(separator: " ", maxSplits: 1).map(String.init)
        let arg = parts.count > 1 ? parts[1] : ""
        let last = model.currentConversation?.msgs.last
        FileHandle.standardError.write(Data("debug: \(line)\n".utf8))
        switch parts.first ?? "" {
        case "open": model.openConversation(arg)
        case "type": model.composerText = arg
        case "send": model.sendMessage()
        case "reply-last": if let last { model.startReply(last.id) }
        case "react-last": if let last { model.sendReaction(last.id, arg) }
        case "edit-last":
            if model.editLastMessage() {
                model.composerText = arg
                model.sendMessage()
            }
        case "search":
            model.openSearch()
            model.searchText = arg
        case "archived": model.showArchived = arg == "on"
        case "sticker":
            let k = arg.split(separator: ":").map(String.init)
            if k.count == 2, let id = Int(k[1]) { model.sendSticker(packId: k[0], stickerId: id) }
        case "poll":
            // poll <question>|<option>|<option>…
            let f = arg.split(separator: "|").map(String.init)
            if f.count >= 3 { model.createPoll(question: f[0], options: Array(f.dropFirst()), allowMultiple: true) }
        case "vote-last": if let last { model.votePoll(last.id, options: arg.split(separator: ",").compactMap { Int($0) }) }
        case "gallery": model.galleryShown = arg != "off"
        case "stories": model.storiesShown = arg != "off"
        case "safety": model.safetyNumberKey = arg.isEmpty ? nil : arg
        case "forward-last": if let last { model.forward(messageId: last.id, to: [arg]) }
        case "forward-sheet": model.forwardMessageId = arg == "off" ? nil : last?.id
        case "viewonce":
            if let m = model.currentConversation?.msgs.first(where: { $0.viewOnce && !$0.viewOnceConsumed }) { model.openViewOnce(m.id) }
        case "poll-sheet": model.pollComposerShown = arg != "off"
        case "callevent":
            if let d = arg.data(using: .utf8), let o = (try? JSONSerialization.jsonObject(with: d)) as? JSON { model.onCallEvent(o) }
        case "accept": if let k = model.current { model.acceptRequest(k) }
        case "block": if let k = model.current { Task { await model.setBlocked(k, arg != "off") } }
        case "group-info", "info": model.infoPanelShown = arg != "off"
        case "new-group": model.newGroupShown = arg != "off"
        case "view-image":
            if let m = model.currentConversation?.msgs.last(where: { $0.attachments.contains(where: \.isImage) }),
               let i = m.attachments.firstIndex(where: \.isImage) { model.openMediaViewer(m, i) }
        case "copy-image": ImageViewerWindow.shared.copyCurrent()
        case "clipboard":
            // One line per pasteboard type: "<type> <byte count>".
            let item = ImageClipboard.pasteboard.pasteboardItems?.first
            let lines = (item?.types ?? []).map { "\($0.rawValue) \(item?.data(forType: $0)?.count ?? 0)" }
            try? (lines.joined(separator: "\n") + "\n").write(toFile: arg, atomically: true, encoding: .utf8)
        case "snapshot": snapshot(to: arg)
        case "agents": model.agentAccess.enabled = arg != "off"
        case "counts":
            // counts <file>: messages and unread per chat, alerts so far, catch-up state
            var lines = model.chats.convs.values.sorted { $0.key < $1.key }.map { "\($0.key) msgs=\($0.msgs.count) unread=\($0.unread)" }
            lines.append("alerts=\(alertCount) catchingUp=\(model.catchingUp) buffered=\(model.earlyEnvelopes.count)")
            try? (lines.joined(separator: "\n") + "\n").write(toFile: arg, atomically: true, encoding: .utf8)
        case "agent-panel":
            // agent-panel allow | deny | all | select <key> | snapshot <png>
            guard let p = AgentPanel.current else { break }
            let a = arg.split(separator: " ", maxSplits: 1).map(String.init)
            switch a.first ?? "" {
            case "allow": p.state.decide(true)
            case "deny": p.state.decide(false)
            case "all": p.state.allChats = true
            case "select": if a.count > 1 { p.state.selected.insert(a[1]) }
            case "snapshot": if a.count > 1 { write(p.panel, a[1]) }
            default: break
            }
        case "agent-settings":
            // Renders Settings → Agents into a PNG.
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 540, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
            w.alphaValue = 0
            w.contentView = NSHostingView(rootView: AgentSettings().environment(model).font(TypeScale.body))
            w.orderFrontRegardless()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                write(w, arg)
                w.orderOut(nil)
            }
        case "quit": NSApp.terminate(nil)
        default: break
        }
    }

    private static func snapshot(to path: String) {
        guard let window = MainWindowTracker.shared.window else { return }
        write(window, path)
        // Sheets and the call window are windows of their own.
        if let sheet = window.attachedSheet { write(sheet, path.replacingOccurrences(of: ".png", with: "-sheet.png")) }
        if let call = NSApp.windows.first(where: { $0.title == "Voice call" && $0.isVisible }) {
            write(call, path.replacingOccurrences(of: ".png", with: "-call.png"))
        }
    }

    private static func write(_ window: NSWindow, _ path: String) {
        guard let view = window.contentView?.superview ?? window.contentView,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    }
}
#endif
