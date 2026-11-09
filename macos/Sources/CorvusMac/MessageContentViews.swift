import AppKit
import CorvusCore
import Observation
import SwiftUI

// Bubble content beyond text and attachments: shared contacts, payments, shared locations, the
// disappearing-message countdown and chat notices.

// MARK: - Disappearing messages

/// One clock for all countdown icons on screen. It runs only while an icon is shown, and only as often as the
/// shortest timer among them needs (from once a second for 30-second timers to once a minute).
@MainActor @Observable
final class ExpiryClock {
    static let shared = ExpiryClock()

    /// Read by the icons to update with the clock; the time itself is taken when drawing.
    private(set) var tick = 0
    @ObservationIgnored private var shown: [Int: Int] = [:]    // timer seconds -> icons on screen
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var interval: TimeInterval = 0

    func add(_ seconds: Int) {
        shown[seconds, default: 0] += 1
        reschedule()
    }

    func remove(_ seconds: Int) {
        guard let n = shown[seconds] else { return }
        shown[seconds] = n > 1 ? n - 1 : nil
        reschedule()
    }

    private func reschedule() {
        guard let shortest = shown.keys.min() else {
            timer?.invalidate()
            timer = nil
            interval = 0
            return
        }
        let want = DisappearingTimer.tickInterval(shortestSeconds: shortest)
        if timer != nil && want == interval { return }
        timer?.invalidate()
        interval = want
        let t = Timer(timeInterval: want, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick &+= 1 }
        }
        t.tolerance = want / 5
        RunLoop.main.add(t, forMode: .common) // also while the list is being scrolled
        timer = t
    }
}

/// The countdown of a disappearing message in the time row: a circle that empties like Signal's timer icon.
struct ExpiryCountdownIcon: View {
    let seconds: Int
    let startMs: Int64

    var body: some View {
        // Not started (unread) messages stay full and need no clock.
        if startMs <= 0 {
            ExpiryPie(step: DisappearingTimer.steps)
        } else {
            Running(seconds: seconds, startMs: startMs)
        }
    }

    private struct Running: View {
        let seconds: Int
        let startMs: Int64
        private let clock = ExpiryClock.shared

        var body: some View {
            _ = clock.tick
            return ExpiryPie(step: DisappearingTimer.step(expiresInSeconds: seconds, startMs: startMs, now: nowMs()))
                .onAppear { clock.add(seconds) }
                .onDisappear { clock.remove(seconds) }
        }
    }
}

private struct ExpiryPie: View, Equatable {
    let step: Int

    var body: some View {
        let fraction = Double(step) / Double(DisappearingTimer.steps)
        ZStack {
            Circle().strokeBorder(lineWidth: 1.1)
            PieSlice(fraction: fraction).padding(2.2)
        }
        .frame(width: 10, height: 10)
        .accessibilityLabel("Disappearing message")
    }
}

private struct PieSlice: Shape {
    let fraction: Double

    func path(in rect: CGRect) -> Path {
        var p = Path()
        guard fraction > 0 else { return p }
        let c = CGPoint(x: rect.midX, y: rect.midY)
        if fraction >= 1 { p.addEllipse(in: rect); return p }
        p.move(to: c)
        p.addArc(center: c, radius: min(rect.width, rect.height) / 2, startAngle: .degrees(-90),
                 endAngle: .degrees(-90 + 360 * fraction), clockwise: false)
        p.closeSubpath()
        return p
    }
}

/// "You set the disappearing message timer to 1 week." between the bubbles.
struct ChatNoticeRow: View {
    @Environment(AppModel.self) private var model
    let message: Message

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: message.notice.seconds > 0 ? "timer" : "timer.slash")
            Text(text)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity)
        .help(message.time.formatted(date: .abbreviated, time: .shortened))
    }

    private var text: String {
        switch message.notice.kind {
        case .timer:
            let mine = message.authorKey.isEmpty || message.authorKey == model.account
            let name = mine ? nil : (message.sender.isEmpty ? model.displayName(message.authorKey) : message.sender)
            return DisappearingTimer.noticeText(message.notice.seconds, actor: name)
        case .none:
            return message.text
        }
    }
}

extension AppModel {
    /// A timer change becomes a note in the chat (incoming, from our other devices, or set here).
    /// `by` is the key of whoever changed it (the own number for the user).
    func addTimerNotice(_ key: String, seconds: Int, by: String, ts: Int64) {
        guard chats.convs[key] != nil else { return }
        var m = Message()
        m.ts = ts > 0 ? ts : nowMs()
        m.authorKey = by.isEmpty ? account : by
        let mine = m.authorKey == account
        m.sender = mine ? "You" : displayName(m.authorKey)
        m.notice = .timer(seconds)
        m.text = DisappearingTimer.noticeText(seconds, actor: mine ? nil : m.sender) // fallback (Qt app, chat list)
        guard let (_, recs) = chats.addMessage(key, m) else { return }
        persist(recs)
        listChanged()
    }

    /// Sets the chat's timer after a change; a real change also leaves a note in the chat.
    func noteTimerChange(_ key: String, seconds: Int, by: String, ts: Int64) {
        guard let c = chats.convs[key], c.expirationSeconds != seconds else { return }
        chats.convs[key]!.expirationSeconds = seconds
        persist(Records.expiration(key, seconds))
        addTimerNotice(key, seconds: seconds, by: by, ts: ts)
    }
}

// MARK: - Contacts, payments, locations

extension AppModel {
    /// The open chat's search text, for highlighting it in the bubbles.
    var searchHighlightQuery: String? {
        let q = searchText.trimmingCharacters(in: .whitespaces)
        return q.isEmpty ? nil : q
    }
}

extension Message {
    /// Bubble content shown by `MessageExtraContent` (and instead of the text when `replacesText`).
    var hasExtraContent: Bool { !sharedContacts.isEmpty || payment != nil || location != nil }
    var extraReplacesText: Bool { textIsFallback || location != nil }
    var location: LocationShare? { text.isEmpty ? nil : LocationShare.parse(text) }
}

struct MessageExtraContent: View {
    let message: Message
    let foreground: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(message.sharedContacts.enumerated()), id: \.offset) { _, c in
                ContactCard(contact: c, foreground: foreground)
            }
            if let p = message.payment { PaymentCard(payment: p, message: message, foreground: foreground) }
            if let loc = message.location { LocationCard(location: loc, foreground: foreground) }
        }
    }
}

private struct ContactCard: View {
    @Environment(AppModel.self) private var model
    let contact: SharedContact
    let foreground: Color
    @State private var detailsShown = false
    @State private var avatar: NSImage?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button { detailsShown = true } label: {
                HStack(spacing: 10) {
                    AvatarView(image: avatar ?? Media.placeholderAvatar(key: contact.signalNumber ?? contact.displayName,
                                                                       title: contact.displayName), size: 40)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(contact.displayName).font(.system(size: NSFont.systemFontSize + 1, weight: .semibold)).lineLimit(2)
                        if let sub = subtitle { Text(sub).font(.caption).opacity(0.8).lineLimit(1) }
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Show contact details")
            .popover(isPresented: $detailsShown, arrowEdge: .trailing) { ContactDetails(contact: contact) }
            if let number = contact.signalNumber {
                Divider().overlay(foreground.opacity(0.25))
                Button { model.startConversation(model.chats.resolveKey(number)) } label: {
                    Text("Message").font(.callout.weight(.semibold)).frame(maxWidth: .infinity)
                }
                .buttonStyle(.plain)
                .help("Start a chat with \(number)")
            }
        }
        .foregroundStyle(foreground)
        .frame(minWidth: 200, alignment: .leading)
        .task(id: contact.avatarId) { await loadAvatar() }
    }

    private var subtitle: String? {
        contact.phones.first?.value ?? contact.emails.first?.value ?? (contact.organization.isEmpty ? nil : contact.organization)
    }

    /// The picture sent with the card, if signal-cli has the file (it downloads attachments when receiving).
    private func loadAvatar() async {
        guard !contact.avatarId.isEmpty else { return }
        var att = Attachment()
        att.id = contact.avatarId
        guard let url = AppModel.signalCliAttachmentURL(att) else { return }
        avatar = await MediaImageCache.shared.image("contact-avatar:" + contact.avatarId) {
            await Task.detached(priority: .utility) {
                (try? Data(contentsOf: url)).flatMap { MediaDecode.image($0, maxPixel: 120) }
            }.value
        }
    }
}

private struct ContactDetails: View {
    let contact: SharedContact

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(contact.displayName).font(.headline)
            if !contact.organization.isEmpty && contact.organization != contact.displayName {
                Text(contact.organization).foregroundStyle(.secondary)
            }
            ForEach(Array(contact.phones.enumerated()), id: \.offset) { _, p in row(p.typeLabel.isEmpty ? "Phone" : p.typeLabel, p.value) }
            ForEach(Array(contact.emails.enumerated()), id: \.offset) { _, e in row(e.typeLabel.isEmpty ? "Email" : e.typeLabel, e.value) }
            ForEach(Array(contact.addresses.enumerated()), id: \.offset) { _, a in row("Address", a) }
        }
        .padding(14)
        .frame(minWidth: 240, alignment: .leading)
    }

    private func row(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text(value).textSelection(.enabled)
        }
    }
}

/// Signal Payments (MobileCoin) cannot be shown without a wallet: who sent it, the note, and a notice.
private struct PaymentCard: View {
    @Environment(AppModel.self) private var model
    let payment: PaymentNote
    let message: Message
    let foreground: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "creditcard")
                Text(title).font(.system(size: NSFont.systemFontSize + 1, weight: .semibold))
            }
            if !payment.note.isEmpty { Text(payment.note).fixedSize(horizontal: false, vertical: true) }
            Text("Payments aren't supported here. Open Signal on your phone to see this payment.")
                .font(.caption)
                .opacity(0.75)
                .fixedSize(horizontal: false, vertical: true)
        }
        .foregroundStyle(foreground)
        .frame(minWidth: 200, alignment: .leading)
    }

    private var title: String {
        if message.outgoing { return "You sent a payment" }
        let name = message.sender.isEmpty ? model.displayName(message.authorKey) : message.sender
        return "\(name) sent you a payment"
    }
}

private struct LocationCard: View {
    let location: LocationShare
    let foreground: Color

    var body: some View {
        Button {
            if let url = location.mapsURL { NSWorkspace.shared.open(url) }
        } label: {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "mappin.circle.fill").font(.system(size: 26))
                VStack(alignment: .leading, spacing: 2) {
                    Text(location.title.isEmpty ? "Location" : location.title)
                        .font(.system(size: NSFont.systemFontSize + 1, weight: .semibold))
                    if !location.address.isEmpty { Text(location.address).font(.callout) }
                    Text(location.coordinateText).font(.caption.monospacedDigit()).opacity(0.75)
                }
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(foreground)
        .frame(minWidth: 200, alignment: .leading)
        .help("Open in Maps")
    }
}

// MARK: - Long messages

extension AppModel {
    /// A long message's full text (attachment) replaces the shortened body. Called when a message arrives
    /// and from "Read more" for older messages.
    func loadLongText(_ key: String, ts: Int64, author: String, userInitiated: Bool = false) {
        guard let c = chats.convs[key], let i = chats.findMessage(c, ts: ts, authors: [author]),
              let ai = c.msgs[i].longTextAttachmentIndex else { return }
        let att = c.msgs[i].attachments[ai]
        let token = "longtext|\(key)|\(ts)|\(author)"
        guard !LongTextLoads.pending.contains(token) else { return }
        LongTextLoads.pending.insert(token)
        Task {
            defer { LongTextLoads.pending.remove(token) }
            guard let data = try? await fetchAttachmentData(key, att), !data.isEmpty else {
                if userInitiated { showFlash("The rest of this message is no longer available.", seconds: 5) }
                return
            }
            let full = String(decoding: data, as: UTF8.self)
            if let rec = chats.applyLongText(key, ts: ts, author: author, full: full) {
                persist(rec)
                if key == current { updateSearch() }
            }
        }
    }
}

@MainActor
private enum LongTextLoads {
    static var pending: Set<String> = []
}
