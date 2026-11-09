import CorvusCore
import SwiftUI

/// Help → Keyboard shortcuts (⌘/), like Signal Desktop's shortcut guide.
struct KeyboardShortcutsSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Keyboard shortcuts").font(.title3.weight(.semibold))
                Spacer()
                Button { dismiss() } label: { Image(systemName: "xmark.circle.fill").font(.system(size: 16)) }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                    .keyboardShortcut(.cancelAction)
                    .iconHelp("Close", tooltip: "Close (Esc)")
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
            Divider()
            ScrollView {
                LazyVGrid(columns: [GridItem(.flexible(), alignment: .top), GridItem(.flexible(), alignment: .top)],
                          alignment: .leading, spacing: 22) {
                    ForEach(ShortcutCatalog.sections, id: \.title) { section in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(section.title).font(.headline)
                            ForEach(section.entries, id: \.self) { entry in
                                ShortcutRow(entry: entry)
                            }
                        }
                    }
                }
                .padding(20)
            }
        }
        .frame(width: 720, height: 560)
    }
}

private struct ShortcutRow: View {
    let entry: ShortcutEntry

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(entry.action).frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 4) {
                ForEach(Array(entry.alternatives.enumerated()), id: \.offset) { i, keys in
                    if i > 0 { Text("or").font(.caption).foregroundStyle(.secondary) }
                    ForEach(Array(keys.enumerated()), id: \.offset) { _, key in KeyCap(key) }
                }
            }
            .fixedSize()
        }
        .font(.callout)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(entry.action)
        .accessibilityValue(entry.alternatives.map(ShortcutCatalog.text).joined(separator: " or "))
    }
}

private struct KeyCap: View {
    let key: String
    init(_ key: String) { self.key = key }

    var body: some View {
        Text(key)
            .font(.system(size: 12, weight: .medium, design: .rounded))
            .padding(.horizontal, 6)
            .frame(minWidth: 22, minHeight: 20)
            .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(Color.secondary.opacity(0.14)))
            .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous).strokeBorder(Color.secondary.opacity(0.25)))
    }
}
