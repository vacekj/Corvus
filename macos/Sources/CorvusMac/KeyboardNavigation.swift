import AppKit
import CorvusCore
import SwiftUI

/// Keyboard navigation state of the main window: the ⌘K switcher and the chat list search field.
/// Kept out of `AppModel` so opening the switcher never touches views that read the model.
@MainActor @Observable
final class KeyboardNavigation {
    static let shared = KeyboardNavigation()

    var quickSwitcherShown = false
    var sidebarSearchFocus = 0      // incremented by ⌥⌘F to put the caret into the chat list search

    @ObservationIgnored private var tabMonitor: Any?

    /// ⌃Tab / ⌃⇧Tab: next / previous chat, like browser tabs. A key monitor rather than menu items:
    /// a menu item has one shortcut, and ⌥↑ / ⌥↓ already name these commands in the menu.
    func installTabMonitor(_ model: AppModel) {
        guard tabMonitor == nil else { return }
        tabMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak model] e in
            let flags = e.modifierFlags.intersection(.deviceIndependentFlagsMask)
            guard e.keyCode == 48, flags.contains(.control), !flags.contains(.command), !flags.contains(.option) else { return e }
            let window = e.window.map(ObjectIdentifier.init), back = flags.contains(.shift)
            let handled = MainActor.assumeIsolated {
                guard let model, window == MainWindowTracker.shared.window.map(ObjectIdentifier.init),
                      !KeyboardNavigation.shared.quickSwitcherShown else { return false }
                model.openAdjacentChat(back ? -1 : 1)
                return true
            }
            return handled ? nil : e
        }
    }
}

extension AppModel {
    /// Everything the switcher offers: chats (groups included) and contacts without a chat, recent first.
    func switcherEntries() -> [PickerPerson] {
        var list = pickerPeople()
        for c in chats.convs.values where c.isGroup && !isBlocked(c.key) {
            list.append(PickerPerson(key: c.key, title: title(c), detail: "Group", avatar: avatarImage(c), lastTs: c.msgs.last?.ts ?? 0))
        }
        if !account.isEmpty, let me = chats.convs[account] {
            list.append(PickerPerson(key: me.key, title: title(me), detail: "", avatar: avatarImage(me), lastTs: me.msgs.last?.ts ?? 0))
        }
        return list.sorted { a, b in
            a.lastTs != b.lastTs ? a.lastTs > b.lastTs : a.title.localizedStandardCompare(b.title) == .orderedAscending
        }
    }

    /// Opens a chat picked by keyboard (switcher, search): an archived chat opens in the archive folder,
    /// a contact without a chat gets a new one.
    func openPicked(_ key: String) {
        if let c = chats.convs[key] {
            showArchived = c.archived
            openConversation(key)
        } else {
            startConversation(key)
        }
    }

    /// A hit of the chat list's message search: opens the chat with the in-chat search on that message.
    func openMessageHit(_ hit: MessageSearchHit, query: String) {
        openPicked(hit.key)
        guard current == hit.key else { return }
        guard let c = currentConversation,
              let m = c.msgs.first(where: { $0.ts == hit.ts && $0.authorKey == hit.authorKey && $0.outgoing == hit.outgoing })
        else { return }
        searchVisible = true
        searchText = query
        updateSearch(prefer: m.id)
    }
}

// MARK: - ⌘K switcher

/// "Go to conversation": a search panel over the window. ↑/↓ move, Return opens, Esc or a click outside closes.
struct QuickSwitcherOverlay: View {
    private let nav = KeyboardNavigation.shared

    var body: some View {
        if nav.quickSwitcherShown {
            ZStack(alignment: .top) {
                Color.black.opacity(0.18)
                    .contentShape(Rectangle())
                    .onTapGesture { nav.quickSwitcherShown = false }
                QuickSwitcherPanel()
                    .padding(.top, 70)
            }
            .ignoresSafeArea()
            .transition(.opacity)
        }
    }
}

private struct QuickSwitcherPanel: View {
    @Environment(AppModel.self) private var model
    @State private var filter = ""
    @State private var entries: [PickerPerson] = []
    @State private var index = 0
    @State private var keyMonitor: Any?

    private static let limit = 60

    private func results(_ q: String) -> [PickerPerson] {
        if q.isEmpty { return Array(entries.prefix(Self.limit)) }
        let digits = q.filter(\.isNumber)
        let scored = entries.compactMap { p -> (PickerPerson, Int)? in
            var best = FuzzyMatch.score(q, p.title)
            if let d = FuzzyMatch.score(q, p.detail), p.detail != "Group" { best = max(best ?? d, d - 100) }
            if best == nil, digits.count >= 3, p.key.filter(\.isNumber).contains(digits) { best = 1 }
            return best.map { (p, $0) }
        }
        // Equal scores keep the recency order (`entries` is sorted, the sort is stable enough for ties).
        return scored.enumerated().sorted { a, b in
            a.element.1 != b.element.1 ? a.element.1 > b.element.1 : a.offset < b.offset
        }.prefix(Self.limit).map(\.element.0)
    }

    var body: some View {
        let list = results(filter.trimmingCharacters(in: .whitespaces))
        VStack(alignment: .leading, spacing: 8) {
            SearchField(text: $filter, prompt: "Go to conversation")
                .onChange(of: filter) { index = 0 }
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(list.enumerated()), id: \.element.key) { i, p in
                            PickerRow(person: p, highlighted: i == index)
                                .id(p.key)
                                .onTapGesture { open(p.key) }
                        }
                    }
                }
                .onChange(of: index) { if list.indices.contains(index) { proxy.scrollTo(list[index].key) } }
            }
            .frame(height: 320)
            .overlay {
                if list.isEmpty {
                    Text(filter.isEmpty ? "No chats yet" : "No chats match “\(filter)”").foregroundStyle(.secondary)
                }
            }
            Text("↑↓ to move, Return to open, Esc to close").font(.caption).foregroundStyle(.secondary)
        }
        .padding(14)
        .frame(width: 440)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.regularMaterial))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(.separator))
        .shadow(color: .black.opacity(0.25), radius: 18, y: 8)
        .onAppear {
            entries = model.switcherEntries()
            installKeys()
        }
        .onDisappear { removeKeys() }
    }

    private func open(_ key: String) {
        KeyboardNavigation.shared.quickSwitcherShown = false
        model.openPicked(key)
    }

    // The keys work wherever the focus is (the field normally has it).
    private func installKeys() {
        removeKeys()
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { e in
            let code = e.keyCode
            let handled = MainActor.assumeIsolated { () -> Bool in
                guard KeyboardNavigation.shared.quickSwitcherShown else { return false }
                let list = results(filter.trimmingCharacters(in: .whitespaces))
                switch code {
                case 53: // Esc
                    KeyboardNavigation.shared.quickSwitcherShown = false
                    model.composerFocusRequest += 1
                case 125: index = min(index + 1, max(list.count - 1, 0))
                case 126: index = max(index - 1, 0)
                case 36, 76: if list.indices.contains(index) { open(list[index].key) }
                default: return false
                }
                return true
            }
            return handled ? nil : e
        }
    }

    private func removeKeys() {
        if let m = keyMonitor { NSEvent.removeMonitor(m) }
        keyMonitor = nil
    }
}

// MARK: - Chat list search

struct SidebarSectionHeader: View {
    let title: String

    var body: some View {
        Text(title)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.top, 6)
    }
}

/// A message found by the chat list search: chat, time and the text around the match.
struct MessageHitRow: View {
    @Environment(AppModel.self) private var model
    let hit: MessageSearchHit

    var body: some View {
        let c = model.chats.convs[hit.key]
        let who = hit.outgoing ? "You: " : (c?.isGroup == true && !hit.sender.isEmpty ? hit.sender + ": " : "")
        HStack(spacing: 10) {
            if model.appearance.showAvatars, let c { AvatarView(image: model.avatarImage(c), size: 32) }
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(c.map(model.title) ?? hit.key).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                    Spacer(minLength: 4)
                    Text(ChatListItem.shortTime(hit.time)).font(.caption2).foregroundStyle(.secondary)
                }
                Text(who + hit.snippet).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
        }
        .padding(.vertical, 4)
    }
}
