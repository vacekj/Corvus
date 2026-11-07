import AppKit
import CorvusCore
import SwiftUI

/// Group management through signal-cli (`listGroups`, `updateGroup`, `quitGroup`). The parsing and the
/// parameter shapes live in CorvusCore (Groups.swift); the Qt app does the same in src/GroupDialog.cpp.
extension AppModel {
    /// Name of a person for member lists: "You", the contact name, the number, or "Unknown" (never a UUID).
    func memberName(_ id: String) -> String {
        let key = chats.resolveKey(id)
        if !account.isEmpty && (id == account || key == account) { return "You" }
        var names: [String] = []
        if let c = chats.convs[key], !c.isGroup, c.title != key { names.append(c.title) }
        if let name = chats.contactNames[key] ?? chats.contactNames[id] { names.append(name) }
        if let c = roster.contact(id) ?? roster.contact(key), c.title != c.key { names.append(c.title) }
        return People.displayName(names: names, number: People.isPhoneNumber(key) ? key : id)
    }

    /// A group member as a picker/list row: name, number (if not the name), avatar.
    func memberPerson(_ m: GroupMember) -> PickerPerson {
        let key = chats.resolveKey(m.id)
        let name = memberName(m.id)
        let number = !m.number.isEmpty ? m.number : (People.isPhoneNumber(key) ? key : "")
        let avatar = avatars[key] ?? chats.convs[key].map(avatarImage) ?? Media.placeholderAvatar(key: key, title: name)
        return PickerPerson(key: key, title: name, detail: isSelf(m.id) ? "" : People.detail(title: name, address: number),
                            avatar: avatar, lastTs: 0)
    }

    func isSelf(_ id: String) -> Bool { !account.isEmpty && (id == account || chats.resolveKey(id) == account) }

    /// Reloads one group (detailed) and updates the chat title.
    func refreshGroup(_ id: String) async {
        guard let res = try? await cli.call("listGroups", ["groupId": [id]]),
              let g = GroupInfo.parseList(res).first(where: { $0.id == id }) else { return }
        // Only real changes: this runs whenever a group's info is shown (every time a group chat opens),
        // and a write to `roster` or `chats` makes the whole chat list update.
        var changed = false
        if roster.groups[g.key] != g || roster.blocked.contains(g.key) != g.isBlocked { roster.set(group: g); changed = true }
        if let c = chats.convs[g.key] {
            if !g.name.isEmpty && c.title != g.name { chats.convs[g.key]!.title = g.name; changed = true }
            if c.expirationSeconds != g.expiration { chats.convs[g.key]!.expirationSeconds = g.expiration; changed = true }
        }
        if changed { listChanged() }
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
            guard let s = await chooseSuccessor(key, g.successors(leaving: account)) else { return }
            successor = s
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

    /// Shows the sheet listing `candidates` and waits for the pick (nil: cancelled).
    func chooseSuccessor(_ key: String, _ candidates: [GroupMember]) async -> String? {
        finishSuccessorPick(nil)
        return await withCheckedContinuation { cont in
            successorContinuation = cont
            successorPick = SuccessorPick(key: key, candidates: candidates)
        }
    }

    func finishSuccessorPick(_ id: String?) {
        successorPick = nil
        let cont = successorContinuation
        successorContinuation = nil
        cont?.resume(returning: id)
    }

    func showGroupInfo(_ key: String) {
        guard chats.convs[key]?.isGroup == true else { return }
        openConversation(key)
        infoPanelShown = true
    }

    /// ⌘I and a click on the chat header.
    func toggleInfoPanel() {
        guard current != nil else { return }
        infoPanelShown.toggle()
    }
}

/// The group being left and who could become its admin.
struct SuccessorPick: Identifiable {
    let key: String
    let candidates: [GroupMember]
    var id: String { key }
}
