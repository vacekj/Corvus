import CorvusCore
import SwiftUI

/// Nickname and note of a contact, kept in Signal (`updateContact --nick-given-name/--nick-family-name/--note`)
/// so they sync with the other devices, as in Signal Desktop. The nickname also stays in the local history
/// (it is the chat title); signal-cli's values are read from `listContacts`.
extension AppModel {
    /// The recipient signal-cli knows the person by.
    private func contactRecipient(_ key: String) -> String { chats.resolveKey(key) }

    /// The contact entry for a chat key (number or UUID).
    func contactEntry(_ key: String) -> ContactEntry? {
        roster.contact(key) ?? roster.contact(chats.resolveKey(key))
    }

    /// Called by `setNickname`: a nickname changed elsewhere in the app (menu, older field) goes to Signal too,
    /// as the given name. Nothing is sent if Signal already has it.
    func syncNicknameToSignal(_ key: String, _ nickname: String) {
        guard connected, !key.hasPrefix("g:"), key != account else { return }
        if let c = contactEntry(key), c.nickname == nickname { return }
        Task { _ = await sendContactNickname(key, given: nickname, family: "") }
    }

    /// Saves the nickname here and in Signal; returns the error text (the local change stays either way).
    func saveContactNickname(_ key: String, given: String, family: String) async -> String? {
        let g = given.trimmingCharacters(in: .whitespacesAndNewlines)
        let f = family.trimmingCharacters(in: .whitespacesAndNewlines)
        let previous = contactEntry(key)
        roster.setContactDetails(contactRecipient(key), nickGivenName: g, nickFamilyName: f)
        applyLocalNickname(key, ContactParams.join(given: g, family: f))
        guard connected else { return "Not connected: the nickname is saved on this Mac only." }
        if let err = await sendContactNickname(key, given: g, family: f) {
            if let previous {
                roster.setContactDetails(contactRecipient(key), nickGivenName: previous.nickGivenName,
                                         nickFamilyName: previous.nickFamilyName)
            }
            return err
        }
        return nil
    }

    private func sendContactNickname(_ key: String, given: String, family: String) async -> String? {
        do {
            try await cli.call("updateContact", ContactParams.nickname(recipient: contactRecipient(key), given: given, family: family))
        } catch {
            return error.localizedDescription
        }
        roster.setContactDetails(contactRecipient(key), nickGivenName: given, nickFamilyName: family)
        return nil
    }

    /// Saves the note in Signal; on failure the previous note comes back. Returns the error text.
    func saveContactNote(_ key: String, _ note: String) async -> String? {
        let n = note.trimmingCharacters(in: .whitespacesAndNewlines)
        let previous = contactEntry(key)?.note
        roster.setContactDetails(contactRecipient(key), note: n)
        do {
            try await cli.call("updateContact", ContactParams.note(recipient: contactRecipient(key), note: n))
        } catch {
            if let previous { roster.setContactDetails(contactRecipient(key), note: previous) }
            return error.localizedDescription
        }
        return nil
    }

    /// The chat title and the history record of a nickname, without telling signal-cli.
    private func applyLocalNickname(_ key: String, _ nickname: String) {
        guard let c = chats.convs[key], !c.isGroup, c.localNickname != nickname else { return }
        chats.convs[key]!.localNickname = nickname
        chats.convs[key]!.title = nickname.isEmpty
            ? (chats.contactNames[key] ?? (c.storedName.isEmpty ? key : c.storedName)) : nickname
        persist(Records.nickname(key, nickname))
        listChanged()
    }

    /// After `listContacts`: a nickname set on another device replaces the local one (Signal is the source).
    /// The chat list is redrawn by the caller.
    func adoptSignalNicknames() {
        for c in roster.contacts where !c.nickname.isEmpty {
            for key in [c.number, c.uuid] where !key.isEmpty {
                guard let conv = chats.convs[key], !conv.isGroup, conv.localNickname != c.nickname else { continue }
                chats.convs[key]!.localNickname = c.nickname
                chats.convs[key]!.title = c.nickname
                persist(Records.nickname(key, c.nickname))
            }
        }
    }
}

/// Nickname (first and last name) and note of a contact in the info panel; each is saved when its field loses
/// focus or on Return.
struct ContactDetailsFields: View {
    @Environment(AppModel.self) private var model
    let conversation: Conversation
    @State private var given = ""
    @State private var family = ""
    @State private var note = ""
    @State private var loadedKey = ""
    @State private var error: String?
    @FocusState private var focus: Field?

    private enum Field { case given, family, note }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Nickname").font(.headline)
            HStack(spacing: 6) {
                TextField("First name", text: $given, prompt: Text("First name"))
                    .focused($focus, equals: .given)
                TextField("Last name", text: $family, prompt: Text("Last name"))
                    .focused($focus, equals: .family)
            }
            .textFieldStyle(.roundedBorder)
            .onSubmit(saveNickname)
            Text("Note").font(.headline).padding(.top, 4)
            TextField("Note", text: $note, prompt: Text("Add a note"), axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(1...6)
                .focused($focus, equals: .note)
                .onSubmit(saveNote)
            if let error { InlineError(text: error) }
        }
        .onChange(of: conversation.key, initial: true) { load() }
        .onChange(of: conversation.localNickname) { if focus == nil { load() } }
        .onChange(of: model.contactEntry(conversation.key)?.note) { if focus != .note { note = saved(loadedKey).note } }
        .onChange(of: focus) { old, new in
            if (old == .given || old == .family) && new != .given && new != .family { saveNickname() }
            if old == .note { saveNote() }
        }
        .onChange(of: model.nicknameFocusPending, initial: true) { focusIfRequested() }
        .disabled(!model.historyReady)
    }

    /// What is saved for `key`: Signal's values, else the local nickname as the first name.
    private func saved(_ key: String) -> (given: String, family: String, note: String) {
        let c = model.contactEntry(key)
        if let c, !c.nickname.isEmpty { return (c.nickGivenName, c.nickFamilyName, c.note) }
        return (model.chats.convs[key]?.localNickname ?? "", "", c?.note ?? "")
    }

    private func load() {
        if loadedKey != conversation.key && !loadedKey.isEmpty {
            // Another chat was opened while editing: save the old chat's fields first.
            saveNickname()
            saveNote()
            focus = nil
        }
        loadedKey = conversation.key
        error = nil
        (given, family, note) = saved(loadedKey)
    }

    private func saveNickname() {
        let key = loadedKey
        let g = given.trimmingCharacters(in: .whitespaces), f = family.trimmingCharacters(in: .whitespaces)
        let now = saved(key)
        guard !key.isEmpty, g != now.given || f != now.family else { return }
        error = nil
        Task { error = await model.saveContactNickname(key, given: g, family: f).map { "Could not save the nickname: \($0)" } }
    }

    private func saveNote() {
        let key = loadedKey
        let n = note.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty, n != saved(key).note else { return }
        guard model.connected else {
            error = "Connect to signal-cli to save the note."
            return
        }
        error = nil
        Task { error = await model.saveContactNote(key, n).map { "Could not save the note: \($0)" } }
    }

    private func focusIfRequested() {
        guard model.nicknameFocusPending else { return }
        model.nicknameFocusPending = false
        DispatchQueue.main.async { focus = .given }
    }
}
