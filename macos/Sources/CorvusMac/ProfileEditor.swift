import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins
import CorvusCore
import SwiftUI

/// Own profile and username through signal-cli: `listContacts` (our entry) to read, `updateProfile` and
/// `updateAccount --username/--delete-username` to change.
extension AppModel {
    func loadOwnProfile() async throws -> OwnProfile? {
        OwnProfile.find(in: try await cli.call("listContacts", ["recipients": [account]]), account: account)
    }

    func updateOwnProfile(_ params: JSON) async -> String? {
        guard !params.isEmpty else { return nil }
        do { try await cli.call("updateProfile", params) } catch { return error.localizedDescription }
        return nil
    }

    /// Sets the username (signal-cli adds a free discriminator when there is none) and remembers its link.
    func setUsername(_ name: String) async -> Result<UsernameResult, Error> {
        do {
            let r = UsernameResult(json: try await cli.call("updateAccount", Username.set(name)))
            if !r.username.isEmpty { UsernameLinkStore.save(r, account: account) }
            return .success(r)
        } catch {
            return .failure(error)
        }
    }

    func deleteUsername() async -> String? {
        do { try await cli.call("updateAccount", Username.delete) } catch { return error.localizedDescription }
        UsernameLinkStore.clear(account: account)
        return nil
    }
}

/// signal-cli reports the username link only when the username is set, so the last one is kept per account.
enum UsernameLinkStore {
    private static func key(_ account: String) -> String { "usernameLink.\(account)" }

    static func save(_ r: UsernameResult, account: String) {
        guard !r.link.isEmpty else { return }
        UserDefaults.standard.set(["username": r.username, "link": r.link], forKey: key(account))
    }

    /// The saved link, if it belongs to `username`.
    static func link(for username: String, account: String) -> String? {
        guard !username.isEmpty, let d = UserDefaults.standard.dictionary(forKey: key(account)),
              d["username"] as? String == username, let link = d["link"] as? String, !link.isEmpty else { return nil }
        return link
    }

    static func clear(account: String) { UserDefaults.standard.removeObject(forKey: key(account)) }
}

/// The Profile tab of the settings: photo, name, about, username (with its link and QR code).
struct ProfileEditor: View {
    @Environment(AppModel.self) private var model
    @State private var saved = OwnProfile()
    @State private var loaded = false
    @State private var loadError: String?
    @State private var given = ""
    @State private var family = ""
    @State private var about = ""
    @State private var aboutEmoji = ""
    @State private var emojiShown = false
    @State private var avatar: NSImage?
    @State private var busy = false
    @State private var status: (text: String, error: Bool)?
    @State private var usernameText = ""
    @State private var usernameBusy = false
    @State private var usernameError: String?
    @State private var usernameLink: String?

    var body: some View {
        Form {
            if !model.connected {
                Text("Connect to signal-cli before editing your profile.").foregroundStyle(.secondary)
            } else if let loadError {
                InlineError(text: "Could not read your profile: \(loadError)")
            }
            Section { header }
            Section("Name") {
                TextField("First name", text: $given, prompt: Text("Required"))
                TextField("Last name", text: $family, prompt: Text("Optional"))
            }
            Section("About") {
                HStack(spacing: 8) {
                    Button { emojiShown = true } label: {
                        Group {
                            if aboutEmoji.isEmpty { Image(systemName: "face.smiling") } else { Text(aboutEmoji) }
                        }
                        .frame(width: 20)
                    }
                    .help("Choose an emoji")
                    .popover(isPresented: $emojiShown) {
                        VStack(alignment: .trailing, spacing: 6) {
                            EmojiPicker { e in
                                aboutEmoji = e
                                emojiShown = false
                            }
                            if !aboutEmoji.isEmpty {
                                Button("No emoji") {
                                    aboutEmoji = ""
                                    emojiShown = false
                                }
                                .buttonStyle(.borderless)
                            }
                        }
                        .padding(8)
                        .frame(width: 340)
                    }
                    TextField("About", text: $about, prompt: Text("Write a few words about yourself"))
                        .labelsHidden()
                }
            }
            HStack {
                if let status { Text(status.text).foregroundStyle(status.error ? .red : .secondary).font(.callout) }
                Spacer()
                if busy { ProgressView().controlSize(.small) }
                Button("Revert") { fill(from: saved) }.disabled(!dirty || busy)
                Button("Save", action: saveProfile)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!dirty || busy || given.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            usernameSection
        }
        .formStyle(.grouped)
        .disabled(!model.connected || !loaded)
        .task(id: model.connected) { await load() }
    }

    private var dirty: Bool {
        !ProfileParams.update(from: saved, givenName: given, familyName: family, about: about, aboutEmoji: aboutEmoji).isEmpty
    }

    private var header: some View {
        HStack(spacing: 14) {
            Group {
                if let avatar {
                    Image(nsImage: avatar).resizable().interpolation(.high)
                } else {
                    Image(systemName: "person.crop.circle.fill").resizable().foregroundStyle(.secondary)
                }
            }
            .frame(width: 64, height: 64)
            .clipShape(Circle())
            VStack(alignment: .leading, spacing: 3) {
                Text(saved.name.isEmpty ? "No profile name" : saved.name).font(.title3.weight(.semibold))
                if !saved.aboutLine.isEmpty { Text(saved.aboutLine).foregroundStyle(.secondary).lineLimit(2) }
                if !saved.username.isEmpty { Text(saved.username).foregroundStyle(.secondary).textSelection(.enabled) }
                HStack(spacing: 12) {
                    Button("Choose photo …", action: chooseAvatar)
                    if avatar != nil {
                        Button("Remove photo", role: .destructive, action: removeAvatar)
                    }
                }
                .buttonStyle(.borderless)
                .padding(.top, 2)
            }
        }
    }

    @ViewBuilder
    private var usernameSection: some View {
        Section("Username") {
            if !saved.username.isEmpty {
                LabeledContent("Username") {
                    HStack {
                        Text(saved.username).textSelection(.enabled)
                        Button { copy(saved.username, "Username copied.") } label: { Image(systemName: "doc.on.doc") }
                            .buttonStyle(.borderless)
                            .help("Copy username")
                    }
                }
            }
            HStack {
                TextField(saved.username.isEmpty ? "Username" : "New username", text: $usernameText,
                          prompt: Text("name or name.42"))
                    .onSubmit(setUsername)
                    .onChange(of: usernameText) { usernameError = nil }
                if usernameBusy { ProgressView().controlSize(.small) }
                Button(saved.username.isEmpty ? "Set" : "Change", action: setUsername)
                    .disabled(usernameBusy || Username.problem(usernameText) != nil)
            }
            if !usernameText.isEmpty, let p = Username.problem(usernameText) {
                Text(p).font(.caption).foregroundStyle(.secondary)
            }
            if let usernameError { InlineError(text: usernameError) }
            if let usernameLink {
                LabeledContent("Link") {
                    HStack {
                        Text(usernameLink).font(.caption.monospaced()).lineLimit(1).truncationMode(.middle)
                            .textSelection(.enabled)
                        Button { copy(usernameLink, "Username link copied.") } label: { Image(systemName: "doc.on.doc") }
                            .buttonStyle(.borderless)
                            .help("Copy link")
                    }
                }
                if let qr = QRCode.image(usernameLink) {
                    HStack {
                        Spacer()
                        Image(nsImage: qr).interpolation(.none).resizable().frame(width: 160, height: 160)
                            .padding(10)
                            .background(RoundedRectangle(cornerRadius: 12).fill(.white))
                        Spacer()
                    }
                }
            }
            if !saved.username.isEmpty {
                Button("Delete username …", role: .destructive, action: deleteUsername)
                    .disabled(usernameBusy)
            }
        }
    }

    // MARK: Loading

    private func load() async {
        guard model.connected else { return }
        do {
            if let p = try await model.loadOwnProfile() {
                saved = p
                fill(from: p)
                usernameLink = UsernameLinkStore.link(for: p.username, account: model.account)
            }
            loadError = nil
        } catch {
            loadError = error.localizedDescription
        }
        loaded = true
        avatar = await model.ownAvatar()
    }

    private func fill(from p: OwnProfile) {
        given = p.givenName
        family = p.familyName
        about = p.about
        aboutEmoji = p.aboutEmoji
    }

    // MARK: Saving

    /// The profile shows the change at once and goes back if signal-cli refuses it.
    private func saveProfile() {
        let params = ProfileParams.update(from: saved, givenName: given, familyName: family, about: about, aboutEmoji: aboutEmoji)
        guard !params.isEmpty else { return }
        let before = saved
        ProfileParams.apply(params, to: &saved)
        busy = true
        status = nil
        Task {
            let e = await model.updateOwnProfile(params)
            busy = false
            if let e {
                saved = before
                status = ("Could not save your profile: \(e)", true)
            } else {
                status = ("Saved.", false)
            }
        }
    }

    private func chooseAvatar() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png, .jpeg, .gif, .webP, .heic]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let before = avatar
        if let img = NSImage(contentsOf: url) { avatar = Media.roundAvatar(img, size: 128) }
        let staged = Media.stageForSignalCli([url.path])
        busy = true
        status = nil
        Task {
            let e = await model.updateOwnProfile(ProfileParams.avatar(staged.paths[0]))
            try? FileManager.default.removeItem(at: staged.dir)
            busy = false
            if let e {
                avatar = before
                status = ("Could not change your photo: \(e)", true)
            }
        }
    }

    private func removeAvatar() {
        let before = avatar
        avatar = nil
        busy = true
        status = nil
        Task {
            let e = await model.updateOwnProfile(ProfileParams.removeAvatar)
            busy = false
            if let e {
                avatar = before
                status = ("Could not remove your photo: \(e)", true)
            }
        }
    }

    private func setUsername() {
        let name = usernameText.trimmingCharacters(in: .whitespaces)
        guard Username.problem(name) == nil else { return }
        usernameBusy = true
        usernameError = nil
        Task {
            let r = await model.setUsername(name)
            usernameBusy = false
            switch r {
            case .success(let u):
                if !u.username.isEmpty { saved.username = u.username }
                usernameLink = u.link.isEmpty ? nil : u.link
                usernameText = ""
            case .failure(let e):
                usernameError = "Could not set the username: \(e.localizedDescription)"
            }
        }
    }

    private func deleteUsername() {
        Task {
            guard await Dialogs.confirm("Delete username?",
                                        "People will no longer be able to find you by “\(saved.username)”. Your username link and QR code will stop working.",
                                        ok: "Delete", destructive: true) else { return }
            usernameBusy = true
            usernameError = nil
            let e = await model.deleteUsername()
            usernameBusy = false
            if let e {
                usernameError = "Could not delete the username: \(e)"
            } else {
                saved.username = ""
                usernameLink = nil
            }
        }
    }

    private func copy(_ text: String, _ flash: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        model.showFlash(flash, seconds: 3)
    }
}

/// QR codes drawn with Core Image (black on white, crisp when scaled).
enum QRCode {
    static func image(_ text: String, scale: CGFloat = 8) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: scale, y: scale)) else { return nil }
        let rep = NSCIImageRep(ciImage: output)
        let image = NSImage(size: rep.size)
        image.addRepresentation(rep)
        return image
    }
}
