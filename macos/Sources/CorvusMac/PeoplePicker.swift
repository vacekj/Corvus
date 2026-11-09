import AppKit
import CorvusCore
import SwiftUI

/// A person to pick (new chat, group members): everyone with a 1:1 chat plus signal-cli's contacts.
struct PickerPerson: Identifiable, Equatable {
    let key: String
    let title: String
    let detail: String      // phone number / username, empty when the title already shows it
    let avatar: NSImage
    let lastTs: Int64       // last message in the chat, 0 if none
    var activity: Double = 0 // how much the user has been writing with them lately (PickerRanking.activity)
    var id: String { key }

    static func == (a: PickerPerson, b: PickerPerson) -> Bool {
        a.key == b.key && a.title == b.title && a.detail == b.detail && a.avatar === b.avatar && a.lastTs == b.lastTs
            && a.activity == b.activity
    }

    /// Most written with lately first, then most recent, then by name.
    static func busierFirst(_ a: PickerPerson, _ b: PickerPerson) -> Bool {
        if a.activity != b.activity { return a.activity > b.activity }
        if a.lastTs != b.lastTs { return a.lastTs > b.lastTs }
        return a.title.localizedStandardCompare(b.title) == .orderedAscending
    }

    func matches(_ q: String, digits: String) -> Bool {
        if q.isEmpty { return true }
        if title.localizedStandardContains(q) || detail.localizedCaseInsensitiveContains(q) { return true }
        return digits.count >= 3 && key.filter(\.isNumber).contains(digits)
    }
}

extension AppModel {
    /// The people the user writes with most lately first (see `PickerPerson.busierFirst`). A person known
    /// both by number and by UUID (a chat from before the number was known) is listed once.
    func pickerPeople() -> [PickerPerson] {
        func detail(_ key: String, title: String) -> String {
            key == title || People.isServiceId(key) ? "" : key
        }
        let now = nowMs()
        var numberOf: [String: String] = [:]
        for e in roster.contacts where !e.uuid.isEmpty && !e.number.isEmpty { numberOf[e.uuid] = e.number }
        var out: [String: PickerPerson] = [:]
        func add(_ p: PickerPerson) {
            let k = numberOf[p.key] ?? p.key
            guard let other = out[k] else { out[k] = p; return }
            // The chat written in most is the one to open; it takes the activity of both.
            let (main, rest) = PickerPerson.busierFirst(p, other) ? (p, other) : (other, p)
            out[k] = PickerPerson(key: main.key, title: main.title, detail: main.detail.isEmpty ? rest.detail : main.detail,
                                  avatar: main.avatar, lastTs: max(main.lastTs, rest.lastTs), activity: main.activity + rest.activity)
        }
        for c in chats.convs.values where !c.isGroup && !c.key.isEmpty && c.key != account && !isBlocked(c.key) {
            let t = title(c)
            add(PickerPerson(key: c.key, title: t, detail: detail(c.key, title: t), avatar: avatarImage(c),
                             lastTs: c.msgs.last?.ts ?? 0, activity: PickerRanking.activity(c.msgs.reversed().lazy.map { ($0.ts, $0.outgoing) }, now: now)))
        }
        for e in roster.pickableContacts {
            let k = chats.resolveKey(e.key)
            guard !k.isEmpty, out[k] == nil, out[numberOf[k] ?? k] == nil, chats.convs[k] == nil, k != account, !isBlocked(k)
            else { continue }
            let named = chats.displayName(k)
            let t = named.isEmpty ? e.title : named
            // A contact known only by UUID with the same name as someone the user has a chat with is that person.
            if People.isServiceId(k), out.values.contains(where: { $0.title == t }) { continue }
            add(PickerPerson(key: k, title: t, detail: detail(k, title: t),
                             avatar: avatars[k] ?? Media.placeholderAvatar(key: k, title: t), lastTs: 0))
        }
        // A chat kept under a UUID (from before the number was known) next to the numbered chat of a
        // person with the same name: one person.
        for (k, p) in out where People.isServiceId(p.key) {
            guard let (ok, other) = out.first(where: { $0.key != k && !People.isServiceId($0.value.key) && $0.value.title == p.title })
            else { continue }
            out.removeValue(forKey: k)
            let (main, rest) = PickerPerson.busierFirst(p, other) ? (p, other) : (other, p)
            out[ok] = PickerPerson(key: main.key, title: main.title, detail: other.detail, avatar: other.avatar,
                                   lastTs: max(main.lastTs, rest.lastTs), activity: main.activity + rest.activity)
        }
        return out.values.sorted(by: PickerPerson.busierFirst)
    }
}

struct PickerRow: View {
    let person: PickerPerson
    var checked: Bool?      // nil: no checkbox
    var highlighted = false

    var body: some View {
        HStack(spacing: 10) {
            if let checked {
                Image(systemName: checked ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 16))
                    .foregroundStyle(checked ? Theme.signalBlue : .secondary)
            }
            Image(nsImage: person.avatar).resizable().interpolation(.high)
                .frame(width: 32, height: 32).clipShape(Circle())
            VStack(alignment: .leading, spacing: 1) {
                Text(person.title).lineLimit(1)
                if !person.detail.isEmpty {
                    Text(person.detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(RoundedRectangle(cornerRadius: 7).fill(highlighted ? Theme.signalBlue.opacity(0.22) : .clear))
        .contentShape(Rectangle())
    }
}

/// Arrow keys move, Return picks: shared by both pickers.
struct PickerKeys: ViewModifier {
    let count: Int
    @Binding var index: Int
    let pick: () -> Void

    func body(content: Content) -> some View {
        content
            .onKeyPress(.downArrow) { index = min(index + 1, max(count - 1, 0)); return .handled }
            .onKeyPress(.upArrow) { index = max(index - 1, 0); return .handled }
            .onSubmit(pick)
    }
}

/// Multi-select list for group members.
struct ContactPicker: View {
    @Environment(AppModel.self) private var model
    @Binding var selection: [String]
    var exclude: Set<String> = []
    @State private var filter = ""
    @State private var people: [PickerPerson] = []
    @State private var index = 0
    @State private var keyboard = false     // highlight only once the arrow keys or typing are used

    var body: some View {
        let q = filter.trimmingCharacters(in: .whitespaces)
        let digits = q.filter(\.isNumber)
        let list = people.filter { !exclude.contains($0.key) && $0.matches(q, digits: digits) }
        VStack(alignment: .leading, spacing: 6) {
            SearchField(text: $filter, prompt: "Search by name or number", autofocus: false)
                .modifier(PickerKeys(count: list.count, index: $index) {
                    if list.indices.contains(index) { toggle(list[index].key) }
                })
                .onChange(of: filter) { index = 0; keyboard = true }
            if !selection.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(selection, id: \.self) { key in
                            Button { toggle(key) } label: {
                                HStack(spacing: 4) {
                                    Text(people.first { $0.key == key }?.title ?? key).lineLimit(1)
                                    Image(systemName: "xmark").font(.system(size: 9, weight: .bold))
                                }
                                .padding(.horizontal, 9).padding(.vertical, 4)
                                .background(Capsule().fill(Theme.signalBlue.opacity(0.2)))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(list.enumerated()), id: \.element.key) { i, p in
                            PickerRow(person: p, checked: selection.contains(p.key), highlighted: keyboard && i == index)
                                .id(p.key)
                                .onTapGesture { index = i; toggle(p.key) }
                        }
                    }
                }
                .onChange(of: index) { keyboard = true; if list.indices.contains(index) { proxy.scrollTo(list[index].key) } }
            }
            .overlay {
                if list.isEmpty {
                    Text(q.isEmpty ? (model.roster.contactsLoaded ? "No contacts" : "Loading contacts …") : "No one matches “\(q)”")
                        .foregroundStyle(.secondary)
                }
            }
            Text(selection.isEmpty ? "Click people to add them" : "\(selection.count) selected")
                .font(.caption).foregroundStyle(.secondary)
        }
        .onAppear { people = model.pickerPeople() }
    }

    private func toggle(_ key: String) {
        if selection.contains(key) { selection.removeAll { $0 == key } } else { selection.append(key) }
    }
}

/// A rounded search field that takes the focus when it appears.
struct SearchField: View {
    @Binding var text: String
    let prompt: String
    var autofocus = true
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField(prompt, text: $text).textFieldStyle(.plain).focused($focused)
            if !text.isEmpty {
                Button { text = "" } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.borderless).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 8).fill(Theme.field))
        .onAppear {
            guard autofocus else { return }
            // Take the caret from the composer (an AppKit text view keeps it unless the window lets go).
            NSApp.keyWindow?.makeFirstResponder(nil)
            focused = true
            DispatchQueue.main.async { focused = true }
        }
    }
}
