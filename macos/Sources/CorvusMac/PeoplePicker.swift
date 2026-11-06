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
    var id: String { key }

    static func == (a: PickerPerson, b: PickerPerson) -> Bool {
        a.key == b.key && a.title == b.title && a.detail == b.detail && a.avatar === b.avatar && a.lastTs == b.lastTs
    }

    func matches(_ q: String, digits: String) -> Bool {
        if q.isEmpty { return true }
        if title.localizedStandardContains(q) || detail.localizedCaseInsensitiveContains(q) { return true }
        return digits.count >= 3 && key.filter(\.isNumber).contains(digits)
    }
}

extension AppModel {
    /// Most recently contacted first, then by name.
    func pickerPeople() -> [PickerPerson] {
        func detail(_ key: String, title: String) -> String {
            let uuidLike = key.count == 36 && key.filter({ $0 == "-" }).count == 4
            return key == title || uuidLike ? "" : key
        }
        var out: [String: PickerPerson] = [:]
        for c in chats.convs.values where !c.isGroup && !c.key.isEmpty && c.key != account && !isBlocked(c.key) {
            let t = title(c)
            out[c.key] = PickerPerson(key: c.key, title: t, detail: detail(c.key, title: t), avatar: avatarImage(c),
                                      lastTs: c.msgs.last?.ts ?? 0)
        }
        for e in roster.pickableContacts {
            let k = chats.resolveKey(e.key)
            guard !k.isEmpty, out[k] == nil, k != account, !isBlocked(k) else { continue }
            let named = chats.displayName(k)
            let t = named.isEmpty ? e.title : named
            out[k] = PickerPerson(key: k, title: t, detail: detail(k, title: t),
                                  avatar: avatars[k] ?? Media.placeholderAvatar(key: k, title: t), lastTs: 0)
        }
        return out.values.sorted { a, b in
            a.lastTs != b.lastTs ? a.lastTs > b.lastTs : a.title.localizedStandardCompare(b.title) == .orderedAscending
        }
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
private struct PickerKeys: ViewModifier {
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

/// "New conversation": search people (recent chats first) or enter a phone number / username.
struct NewConversationSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var filter = ""
    @State private var people: [PickerPerson] = []
    @State private var index = 0

    private enum Choice: Identifiable {
        case person(PickerPerson)
        case address(String)
        var id: String { switch self { case .person(let p): p.key; case .address(let a): "::" + a } }
    }

    /// What was typed, if it can be an address: "+420 123 …" or "name.12".
    private static func address(_ q: String) -> String? {
        let compact = q.filter { !" -()".contains($0) }
        if compact.hasPrefix("+"), compact.count >= 8, compact.dropFirst().allSatisfy(\.isNumber) { return compact }
        if !q.contains(" "), let dot = q.lastIndex(of: "."), q[q.index(after: dot)...].count >= 2,
           q[q.index(after: dot)...].allSatisfy(\.isNumber), q.distance(from: q.startIndex, to: dot) >= 3 { return q }
        return nil
    }

    var body: some View {
        let q = filter.trimmingCharacters(in: .whitespaces)
        let digits = q.filter(\.isNumber)
        let matches = people.filter { $0.matches(q, digits: digits) }
        var choices: [Choice] = matches.map { .person($0) }
        if let a = Self.address(q), !people.contains(where: { $0.key == a }) { choices.insert(.address(a), at: 0) }
        return VStack(alignment: .leading, spacing: 10) {
            Text("New conversation").font(.title3.weight(.semibold))
            SearchField(text: $filter, prompt: "Name, phone number (+…) or username")
                .modifier(PickerKeys(count: choices.count, index: $index) {
                    if choices.indices.contains(index) { pick(choices[index]) }
                })
                .onChange(of: filter) { index = 0 }
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(choices.enumerated()), id: \.element.id) { i, c in
                            Group {
                                switch c {
                                case .person(let p): PickerRow(person: p, highlighted: i == index)
                                case .address(let a):
                                    HStack(spacing: 10) {
                                        Image(systemName: "plus.message").font(.system(size: 16))
                                            .frame(width: 32, height: 32).background(Circle().fill(Theme.field))
                                        Text("Message \(a)").lineLimit(1)
                                        Spacer(minLength: 0)
                                    }
                                    .padding(.horizontal, 8).padding(.vertical, 4)
                                    .background(RoundedRectangle(cornerRadius: 7).fill(i == index ? Theme.signalBlue.opacity(0.22) : .clear))
                                    .contentShape(Rectangle())
                                }
                            }
                            .id(c.id)
                            .onTapGesture { pick(c) }
                        }
                    }
                }
                .onChange(of: index) { if choices.indices.contains(index) { proxy.scrollTo(choices[index].id) } }
            }
            .frame(height: 320)
            .overlay {
                if choices.isEmpty {
                    Text(q.isEmpty ? "No contacts yet" : "No one matches “\(q)”.\nType a phone number with + and country code, or a username like name.12.")
                        .multilineTextAlignment(.center).foregroundStyle(.secondary).padding()
                }
            }
            HStack {
                Text("↑↓ to move, Return to open").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
            }
        }
        .padding(20)
        .frame(width: 420)
        .onAppear { people = model.pickerPeople() }
    }

    private func pick(_ c: Choice) {
        dismiss()
        switch c {
        case .person(let p): model.startConversation(p.key)
        case .address(let a): model.startConversation(a)
        }
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
        .onAppear { if autofocus { focused = true } }
    }
}
