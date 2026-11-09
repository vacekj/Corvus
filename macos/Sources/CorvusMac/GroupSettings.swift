import AppKit
import CorvusCore
import SwiftUI

/// UI state of the group, profile and sticker-pack features that is not part of AppModel (kept separate so
/// views reading it do not depend on the whole model).
@MainActor
@Observable
final class GroupExtras {
    static let shared = GroupExtras()

    /// Confirmation sheet for joining a group by link (nil: hidden). An empty link asks for one.
    var joinRequest: JoinRequest?
    var stickerCreatorShown = false
    /// Member labels by group key, then by member number and UUID. Only groups with a label are listed.
    private(set) var memberLabels: [String: [String: String]] = [:]

    func setLabels(_ key: String, _ labels: [String: String]) {
        if labels.isEmpty {
            if memberLabels[key] != nil { memberLabels.removeValue(forKey: key) }
        } else if memberLabels[key] != labels {
            memberLabels[key] = labels
        }
    }
}

struct JoinRequest: Identifiable {
    let id = UUID()
    var link: GroupInviteLink?
}

/// Avatar, permissions, invite link, member labels and joining by link (`updateGroup`, `joinGroup`).
extension AppModel {
    /// Keeps the member-label index in step with the roster (called after every group update).
    func syncMemberLabels(_ keys: [String]? = nil) {
        let extras = GroupExtras.shared
        let all = keys == nil ? Set(extras.memberLabels.keys).union(roster.groups.keys) : []
        for key in keys ?? Array(all) {
            extras.setLabels(key, roster.groups[key]?.memberLabels ?? [:])
        }
    }

    /// Applies `change` to the cached group at once and sends `params`; on failure the change is undone.
    /// Returns the error text, nil on success.
    func updateGroupOptimistically(_ key: String, _ params: JSON, change: (inout GroupInfo) -> Void) async -> String? {
        guard !params.isEmpty, let before = roster.groups[key] else { return nil }
        var after = before
        change(&after)
        if after != before {
            roster.set(group: after)
            syncMemberLabels([key])
        }
        if let err = await updateGroup(String(key.dropFirst(2)), params) {
            if roster.groups[key] == after { roster.set(group: before) }
            syncMemberLabels([key])
            return err
        }
        return nil
    }

    // MARK: Avatar

    /// Sets the group picture; it shows right away and goes back if signal-cli refuses it.
    func setGroupAvatar(_ key: String, file: URL) async -> String? {
        let previous = avatars[key]
        if let img = NSImage(contentsOf: file) { avatars[key] = Media.roundAvatar(img) }
        let staged = Media.stageForSignalCli([file.path])
        defer { try? FileManager.default.removeItem(at: staged.dir) }
        if let err = await updateGroup(String(key.dropFirst(2)), GroupParams.avatar(staged.paths[0])) {
            avatars[key] = previous
            return err
        }
        return nil
    }

    // MARK: Permissions

    func setGroupPermission(_ key: String, _ kind: GroupPermissionKind, _ value: GroupPermission) async -> String? {
        guard let g = roster.groups[key] else { return nil }
        return await updateGroupOptimistically(key, GroupParams.permission(kind, value, in: g)) { kind.set(value, in: &$0) }
    }

    // MARK: Invite link

    private func approvalKey(_ key: String) -> String { "groupLinkApproval.\(account).\(key)" }

    /// Whether joining by link needs an admin's approval. signal-cli does not report it, so this is what was
    /// last set from Corvus; pending join requests prove it is on.
    func linkNeedsApproval(_ g: GroupInfo) -> Bool {
        !g.requesting.isEmpty || UserDefaults.standard.bool(forKey: approvalKey(g.key))
    }

    func setGroupLink(_ key: String, _ state: GroupLinkState) async -> String? {
        let err = await updateGroup(String(key.dropFirst(2)), GroupParams.link(state))
        if err == nil, state != .disabled {
            UserDefaults.standard.set(state == .enabledWithApproval, forKey: approvalKey(key))
        }
        return err
    }

    // MARK: Member label

    func setOwnMemberLabel(_ key: String, text: String, emoji: String) async -> String? {
        let params = GroupParams.memberLabel(text, emoji: emoji)
        let me = account
        return await updateGroupOptimistically(key, params) { g in
            for i in g.members.indices where g.members[i].matches(me) || isSelf(g.members[i].id) {
                g.members[i].label = jsonString(params["memberLabel"])
                g.members[i].labelEmoji = jsonString(params["memberLabelEmoji"])
            }
        }
    }

    // MARK: Joining by link

    /// A click on a signal.group link (or the menu command with `nil`): shows the join confirmation.
    func askToJoinGroup(_ link: GroupInviteLink?) {
        GroupExtras.shared.joinRequest = JoinRequest(link: link)
    }

    /// `joinGroup`: opens the group, or reports that an admin has to approve. Returns the error text.
    func joinGroup(_ link: GroupInviteLink) async -> String? {
        let result: GroupJoinResult
        do { result = GroupJoinResult(json: try await cli.call("joinGroup", GroupParams.join(link))) } catch {
            return error.localizedDescription
        }
        if result.onlyRequested {
            showFlash("Request sent. You will join once a group admin approves it.", seconds: 6)
            return nil
        }
        guard !result.groupId.isEmpty else {
            showFlash("Joined the group.", seconds: 4)
            return nil
        }
        let key = GroupInfo.key(forId: result.groupId)
        chats.ensure(key, title: "Group", group: true)
        roster.accept(key) // joining is accepting
        roster.save()
        await refreshGroup(result.groupId)
        showArchived = false
        openConversation(key)
        showFlash("You joined the group.", seconds: 4)
        return nil
    }
}
