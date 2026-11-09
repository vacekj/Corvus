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

/// Sent: one tick; delivered: two ticks; read: two filled ticks.
struct DeliveryTicks: View {
    let message: Message
    let pending: Bool

    var body: some View {
        ReceiptTicks(status: pending ? nil : message.deliveryStatus).help(pending ? "Sending" : helpText(message.deliveryStatus))
    }

    private func helpText(_ status: Int) -> String {
        let n = message.recipientReceipts.count
        guard n > 1 else { return Message.receiptLabel(status) }
        let delivered = message.recipients(withStatusAtLeast: 1).count, read = message.recipients(withStatusAtLeast: 2).count
        return "Delivered to \(delivered) of \(n), read by \(read)"
    }
}

/// The ticks alone (also in the chat list): nil while sending.
struct ReceiptTicks: View {
    let status: Int?

    var body: some View {
        if let status {
            let symbol = status >= 2 ? "checkmark.circle.fill" : "checkmark.circle"
            HStack(spacing: -5) {
                if status >= 1 { Image(systemName: symbol) }
                Image(systemName: symbol)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Message.receiptLabel(status))
        } else {
            Image(systemName: "circle.dotted").accessibilityLabel("Sending")
        }
    }
}

/// "Info …" of a message: time, and for outgoing messages the delivery and read state per recipient.
struct MessageInfoSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let messageId: String

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Message info").font(.title3.weight(.semibold))
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
                            .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
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
                    LabeledContent("From", value: m.sender.isEmpty ? model.displayName(m.authorKey) : m.sender)
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
