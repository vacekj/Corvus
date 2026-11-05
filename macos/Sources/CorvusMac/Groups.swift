import AppKit
import CorvusCore
import SwiftUI

/// Group management through signal-cli (`listGroups`, `updateGroup`, `quitGroup`). The parsing and the
/// parameter shapes live in CorvusCore (Groups.swift); the Qt app does the same in src/GroupDialog.cpp.
extension AppModel {
    /// Name of a person for member lists: "You", the contact name, or the number.
    func memberName(_ id: String) -> String {
        let key = chats.resolveKey(id)
        if !account.isEmpty && (id == account || key == account) { return "You" }
        if let c = chats.convs[key], !c.isGroup, c.title != key { return c.title }
        if let name = chats.contactNames[key] ?? chats.contactNames[id] { return name }
        if let c = roster.contact(id) ?? roster.contact(key), c.title != c.key { return c.title }
        return id
    }

    func isSelf(_ id: String) -> Bool { !account.isEmpty && (id == account || chats.resolveKey(id) == account) }

    /// Reloads one group (detailed) and updates the chat title.
    func refreshGroup(_ id: String) async {
        guard let res = try? await cli.call("listGroups", ["groupId": [id]]),
              let g = GroupInfo.parseList(res).first(where: { $0.id == id }) else { return }
        roster.set(group: g)
        if chats.convs[g.key] != nil {
            if !g.name.isEmpty { chats.convs[g.key]!.title = g.name }
            chats.convs[g.key]!.expirationSeconds = g.expiration
        }
        listChanged()
    }

    /// One `updateGroup` call for the group `id`; returns the error text, nil on success.
    func updateGroup(_ id: String, _ changes: JSON) async -> String? {
        guard !changes.isEmpty else { return nil }
        do { try await cli.call("updateGroup", GroupParams.update(groupId: id, changes)) } catch {
            return error.localizedDescription
        }
        await refreshGroup(id)
        return nil
    }

    /// Creates a group (`updateGroup` without `groupId`) and opens it; returns the error text, nil on success.
    func createGroup(name: String, description: String, members: [String]) async -> String? {
        let res: Any
        do { res = try await cli.call("updateGroup", GroupParams.create(name: name, description: description, members: members)) } catch {
            return error.localizedDescription
        }
        let id = jsonString(jsonObject(res)["groupId"])
        if id.isEmpty { return "signal-cli did not report the id of the new group." }
        let key = GroupInfo.key(forId: id)
        chats.ensure(key, title: name, group: true)
        chats.convs[key]!.title = name
        roster.accept(key) // a group we created is not a request
        roster.save()
        await refreshGroup(id)
        showArchived = false
        openConversation(key)
        showFlash("Group created.", seconds: 4)
        return nil
    }

    /// Leaves the group (`quitGroup`). The only admin has to name a successor first.
    func leaveGroup(_ key: String) async {
        guard key.hasPrefix("g:"), let c = chats.convs[key] else { return }
        let id = String(key.dropFirst(2))
        guard await Dialogs.confirm("Leave group", "Leave “\(c.title)”? You will stop receiving its messages.",
                                    ok: "Leave", destructive: true) else { return }
        var successor: String?
        if let g = roster.groups[key], g.needsSuccessor(leaving: account) {
            let candidates = g.successors(leaving: account)
            guard let i = await Dialogs.choose("Choose a new admin", "You are the only admin. Who should take over?",
                                               options: candidates.map { memberName($0.id) }) else { return }
            successor = candidates[i].id
        }
        do { try await cli.call("quitGroup", GroupParams.quit(groupId: id, successor: successor)) } catch {
            showFlash("Could not leave the group: \(error.localizedDescription)", seconds: 8)
            return
        }
        await refreshGroup(id)
        if var g = roster.groups[key], g.isMember { // signal-cli did not report the change yet
            g.isMember = false
            roster.set(group: g)
        }
        showFlash("You left the group.", seconds: 4)
    }

    func showGroupInfo(_ key: String) {
        guard chats.convs[key]?.isGroup == true else { return }
        openConversation(key)
        groupInfoKey = key
    }
}
