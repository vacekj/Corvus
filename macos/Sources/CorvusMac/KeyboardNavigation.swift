import AppKit
import CorvusCore
import SwiftUI

/// Keyboard navigation state of the main window: the ⌘K switcher and the chat list search field.
/// Kept out of `AppModel` so opening the switcher never touches views that read the model.
@MainActor @Observable
final class KeyboardNavigation {
    static let shared = KeyboardNavigation()

    var quickSwitcherShown = false
    var switcherNewChat = false     // the switcher was opened as "New conversation": people, and any number / username

    /// Opens the switcher (⌘K, or ⌘N for a new conversation).
    func showSwitcher(newChat: Bool) {
        switcherNewChat = newChat
        quickSwitcherShown = true
    }
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
            list.append(PickerPerson(key: c.key, title: title(c), detail: "Group", avatar: avatarImage(c), lastTs: c.msgs.last?.ts ?? 0,
                                     activity: PickerRanking.activity(c.msgs.reversed().lazy.map(\.ts), now: nowMs())))
        }
        if !account.isEmpty, let me = chats.convs[account] {
            list.append(PickerPerson(key: me.key, title: title(me), detail: "", avatar: avatarImage(me), lastTs: me.msgs.last?.ts ?? 0,
                                     activity: PickerRanking.activity(me.msgs.reversed().lazy.map(\.ts), now: nowMs())))
        }
        return list.sorted(by: PickerPerson.busierFirst)
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
    private let newChat = KeyboardNavigation.shared.switcherNewChat

    private static let limit = 60

    /// What was typed, if it can be an address: "+420 123 …" or "name.12".
    static func address(_ q: String) -> String? {
        let compact = q.filter { !" -()".contains($0) }
        if compact.hasPrefix("+"), compact.count >= 8, compact.dropFirst().allSatisfy(\.isNumber) { return compact }
        if !q.contains(" "), let dot = q.lastIndex(of: "."), q[q.index(after: dot)...].count >= 2,
           q[q.index(after: dot)...].allSatisfy(\.isNumber), q.distance(from: q.startIndex, to: dot) >= 3 { return q }
        return nil
    }

    private func results(_ q: String) -> [PickerPerson] {
        var list = matches(q)
        if newChat, let a = Self.address(q), !entries.contains(where: { $0.key == a }) {
            list.insert(PickerPerson(key: a, title: "Message \(a)", detail: "New conversation",
                                     avatar: Media.placeholderAvatar(key: a, title: "+"), lastTs: 0), at: 0)
        }
        return list
    }

    private func matches(_ q: String) -> [PickerPerson] {
        if q.isEmpty { return Array(entries.prefix(Self.limit)) }
        let digits = q.filter(\.isNumber)
        // Match quality only coarsely (a name or word starting with the query beats one containing it, which
        // beats a scattered match), then who the user writes with most: "domi" finds the Dominik you talk to.
        let scored = entries.compactMap { p -> (p: PickerPerson, tier: Int, score: Int)? in
            var best = FuzzyMatch.score(q, p.title)
            var tier = best == nil ? -1 : PickerRanking.tier(q, p.title)
            if p.detail != "Group", let d = FuzzyMatch.score(q, p.detail) {
                best = max(best ?? d, d - 100)
                tier = max(tier, PickerRanking.tier(q, p.detail))
            }
            if best == nil, digits.count >= 3, p.key.filter(\.isNumber).contains(digits) { best = 1; tier = 1 }
            return best.map { (p, tier, $0) }
        }
        return scored.sorted { a, b in
            if a.tier != b.tier { return a.tier > b.tier }
            if a.p.activity != b.p.activity { return a.p.activity > b.p.activity }
            if a.p.lastTs != b.p.lastTs { return a.p.lastTs > b.p.lastTs }
            return a.score > b.score
        }.prefix(Self.limit).map(\.p)
    }

    var body: some View {
        let list = results(filter.trimmingCharacters(in: .whitespaces))
        VStack(alignment: .leading, spacing: 8) {
            if newChat { Text("New conversation").font(.headline) }
            SearchField(text: $filter, prompt: newChat ? "Name, phone number (+…) or username" : "Go to conversation")
                .onChange(of: filter) { index = 0 }
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(list.enumerated()), id: \.element.key) { i, p in
                            PickerRow(person: p, highlighted: i == index)
                                .id(p.key)
                                // Opens on mouse down, like the chat list.
                                .gesture(DragGesture(minimumDistance: 0).onChanged { _ in open(p.key) })
                        }
                    }
                }
                .onChange(of: index) { if list.indices.contains(index) { proxy.scrollTo(list[index].key) } }
            }
            .frame(height: 320)
            .overlay {
                if list.isEmpty {
                    Text(filter.isEmpty ? "No chats yet"
                         : newChat ? "No one matches “\(filter)”.\nType a phone number with + and country code, or a username like name.12."
                         : "No chats match “\(filter)”")
                        .multilineTextAlignment(.center).foregroundStyle(.secondary).padding()
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
            entries = newChat ? model.pickerPeople() : model.switcherEntries()
            installKeys()
        }
        .onDisappear { removeKeys() }
    }

    private func open(_ key: String) {
        guard KeyboardNavigation.shared.quickSwitcherShown else { return }
        KeyboardNavigation.shared.quickSwitcherShown = false
        model.openPicked(key)
    }

    // The keys work wherever the focus is (the field normally has it).
    private func installKeys() {
        removeKeys()
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { e in
            let code = e.keyCode
            let typed = e.modifierFlags.intersection([.command, .control, .option]).isEmpty ? (e.characters ?? "") : ""
            let handled = MainActor.assumeIsolated { () -> Bool in
                guard KeyboardNavigation.shared.quickSwitcherShown else { return false }
                // Typing goes into the search even if the field did not get the caret.
                let fieldFocused = (NSApp.keyWindow?.firstResponder as? NSTextView)?.isFieldEditor == true
                if !fieldFocused, !typed.isEmpty, typed.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }),
                   ![53, 125, 126, 36, 76].contains(code) {
                    filter += typed
                    return true
                }
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
