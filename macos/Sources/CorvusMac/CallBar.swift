import AppKit
import CorvusCore
import SwiftUI

/// The call layer of the main window: a banner for an incoming call and a bar for the running call,
/// both above the chat. Return accepts, Esc declines, ⌘⇧M mutes (while a call is up).
struct CallLayer: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let model = model // the key handler runs outside of body
        VStack(spacing: 0) {
            if let s = model.call {
                if s.state == .ringingIncoming {
                    IncomingCallBanner(session: s)
                } else {
                    CallBar(session: s)
                }
            }
        }
        .animation(.easeOut(duration: 0.15), value: model.call?.state)
        .onLocalKeyDown(enabled: model.call != nil) { e in CallLayer.handleKey(e, model) }
    }

    private static func handleKey(_ e: NSEvent, _ model: AppModel) -> Bool {
        guard let s = model.call else { return false }
        let mods = e.modifierFlags.intersection([.command, .shift, .control, .option])
        if s.state == .ringingIncoming && mods.isEmpty {
            switch e.keyCode {
            case KeyCode.returnKey, KeyCode.enter:
                Task { await model.acceptCall() }
                return true
            case KeyCode.escape:
                model.declineCall()
                return true
            default:
                return false
            }
        }
        if s.isActive && s.state != .ringingIncoming && mods == [.command, .shift] && e.keyCode == KeyCode.m {
            model.toggleCallMute()
            return true
        }
        return false
    }
}

private struct IncomingCallBanner: View {
    @Environment(AppModel.self) private var model
    let session: CallSession

    var body: some View {
        HStack(spacing: 12) {
            if let c = model.chats.convs[session.peerKey] {
                AvatarView(image: model.avatarImage(c), size: 36)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(model.chats.convs[session.peerKey].map { model.title($0) } ?? session.peerKey)
                    .font(.headline).lineLimit(1)
                Text("Incoming voice call").font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Button(role: .destructive) { model.declineCall() } label: {
                Label("Decline", systemImage: "phone.down.fill")
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)
            .help("Decline (Esc)")
            Button { Task { await model.acceptCall() } } label: {
                Label("Accept", systemImage: "phone.fill")
            }
            .buttonStyle(.borderedProminent)
            .tint(.green)
            .help("Accept (Return)")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.regularMaterial)
        .overlay(alignment: .bottom) { Divider() }
        .transition(.move(edge: .top).combined(with: .opacity))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Incoming voice call")
    }
}

private struct CallBar: View {
    @Environment(AppModel.self) private var model
    let session: CallSession

    var body: some View {
        let s = session
        HStack(spacing: 10) {
            Image(systemName: "phone.fill").foregroundStyle(s.state == .ended ? Color.secondary : Color.green)
            Button {
                if model.chats.convs[s.peerKey] != nil { model.activateConversation(s.peerKey) }
            } label: {
                Text(model.chats.convs[s.peerKey].map { model.title($0) } ?? s.peerKey).fontWeight(.semibold).lineLimit(1)
            }
            .buttonStyle(.plain)
            .help("Open the chat")
            TimelineView(.periodic(from: .now, by: 1)) { ctx in
                Text(CallBar.statusText(s, now: ctx.date)).foregroundStyle(.secondary).monospacedDigit()
            }
            Spacer(minLength: 8)
            if s.isActive {
                Button { model.toggleCallMute() } label: {
                    Label(s.muted ? "Unmute" : "Mute", systemImage: s.muted ? "mic.slash.fill" : "mic.fill")
                }
                .tint(s.muted ? .orange : nil)
                .help(s.muted ? "Unmute (⌘⇧M)" : "Mute (⌘⇧M)")
                Button(role: .destructive) { model.hangUp() } label: { Label("End", systemImage: "phone.down.fill") }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                    .help("End the call")
            }
        }
        .controlSize(.small)
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .background(s.state == .connected ? Color.green.opacity(0.12) : Color.secondary.opacity(0.1))
        .overlay(alignment: .bottom) { Divider() }
        .transition(.move(edge: .top).combined(with: .opacity))
    }

    static func statusText(_ s: CallSession, now: Date) -> String {
        switch s.state {
        case .ringingIncoming: return "Incoming voice call …"
        case .ringingOutgoing: return "Ringing …"
        case .connecting, .idle: return "Connecting …"
        case .reconnecting: return "Reconnecting …"
        case .connected:
            let t = Int(now.timeIntervalSince(s.connectedAt ?? now))
            return String(format: "%d:%02d", t / 60, t % 60)
        case .ended:
            switch s.endReason {
            case "", "hangup", "remote_hangup": return "Call ended"
            case "declined": return "Call declined"
            case "tunnel_spawn_error", "tunnel_exit", "tunnel_error": return "Call failed (signal-call-tunnel)"
            default: return "Call ended (\(s.endReason.replacingOccurrences(of: "_", with: " ")))"
            }
        }
    }
}
