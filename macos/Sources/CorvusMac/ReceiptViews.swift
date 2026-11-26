import AppKit
import CorvusCore
import SwiftUI

extension AppModel {
    /// A recipient confirmed delivery or reading of outgoing messages.
    func handleReceipt(_ r: ReceiptEvent) {
        let who = chats.resolveKey(r.sender)
        let recs = chats.applyReceipt(who, recipient: who, status: r.status, timestamps: r.timestamps,
                                      atMs: r.timeMs > 0 ? r.timeMs : nowMs())
        if !recs.isEmpty { persist(recs) }
    }
}

extension Message {
    static func receiptLabel(_ status: Int) -> String {
        status >= 2 ? "Read" : status == 1 ? "Delivered" : "Sent"
    }
}

/// Signal's message status icons: dotted circle (sending), circled check (sent), two outlined circles
/// (delivered), two filled circles (read), all in the colour of the time next to them.
struct DeliveryTicks: View {
    let message: Message
    let pending: Bool
    let isGroup: Bool
    let muted: Color
    let read: Color

    @Environment(AppModel.self) private var model
    @Environment(\.messageHovered) private var hovered
    @Environment(\.conversationKey) private var conversationKey

    private var status: Int { pending ? 0 : message.deliveryStatus }

    var body: some View {
        if hovered && !pending {
            // Names and dates are built only while the pointer is over the message: a tooltip for
            // every bubble would format timestamps throughout long lists.
            ticks.help(hoverLines().joined(separator: "\n"))
        } else {
            ticks
        }
    }

    private var ticks: some View {
        ReceiptTicks(status: pending ? nil : status)
            .foregroundStyle(muted)
    }

    // The hover text: for direct chats when the message was read (or delivered), for groups the
    // totals plus one line per recipient — every reader with its read time, delivered-only and
    // still-sent recipients told apart.
    private func hoverLines() -> [String] {
        let detail = message.receiptHover(isGroup: isGroup,
                                          directKey: isGroup ? "" : conversationKey,
                                          resolve: { model.chats.resolveKey($0) }) {
            model.displayName($0)
        }
        var lines: [String] = []
        if !isGroup {
            let row = detail.rows.first
            let status = row?.status ?? message.deliveryStatus
            if status >= 2 {
                let ms = row?.readAtMs ?? 0
                lines.append(ms > 0 ? "Read · \(Self.time(ms))" : "Read · time unavailable")
            } else if status == 1 {
                let ms = row?.deliveredAtMs ?? 0
                lines.append(ms > 0 ? "Delivered · \(Self.time(ms))" : "Delivered")
            } else {
                lines.append("Sent")
            }
        } else if detail.rows.isEmpty {
            // A legacy group record can carry an aggregate status without per-recipient receipts.
            lines.append(message.receiptStatus > 0
                ? "\(Message.receiptLabel(message.receiptStatus)) · recipient details unavailable"
                : "Sent")
        } else {
            if detail.total > 0 {
                lines.append("Delivered to \(detail.deliveredCount) of \(detail.total), read by \(detail.readCount)")
            } else {
                lines.append("Delivered to \(detail.deliveredCount), read by \(detail.readCount)")
            }
            for r in detail.rows {
                if r.status >= 2 {
                    lines.append(r.readAtMs > 0
                        ? "\(r.name): Read · \(Self.time(r.readAtMs))"
                        : "\(r.name): Read · time unavailable")
                } else if r.status == 1 {
                    lines.append(r.deliveredAtMs > 0
                        ? "\(r.name): Delivered · \(Self.time(r.deliveredAtMs))"
                        : "\(r.name): Delivered")
                } else {
                    lines.append("\(r.name): Sent")
                }
            }
            if message.receiptStatus > (detail.rows.map(\.status).max() ?? 0) {
                lines.append("\(Message.receiptLabel(message.receiptStatus)) · recipient details unavailable")
            }
        }
        return lines
    }

    /// Localized date and time, seconds included, of a receipt timestamp (never the sent time).
    private static func time(_ ms: Int64) -> String {
        Date(timeIntervalSince1970: TimeInterval(ms) / 1000).formatted(date: .abbreviated, time: .standard)
    }
}

/// The receipt icon shared by message rows and the chat list: nil while sending.
struct ReceiptTicks: View {
    let status: Int?

    var body: some View {
        let (name, width): (String, CGFloat) = switch status {
        case nil: ("sending", 12)
        case 0?: ("sent", 12)
        case 1?: ("delivered", 18)
        default: ("read", 18)
        }
        Image(nsImage: ReceiptIcons.image(name))
            .renderingMode(.template)
            .resizable()
            .frame(width: width, height: 12)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(status.map { Message.receiptLabel($0) } ?? "Sending")
    }
}

/// The four status SVGs from Signal Desktop, loaded once as template images.
@MainActor
enum ReceiptIcons {
    private static var cache: [String: NSImage] = [:]

    static func image(_ name: String) -> NSImage {
        if let i = cache[name] { return i }
        let i = AppResources.bundle.image(forResource: "messagestatus-" + name) ?? NSImage()
        i.isTemplate = true
        cache[name] = i
        return i
    }
}

/// "Info …" of a message: time, and for outgoing messages the delivery and read state per recipient.
struct MessageInfoSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let messageId: String

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Message info").font(TypeScale.title3.weight(.semibold))
            if let found = model.message(withId: messageId), let c = model.currentConversation {
                let m = found.message
                LabeledContent("Sent", value: m.time.formatted(date: .abbreviated, time: .standard))
                if m.outgoing {
                    let rows = recipients(m, c)
                    if rows.isEmpty {
                        Text("No recipient status is available yet.").foregroundStyle(.secondary)
                    } else {
                        Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 6) {
                            GridRow {
                                Text("Recipient"); Text("Status"); Text("Delivered"); Text("Read")
                            }
                            .font(TypeScale.caption.weight(.semibold)).foregroundStyle(.secondary)
                            Divider()
                            ForEach(rows, id: \.key) { key, r in
                                GridRow {
                                    Text(model.displayName(key))
                                    Text(Message.receiptLabel(r.status))
                                    Text(Self.time(r.deliveredAtMs))
                                    Text(Self.time(r.readAtMs))
                                }
                            }
                        }
                    }
                } else {
                    LabeledContent("From", value: model.senderName(m))
                }
            } else {
                Text("The message is no longer available.").foregroundStyle(.secondary)
            }
            HStack {
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(22)
        .frame(minWidth: 420)
    }

    private func recipients(_ m: Message, _ c: Conversation) -> [(key: String, value: RecipientReceipt)] {
        var all = m.recipientReceipts
        if !c.isGroup && all[c.key] == nil && !c.key.isEmpty { all[c.key] = RecipientReceipt(status: m.receiptStatus) }
        return all.sorted { model.displayName($0.key).localizedStandardCompare(model.displayName($1.key)) == .orderedAscending }
            .map { (key: $0.key, value: $0.value) }
    }

    private static func time(_ ms: Int64) -> String {
        ms > 0 ? Date(timeIntervalSince1970: TimeInterval(ms) / 1000).formatted(date: .abbreviated, time: .shortened) : "–"
    }
}
