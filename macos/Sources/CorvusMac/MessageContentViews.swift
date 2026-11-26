import AppKit
import CorvusCore
import Observation
import SwiftUI

// Bubble content beyond text and attachments: shared contacts, payments, shared locations and chat notices.

/// "You set the disappearing message timer to 1 week." between the bubbles.
struct ChatNoticeRow: View {
    @Environment(AppModel.self) private var model
    let message: Message

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: message.notice.seconds > 0 ? "timer" : "timer.slash")
            Text(text)
        }
        .font(TypeScale.caption)
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
            let name = mine ? nil : model.senderName(message)
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
                        Text(contact.displayName).font(.inter(NSFont.systemFontSize + 1, weight: .semibold)).lineLimit(2)
                        if let sub = subtitle { Text(sub).font(TypeScale.caption).opacity(0.8).lineLimit(1) }
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
                    Text("Message").font(TypeScale.callout.weight(.semibold)).frame(maxWidth: .infinity)
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

    /// The picture sent with the card, if the backend has the file (it downloads attachments when receiving).
    private func loadAvatar() async {
        guard !contact.avatarId.isEmpty else { return }
        var att = Attachment()
        att.id = contact.avatarId
        guard let url = AppModel.backendAttachmentURL(att) else { return }
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
            Text(contact.displayName).font(TypeScale.headline)
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
            Text(label).font(TypeScale.caption).foregroundStyle(.secondary)
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
                Text(title).font(.inter(NSFont.systemFontSize + 1, weight: .semibold))
            }
            if !payment.note.isEmpty { Text(payment.note).fixedSize(horizontal: false, vertical: true) }
            Text("Payments aren't supported here. Open Signal on your phone to see this payment.")
                .font(TypeScale.caption)
                .opacity(0.75)
                .fixedSize(horizontal: false, vertical: true)
        }
        .foregroundStyle(foreground)
        .frame(minWidth: 200, alignment: .leading)
    }

    private var title: String {
        if message.outgoing { return "You sent a payment" }
        let name = model.senderName(message)
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
                        .font(.inter(NSFont.systemFontSize + 1, weight: .semibold))
                    if !location.address.isEmpty { Text(location.address).font(TypeScale.callout) }
                    Text(location.coordinateText).font(TypeScale.caption.monospacedDigit()).opacity(0.75)
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
