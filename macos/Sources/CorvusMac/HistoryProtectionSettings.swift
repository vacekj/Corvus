import CorvusCore
import SwiftUI

/// Settings › General › Chat history: keychain or passphrase protection of the encrypted history,
/// with the passphrase fields shown inline and checked while typing.
struct HistoryProtectionSection: View {
    @Environment(AppModel.self) private var model

    private enum Mode: String { case keychain, passphrase }

    @State private var choice = Mode.keychain
    @State private var changingPassphrase = false
    @State private var current = ""
    @State private var new = ""
    @State private var repeated = ""
    @State private var busy = false
    @State private var error: String?
    @State private var done: String?
    @State private var confirmingPassphrase = false

    var body: some View {
        let active: Mode = model.historyProtectionMode == "keychain" ? .keychain : .passphrase
        Section("Chat history") {
            LabeledContent("File") {
                Text(AppPaths.historyPath).textSelection(.enabled).lineLimit(1).truncationMode(.middle)
            }
            Picker("Protection", selection: $choice) {
                Text("System keychain").tag(Mode.keychain)
                Text("Passphrase").tag(Mode.passphrase)
            }
            .pickerStyle(.radioGroup)
            .disabled(!model.historyReady || busy)
            .onChange(of: choice) { reset(); done = nil }

            if model.historyReady {
                if choice != active {
                    if choice == .keychain {
                        // Passphrase → keychain
                        SecureField("Current passphrase", text: $current).onSubmit(apply)
                        actionRow("Use system keychain", enabled: !current.isEmpty)
                    } else {
                        // Keychain → passphrase
                        newPassphraseFields
                        Text("If you forget the passphrase, your chat history cannot be recovered.")
                            .font(.caption).foregroundStyle(.secondary)
                        actionRow("Use passphrase", enabled: PassphrasePolicy.isAcceptable(new: new, repeated: repeated))
                    }
                } else if active == .passphrase {
                    if changingPassphrase {
                        SecureField("Current passphrase", text: $current)
                        newPassphraseFields
                        actionRow("Change passphrase",
                                  enabled: !current.isEmpty && PassphrasePolicy.isAcceptable(new: new, repeated: repeated),
                                  cancel: { changingPassphrase = false; reset() })
                    } else {
                        Button("Change passphrase …") { changingPassphrase = true; done = nil }
                    }
                }
                if let done { Text(done).foregroundStyle(.secondary) }
            }
        }
        .alert("Protect the chat history with a passphrase?", isPresented: $confirmingPassphrase) {
            Button("Use passphrase") { perform() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The key is removed from the keychain. If you forget the passphrase, the stored history cannot be recovered.")
        }
        .onAppear { choice = active }
        .onChange(of: model.historyProtectionMode) { choice = active }
    }

    @ViewBuilder private var newPassphraseFields: some View {
        SecureField(changingPassphrase ? "New passphrase" : "Passphrase", text: $new)
        SecureField("Repeat passphrase", text: $repeated).onSubmit(apply)
        if let p = PassphrasePolicy.problem(new: new, repeated: repeated), !p.isEmpty {
            Text(p).font(.caption).foregroundStyle(.red)
        }
    }

    private func actionRow(_ title: String, enabled: Bool, cancel: (() -> Void)? = nil) -> some View {
        HStack {
            if let error { Text(error).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true) }
            Spacer()
            if busy { ProgressView().controlSize(.small) }
            Button("Cancel") {
                if let cancel { cancel() } else { choice = model.historyProtectionMode == "keychain" ? .keychain : .passphrase }
            }
            .disabled(busy)
            Button(title, action: apply).disabled(!enabled || busy)
        }
    }

    private func reset() {
        current = ""
        new = ""
        repeated = ""
        error = nil
    }

    private func apply() {
        guard !busy else { return }
        let active: Mode = model.historyProtectionMode == "keychain" ? .keychain : .passphrase
        if choice == .passphrase && active == .keychain {
            // Leaving the keychain means the history depends on remembering the passphrase: confirm first.
            if PassphrasePolicy.isAcceptable(new: new, repeated: repeated) { confirmingPassphrase = true }
            return
        }
        perform()
    }

    private func perform() {
        guard !busy else { return }
        let active: Mode = model.historyProtectionMode == "keychain" ? .keychain : .passphrase
        let old = current, pw = new, rep = repeated
        Task {
            busy = true
            error = nil
            let result: String?
            let success: String
            switch (active, choice) {
            case (.passphrase, .keychain):
                result = await model.protectHistoryWithKeychain(currentPassphrase: old)
                success = "The history is now protected by the system keychain."
            case (.keychain, .passphrase):
                result = await model.protectHistoryWithPassphrase(pw, repeated: rep)
                success = "The history is now protected by your passphrase."
            default:
                result = await model.changeHistoryPassphrase(old: old, new: pw, repeated: rep)
                success = "The passphrase has been changed."
            }
            busy = false
            if let result {
                error = result
            } else {
                reset()
                changingPassphrase = false
                done = success
            }
        }
    }
}
