import AppKit
import CorvusCore
import SwiftUI

/// Message requests and blocking. The rules live in CorvusCore.Roster; this file talks to signal-cli
/// (`sendMessageRequestResponse`, `block`, `unblock`, `removeContact`) and keeps the state in sync.
extension AppModel {
    // MARK: - State

    private var resolver: (String) -> String { { [alias = chats.alias] in alias[$0] ?? $0 } }

    func isMessageRequest(_ key: String) -> Bool {
        guard let c = chats.convs[key] else { return false }
        return roster.isRequest(c, resolve: resolver)
    }

    func isBlocked(_ key: String) -> Bool { roster.isBlocked(key, resolve: resolver) }

    /// True for a request, a blocked chat and a group we left: the composer is disabled.
    func isSendLocked(_ key: String) -> Bool {
        guard let c = chats.convs[key] else { return false }
        return roster.isSendLocked(c, resolve: resolver)
    }

    /// The composer of the open chat accepts input.
    var canCompose: Bool { current.map { !isSendLocked($0) } ?? true }

    /// No notification, sound, unread counter or dock bounce for requests and blocked senders.
    func isQuiet(_ key: String, author: String = "") -> Bool {
        guard let c = chats.convs[key] else { return false }
        return roster.isQuiet(c, author: author, resolve: resolver)
    }

    /// Read receipts and typing indicators must only be sent when this is true (not before a request is
    /// accepted, never to blocked people).
    func mayAcknowledge(_ key: String) -> Bool {
        guard let c = chats.convs[key] else { return true }
        return roster.mayAcknowledge(c, resolve: resolver)
    }

    var requestCount: Int { chats.convs.values.filter { roster.isRequest($0, resolve: resolver) }.count }

    // MARK: - Loading (called from loadContactsAndGroups)

    func noteContacts(_ result: Any) {
        roster.update(contacts: result)
        roster.baselineContacts(existing: Array(chats.convs.keys), resolve: resolver)
        roster.save()
    }

    /// Invitations are shown as chats (message requests) even though signal-cli says we are not members yet.
    func noteGroups(_ result: Any) {
        roster.update(groups: result)
        roster.baselineGroups()
        roster.save()
        for g in roster.groups.values where g.isInvitation(for: account) {
            chats.ensure(g.key, title: g.name.isEmpty ? "Group" : g.name, group: true)
            if !g.name.isEmpty { chats.convs[g.key]!.title = g.name }
        }
    }

    // MARK: - Accept

    func acceptRequest(_ key: String) {
        guard let c = chats.convs[key] else { return }
        Task {
            var warning: String?
            if c.isGroup {
                // An invitation is accepted by updating the group (signal-cli joins it).
                if roster.groups[key]?.isInvitation(for: account) == true {
                    do { try await cli.call("updateGroup", ["groupId": String(key.dropFirst(2))]) } catch {
                        showFlash("Could not accept the invitation: \(error.localizedDescription)")
                        return
                    }
                }
            } else if roster.contact(key)?.isHidden == true || roster.contact(chats.resolveKey(key))?.isHidden == true {
                // Hidden contacts are the phone's message requests: accepting clears the hidden state.
                _ = try? await cli.call("removeContact", ["recipient": chats.resolveKey(key)])
            }
            do { try await respond(.accept, key: key) } catch {
                warning = error.localizedDescription // still accepted here; only the phone was not told
            }
            roster.accept(key, resolve: resolver)
            roster.save()
            if c.isGroup { await refreshGroup(String(key.dropFirst(2))) }
            if let warning {
                showFlash("Accepted here, but your other devices were not told: \(warning)", seconds: 8)
            } else {
                showFlash("Message request accepted.", seconds: 4)
            }
            composerFocusRequest += 1
            listChanged()
        }
    }

    /// `sendMessageRequestResponse`. The type is lowercase in signal-cli 0.14; if a build only knows the
    /// enum names, the call is repeated in uppercase.
    @discardableResult
    func respond(_ type: MessageRequestResponse, key: String) async throws -> Any {
        var params = RequestParams.response(type, key: key.hasPrefix("g:") ? key : chats.resolveKey(key))
        do {
            return try await cli.call("sendMessageRequestResponse", params)
        } catch {
            let text = error.localizedDescription.lowercased()
            guard text.contains("type") || text.contains("convert") || text.contains("enum") else { throw error }
            params["type"] = type.rawValue.uppercased()
            return try await cli.call("sendMessageRequestResponse", params)
        }
    }

    // MARK: - Delete

    func deleteRequest(_ key: String) async {
        guard let c = chats.convs[key] else { return }
        let message = c.isGroup
            ? "Leave “\(c.title)” and delete the conversation? The group will not be able to add you again without a new invitation."
            : "Delete the message request from “\(c.title)” and its messages? They can still send you a new request."
        guard await Dialogs.confirm("Delete message request", message, ok: "Delete", destructive: true) else { return }
        if c.isGroup {
            let id = String(key.dropFirst(2))
            // Declines an invitation or leaves the group.
            if roster.groups[key]?.isMember == true || roster.groups[key]?.isInvitation(for: account) == true {
                do { try await cli.call("quitGroup", GroupParams.quit(groupId: id)) } catch {
                    showFlash("Could not leave the group: \(error.localizedDescription)")
                    return
                }
            }
        }
        do { try await respond(.delete, key: key) } catch {
            showFlash("Deleted here, but your other devices were not told: \(error.localizedDescription)", seconds: 8)
        }
        removeConversation(key)
        if c.isGroup { roster.groups.removeValue(forKey: key) }
    }

    // MARK: - Block

    func toggleBlocked(_ key: String) async {
        guard let c = chats.convs[key], key != account else { return }
        let block = !isBlocked(key)
        if block {
            let what = c.isGroup ? "You will no longer receive messages from this group." : "You will no longer receive messages or calls from this contact."
            guard await Dialogs.confirm("Block “\(c.title)”?", what, ok: "Block", destructive: true) else { return }
        }
        await setBlocked(key, block)
    }

    func setBlocked(_ key: String, _ block: Bool) async {
        guard chats.convs[key] != nil else { return }
        let target = key.hasPrefix("g:") ? key : chats.resolveKey(key)
        do {
            try await cli.call(block ? "block" : "unblock", RequestParams.block(key: target))
        } catch {
            showFlash("Could not \(block ? "block" : "unblock"): \(error.localizedDescription)", seconds: 8)
            return
        }
        roster.setBlocked(key, block, resolve: resolver)
        roster.save()
        if block, key == current { closeSearch() }
        showFlash(block ? "Blocked." : "Unblocked.", seconds: 4)
        listChanged()
    }
}

// MARK: - Views

/// Banner above the composer: message request (Accept / Delete / Block), blocked chat (Unblock) or a group
/// we left. Shows nothing for a normal chat.
struct RequestBanner: View {
    @Environment(AppModel.self) private var model
    let conversation: Conversation

    var body: some View {
        let key = conversation.key
        if model.isBlocked(key) {
            banner(icon: "nosign", title: "You blocked this \(conversation.isGroup ? "group" : "contact")",
                   text: "You will not receive messages from them. Unblock to chat again.") {
                Button("Unblock") { Task { await model.setBlocked(key, false) } }
                    .buttonStyle(.borderedProminent)
            }
        } else if model.isMessageRequest(key) {
            banner(icon: "envelope.badge",
                   title: conversation.isGroup ? "You were added to this group" : "Message request",
                   text: conversation.isGroup
                       ? "Accept to join the conversation. Until then nobody is told that you have seen it."
                       : "\(conversation.title) is not in your contacts. Accept to reply; until then they will not see that you read their messages.") {
                Button("Accept") { model.acceptRequest(key) }
                    .buttonStyle(.borderedProminent)
                Button("Delete", role: .destructive) { Task { await model.deleteRequest(key) } }
                Button("Block", role: .destructive) { Task { await model.toggleBlocked(key) } }
            }
        } else if conversation.isGroup, let g = model.roster.groups[key], !g.isMember {
            banner(icon: "person.fill.xmark", title: "You are no longer a member of this group", text: "") { EmptyView() }
        }
    }

    private func banner<Actions: View>(icon: String, title: String, text: String,
                                       @ViewBuilder actions: () -> Actions) -> some View {
        let label = HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon).font(.system(size: 20)).foregroundStyle(Theme.signalBlue)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.callout.weight(.semibold))
                if !text.isEmpty { Text(text).font(.caption).foregroundStyle(.secondary).lineLimit(4) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        let buttons = HStack(spacing: 8) { actions() }.controlSize(.regular).disabled(!model.connected).fixedSize()
        // Side by side when the pane is wide enough, otherwise the buttons go below the text.
        return ViewThatFits(in: .horizontal) {
            HStack(alignment: .center, spacing: 12) {
                label.frame(minWidth: 260)
                buttons
            }
            VStack(alignment: .trailing, spacing: 8) {
                label
                buttons
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Theme.chrome)
        .overlay(alignment: .top) { Divider() }
    }
}

/// Block / Unblock entry of the conversation menu.
struct BlockMenuItem: View {
    @Environment(AppModel.self) private var model
    let conversation: Conversation

    var body: some View {
        let c = conversation
        if c.key != model.account {
            let blocked = model.isBlocked(c.key)
            Button { Task { await model.toggleBlocked(c.key) } } label: {
                Label(blocked ? (c.isGroup ? "Unblock group" : "Unblock contact") : (c.isGroup ? "Block group …" : "Block contact …"),
                      systemImage: blocked ? "checkmark.circle" : "nosign")
            }
            .disabled(!model.connected)
        }
    }
}
