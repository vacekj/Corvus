import AppKit
import CorvusCore
import CryptoKit
import SwiftUI

/// The call list (Signal Desktop's Calls tab). signal-cli's `listCalls` only reports calls in progress, so
/// Corvus records the calls it sees (Calls.swift) and keeps them in `call-history.bin`, encrypted with a key
/// derived from the history secret like the roster cache.
@MainActor @Observable
final class CallHistoryStore {
    static let shared = CallHistoryStore()

    private(set) var log = CallLog()
    /// Missed calls since the call list was last opened (the badge on the Calls button).
    private(set) var unseenMissed = 0

    @ObservationIgnored private var loaded = false
    @ObservationIgnored private var installed = false
    private static let seenKey = "callHistorySeenMs"
    private static var url: URL { AppPaths.dataDir.appendingPathComponent("call-history.bin") }
    private static let keyInfo = "corvus call history v1"

    /// Loads the list once the history is unlocked, and re-encrypts it when the history secret changes.
    func install() {
        guard !installed else { return }
        installed = true
        RosterCache.keyChanged.append { [weak self] in
            guard let self else { return }
            if self.loaded { self.save() } else { self.load() }
        }
    }

    private func load() {
        guard let key = RosterCache.subkey(Self.keyInfo) else { return }
        loaded = true
        if let sealed = try? Data(contentsOf: Self.url), let box = try? AES.GCM.SealedBox(combined: sealed),
           let plain = try? AES.GCM.open(box, using: key), let decoded = try? JSONDecoder().decode(CallLog.self, from: plain) {
            var l = decoded
            l.closeDangling(at: nowMs())
            log = l
        }
        updateUnseen()
    }

    private func save() {
        guard loaded, let key = RosterCache.subkey(Self.keyInfo), let plain = try? JSONEncoder().encode(log),
              let sealed = try? AES.GCM.seal(plain, using: key).combined else { return }
        let tmp = Self.url.appendingPathExtension("tmp")
        FileManager.default.createFile(atPath: tmp.path, contents: sealed, attributes: [.posixPermissions: 0o600])
        if FileManager.default.fileExists(atPath: Self.url.path) {
            _ = try? FileManager.default.replaceItemAt(Self.url, withItemAt: tmp)
        } else {
            try? FileManager.default.moveItem(at: tmp, to: Self.url)
        }
    }

    private func updateUnseen() {
        let seen = Int64(UserDefaults.standard.double(forKey: Self.seenKey))
        let n = log.records.lazy.filter { $0.isMissed && $0.startedMs > seen }.count
        if n != unseenMissed { unseenMissed = n }
    }

    func markSeen() {
        UserDefaults.standard.set(Double(nowMs()), forKey: Self.seenKey)
        updateUnseen()
    }

    // MARK: Recording (Calls.swift)

    func begin(callId: Int64, peerKey: String, outgoing: Bool) {
        if log.begin(callId: callId, peerKey: peerKey, outgoing: outgoing, at: nowMs()) { save() }
    }

    func connected(callId: Int64) {
        if log.connected(callId: callId, at: nowMs()) { save() }
    }

    @discardableResult
    func ended(callId: Int64, reason: String) -> CallRecord? {
        guard let r = log.ended(callId: callId, reason: reason, at: nowMs()) else { return nil }
        save()
        updateUnseen()
        return r
    }

    func remove(_ id: String) {
        log.remove(id: id)
        save()
        updateUnseen()
    }

    func removeAll() {
        log.removeAll()
        save()
        updateUnseen()
    }
}

extension AppModel {
    /// Replaces the "Incoming voice call" notification of a call nobody answered.
    func notifyMissedCall(_ record: CallRecord) {
        guard record.isMissed, notify.notifications, let c = chats.convs[record.peerKey], !c.muted,
              !AppChrome.shared.notificationsMuted else { return }
        let hidden = notify.content == .hidden
        notifier.notify(key: c.key, title: hidden ? "Corvus" : title(c), body: "Missed voice call",
                        icon: hidden ? nil : avatarImage(c))
    }
}

// MARK: - Views

/// The Calls button next to Stories above the chat list, with the number of missed calls not yet seen.
struct CallsButton: View {
    @Environment(AppModel.self) private var model
    private let store = CallHistoryStore.shared

    var body: some View {
        Button { AppChrome.shared.callsShown = true } label: {
            Image(systemName: "phone").font(.system(size: 15))
                .overlay(alignment: .topTrailing) {
                    if store.unseenMissed > 0 { Circle().fill(Color.red).frame(width: 7, height: 7).offset(x: 3, y: -2) }
                }
        }
        .buttonStyle(.borderless)
        .iconHelp(store.unseenMissed > 0 ? "Calls, \(store.unseenMissed) missed" : "Calls")
        .disabled(!model.historyReady)
    }
}

struct CallHistorySheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    private let store = CallHistoryStore.shared
    @State private var missedOnly = false

    var body: some View {
        let records = store.log.filtered(missedOnly: missedOnly)
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Text("Calls").font(.title3.weight(.semibold))
                Spacer()
                Picker("Show", selection: $missedOnly) {
                    Text("All").tag(false)
                    Text("Missed").tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 150)
                Menu {
                    Button("Clear call history …", role: .destructive) { Task { await clear() } }
                        .disabled(store.log.records.isEmpty)
                } label: { Image(systemName: "ellipsis.circle") }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .iconHelp("More")
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            Divider()
            if records.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: missedOnly ? "phone.arrow.down.left" : "phone").font(.system(size: 28)).foregroundStyle(.tertiary)
                    Text(missedOnly ? "No missed calls" : "No recent calls").foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(records) { r in
                    CallRow(record: r) { open(r.peerKey) }
                        .contextMenu {
                            Button("Call back") { callBack(r.peerKey) }
                                .disabled(model.callUnavailableReason(r.peerKey) != nil)
                            Button("Open chat") { open(r.peerKey) }
                            Divider()
                            Button("Remove from call history", role: .destructive) { store.remove(r.id) }
                        }
                }
                .listStyle(.inset)
            }
            Divider()
            HStack {
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding(12)
        }
        .frame(width: 460, height: 540)
        .onAppear { store.markSeen() }
        .onDisappear { store.markSeen() }
    }

    private func open(_ key: String) {
        dismiss()
        model.openPicked(key)
    }

    private func callBack(_ key: String) {
        dismiss()
        Task { await model.startCall(key) }
    }

    private func clear() async {
        if await Dialogs.confirm("Clear call history?", "All calls are removed from this list. Chats are not affected.",
                                 ok: "Clear", destructive: true) {
            store.removeAll()
        }
    }
}

private struct CallRow: View {
    @Environment(AppModel.self) private var model
    let record: CallRecord
    let open: () -> Void

    var body: some View {
        let r = record
        let c = model.chats.convs[r.peerKey]
        let unavailable = model.callUnavailableReason(r.peerKey)
        let detail = r.durationSeconds > 0 ? "\(r.title) · \(CallRecord.durationText(r.durationSeconds))" : r.title
        HStack(spacing: 10) {
            if let c { AvatarView(image: model.avatarImage(c), size: 34) }
            VStack(alignment: .leading, spacing: 2) {
                Text(c.map(model.title) ?? r.peerKey).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                    .foregroundStyle(r.isMissed ? Color.red : Color.primary)
                Label(detail, systemImage: Self.icon(r))
                    .labelStyle(.titleAndIcon)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 6)
            Text(ChatListItem.shortTime(Date(timeIntervalSince1970: TimeInterval(r.startedMs) / 1000)))
                .font(.caption)
                .foregroundStyle(.secondary)
            Button { Task { await model.startCall(r.peerKey) } } label: { Image(systemName: "phone.fill") }
                .buttonStyle(.borderless)
                .foregroundStyle(unavailable == nil ? Theme.signalBlue : Color.secondary)
                .disabled(unavailable != nil)
                .iconHelp("Call back", tooltip: unavailable ?? "Call back")
        }
        .padding(.vertical, 3)
        .contentShape(Rectangle())
        .onTapGesture(count: 1, perform: open)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction(named: "Call back") { Task { await model.startCall(r.peerKey) } }
    }

    static func icon(_ r: CallRecord) -> String {
        switch r.outcome {
        case .missed: return "phone.arrow.down.left.fill"
        case .declined, .failed, .unanswered: return r.outgoing ? "phone.arrow.up.right" : "phone.down"
        default: return r.outgoing ? "phone.arrow.up.right" : "phone.arrow.down.left"
        }
    }
}
