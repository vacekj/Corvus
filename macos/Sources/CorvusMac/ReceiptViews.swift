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

/// Sent: one bare check; delivered: two muted bare checks; read: two bright bare checks.
/// One stroked shape only — the double check is part of the same path, no overlapping SF Symbols.
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
            .foregroundStyle(status >= 2 ? read : muted)
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

/// The receipt check: (1,5)→(4,8)→(10,1) and, when double, a second (9,7)→(10,8)→(16,1).
/// Single checks use an 11×10 frame, double checks 17×10; the stroke is 1.35 with round caps and joins.
private struct ReceiptTickStroke: Shape {
    let double: Bool

    func path(in rect: CGRect) -> Path {
        let baseWidth: CGFloat = double ? 17 : 11
        let sx = rect.width / baseWidth, sy = rect.height / 10
        func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: rect.minX + x * sx, y: rect.minY + y * sy)
        }
        var p = Path()
        p.move(to: point(1, 5))
        p.addLine(to: point(4, 8))
        p.addLine(to: point(10, 1))
        if double {
            p.move(to: point(9, 7))
            p.addLine(to: point(10, 8))
            p.addLine(to: point(16, 1))
        }
        return p
    }
}

/// The receipt check shared by message rows and the chat list: nil while sending.
struct ReceiptTicks: View {
    let status: Int?

    var body: some View {
        if let status {
            ReceiptTickStroke(double: status >= 1)
                .stroke(.foreground, style: StrokeStyle(lineWidth: 1.35, lineCap: .round, lineJoin: .round))
                .frame(width: status >= 1 ? 17 : 11, height: 10)
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
