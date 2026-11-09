import SwiftUI
import CorvusCore

/// resources/emoji-catalog.json ({category: [{emoji, tones}]}) and emoji-names.json ({emoji: name}).
@MainActor
enum EmojiCatalog {
    struct Entry: Hashable {
        let emoji: String
        let tones: [String]
    }

    /// The reactions offered under a message, in the default skin tone.
    static var quickReactions: [String] { ["👍", "❤️", "😂", "😮", "😢", "🙏"].map { toned($0) } }

    static let categories: [(key: String, icon: String)] = [
        ("Smileys & People", "😀"), ("Animals & Nature", "🐻"), ("Food & Drink", "🍕"), ("Travel & Places", "🚗"),
        ("Activities", "⚽"), ("Objects", "💡"), ("Symbols", "🔣"), ("Flags", "🏁"),
    ]

    static let catalog: [String: [Entry]] = {
        guard let url = AppResources.url("emoji-catalog", "json"), let data = try? Data(contentsOf: url),
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: [[String: Any]]] else { return [:] }
        return root.mapValues { list in
            list.compactMap { o in
                guard let e = o["emoji"] as? String else { return nil }
                return Entry(emoji: e, tones: o["tones"] as? [String] ?? [])
            }
        }
    }()

    static let names: [String: String] = {
        guard let url = AppResources.url("emoji-names", "json"), let data = try? Data(contentsOf: url) else { return [:] }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: String] ?? [:]
    }()

    private static let recentKey = "emoji.recent"

    static var recent: [String] { UserDefaults.standard.stringArray(forKey: recentKey) ?? [] }

    static func remember(_ e: String) {
        var r = recent.filter { $0 != e }
        r.insert(e, at: 0)
        UserDefaults.standard.set(Array(r.prefix(36)), forKey: recentKey)
    }

    // MARK: Skin tone

    /// Default skin tone (0 = yellow, 1…5 = light … dark), set in Settings or the picker.
    static let skinToneKey = "emoji.skinTone"
    static var skinTone: Int { UserDefaults.standard.integer(forKey: skinToneKey) }

    /// Emoji -> its skin tone variants.
    static let variants: [String: [String]] = {
        var out: [String: [String]] = [:]
        for list in catalog.values { for e in list where !e.tones.isEmpty { out[e.emoji] = e.tones } }
        return out
    }()

    static func toned(_ emoji: String) -> String { toned(emoji, tone: skinTone) }

    static func toned(_ emoji: String, tone: Int) -> String {
        guard tone > 0, let v = variants[emoji] else { return emoji }
        return EmojiSkinTone.apply(tone, to: emoji, variants: v)
    }

    /// The raised hand in each tone, for the tone choosers.
    static let toneSamples: [String] = (0...5).map { toned("✋", tone: $0) }
    static let toneNames = ["Default", "Light", "Medium light", "Medium", "Medium dark", "Dark"]

    // MARK: Shortcodes

    /// ":code:" index for the composer, built on first use (catalog order breaks ties).
    static let shortcodes: EmojiShortcodeIndex = {
        var list: [(emoji: String, name: String)] = []
        for c in categories {
            for e in catalog[c.key] ?? [] { if let n = names[e.emoji] { list.append((e.emoji, n)) } }
        }
        return EmojiShortcodeIndex(names: list)
    }()
}

/// Settings → General: the default skin tone of the emoji picker, ":shortcode:"s and reactions.
struct EmojiSkinToneSetting: View {
    @AppStorage(EmojiCatalog.skinToneKey) private var tone = 0

    var body: some View {
        Picker("Emoji skin tone", selection: $tone) {
            ForEach(0..<6, id: \.self) { t in
                Text("\(EmojiCatalog.toneSamples[t])  \(EmojiCatalog.toneNames[t])").tag(t)
            }
        }
    }
}

/// The tone chooser in the picker's header.
private struct SkinToneMenu: View {
    @AppStorage(EmojiCatalog.skinToneKey) private var tone = 0
    @State private var shown = false

    var body: some View {
        Button { shown.toggle() } label: {
            Text(EmojiCatalog.toneSamples[min(max(tone, 0), 5)]).font(.system(size: 18)).frame(width: 28, height: 24)
        }
        .buttonStyle(.plain)
        .help("Skin tone")
        .popover(isPresented: $shown, arrowEdge: .bottom) {
            HStack(spacing: 2) {
                ForEach(0..<6, id: \.self) { t in
                    Button {
                        tone = t
                        shown = false
                    } label: {
                        Text(EmojiCatalog.toneSamples[t]).font(.system(size: 22)).frame(width: 32, height: 30)
                            .background(RoundedRectangle(cornerRadius: 5).fill(t == tone ? Color.accentColor.opacity(0.25) : .clear))
                    }
                    .buttonStyle(.plain)
                    .help(EmojiCatalog.toneNames[t])
                }
            }
            .padding(6)
        }
    }
}

/// Recently used emojis, search by name and the categories, like the official Signal client.
struct EmojiPicker: View {
    let onPick: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @AppStorage(EmojiCatalog.skinToneKey) private var tone = 0
    @State private var search = ""
    @State private var recent = EmojiCatalog.recent
    @State private var category = EmojiCatalog.recent.isEmpty ? EmojiCatalog.categories[0].key : EmojiPicker.recentKey

    private static let recentKey = "Recently used"
    private let columns = Array(repeating: GridItem(.fixed(34), spacing: 2), count: 9)

    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 6) {
                TextField("Search emojis…", text: $search)
                    .textFieldStyle(.roundedBorder)
                SkinToneMenu()
            }
            if search.isEmpty {
                Text(category).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.leading, 2)
            }
            ScrollView {
                LazyVGrid(columns: columns, spacing: 2) {
                    ForEach(entries, id: \.self) { button($0) }
                }
            }
            .frame(height: 250)
            if search.isEmpty {
                HStack(spacing: 2) {
                    if !recent.isEmpty {
                        categoryButton(Self.recentKey) { Image(systemName: "clock").font(.system(size: 15)) }
                    }
                    ForEach(EmojiCatalog.categories, id: \.key) { c in
                        categoryButton(c.key) { Text(c.icon).font(.title3) }
                    }
                }
            }
        }
        .padding(8)
        .frame(width: 340)
    }

    private func categoryButton<L: View>(_ key: String, @ViewBuilder label: () -> L) -> some View {
        Button { category = key } label: {
            label().frame(width: 32, height: 28)
                .background(RoundedRectangle(cornerRadius: 5).fill(category == key ? Color.accentColor.opacity(0.25) : .clear))
        }
        .buttonStyle(.plain)
        .help(key)
    }

    private var entries: [EmojiCatalog.Entry] {
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        if q.isEmpty {
            // Recent ones are kept as picked (with their tone).
            if category == Self.recentKey { return recent.map { EmojiCatalog.Entry(emoji: $0, tones: []) } }
            return EmojiCatalog.catalog[category] ?? []
        }
        var out: [EmojiCatalog.Entry] = []
        for c in EmojiCatalog.categories {
            for e in EmojiCatalog.catalog[c.key] ?? [] where (EmojiCatalog.names[e.emoji] ?? "").lowercased().contains(q) {
                out.append(e)
            }
        }
        return out
    }

    private func button(_ e: EmojiCatalog.Entry) -> some View {
        let shown = e.tones.isEmpty ? e.emoji : EmojiCatalog.toned(e.emoji, tone: tone)
        return Button {
            pick(shown)
        } label: {
            Text(shown).font(.system(size: 22)).frame(width: 34, height: 32)
        }
        .buttonStyle(.plain)
        .help(EmojiCatalog.names[e.emoji] ?? "")
        .contextMenu {
            if !e.tones.isEmpty {
                Button(e.emoji) { pick(e.emoji) }
                ForEach(e.tones, id: \.self) { t in Button(t) { pick(t) } }
            }
        }
    }

    private func pick(_ e: String) {
        EmojiCatalog.remember(e)
        recent = EmojiCatalog.recent
        onPick(e)
        dismiss()
    }
}
