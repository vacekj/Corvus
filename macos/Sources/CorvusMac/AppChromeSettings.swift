import AppKit
import CorvusCore
import ServiceManagement
import SwiftUI

// MARK: - General: startup and updates

/// The sections this part of the app adds to Settings → General.
struct AppGeneralSections: View {
    var body: some View {
        Section("Startup") { LaunchAtLoginToggle() }
        AppUpdateSettingsSection()
    }
}

/// "Open Corvus at login" through the system's login items (SMAppService), like Signal Desktop's
/// "Open at computer login". The state is read from the system, which the user can change in System Settings.
private struct LaunchAtLoginToggle: View {
    @State private var status = SMAppService.mainApp.status
    @State private var error: String?

    /// Only an app bundle can be a login item (not `swift run`).
    private var available: Bool { Bundle.main.bundleURL.pathExtension == "app" }

    var body: some View {
        Toggle("Open Corvus at login", isOn: Binding(get: { status == .enabled || status == .requiresApproval }, set: set))
            .disabled(!available)
        if status == .requiresApproval {
            HStack {
                Text("Allow Corvus in System Settings → General → Login Items.").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Open Login Items") { SMAppService.openSystemSettingsLoginItems() }
            }
        }
        if let error { Text(error).font(.caption).foregroundStyle(.red) }
    }

    private func set(_ on: Bool) {
        error = nil
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            self.error = error.localizedDescription
        }
        status = SMAppService.mainApp.status
    }
}

// MARK: - Advanced: proxy and this device

/// The Signal TLS proxy signal-cli connects through (`--tls-proxy`), applied when signal-cli starts.
enum ProxySetting {
    static let key = "signalCli.tlsProxy"

    static var value: String {
        get { UserDefaults.standard.string(forKey: key) ?? "" }
        set {
            if newValue.isEmpty { UserDefaults.standard.removeObject(forKey: key) } else { UserDefaults.standard.set(newValue, forKey: key) }
        }
    }
}

struct AdvancedSettings: View {
    var body: some View {
        Form {
            ProxySection()
            DeviceDataSection()
        }
        .formStyle(.grouped)
    }
}

private struct ProxySection: View {
    @Environment(AppModel.self) private var model
    @State private var enabled = !ProxySetting.value.isEmpty
    @State private var address = ProxySetting.value
    @State private var saved = ProxySetting.value

    var body: some View {
        let normalized = enabled ? SignalProxy.normalize(address) : ""
        let target = normalized ?? ""
        Section("Proxy") {
            Toggle("Use a Signal proxy", isOn: $enabled)
            TextField("Proxy address", text: $address, prompt: Text("proxy.example.com or https://signal.tube/#…"))
                .disabled(!enabled)
                .onSubmit { if normalized != nil && target != saved { apply(target) } }
            if enabled && normalized == nil && !address.isEmpty {
                Text("Enter a host name, host:port or a signal.tube link.").font(.caption).foregroundStyle(.red)
            } else {
                Text("Signal TLS proxies only, the kind the Signal apps use. HTTP and SOCKS proxies are not supported by signal-cli.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Spacer()
                Button(model.historyReady ? "Save and reconnect" : "Save") { apply(target) }
                    .disabled(normalized == nil || (enabled && target.isEmpty) || target == saved)
            }
        }
    }

    private func apply(_ proxy: String) {
        ProxySetting.value = proxy
        saved = proxy
        if !proxy.isEmpty { address = proxy }
        model.cli.globalOptions = SignalProxy.arguments(proxy)
        if model.historyReady { model.reconnect() }
    }
}

private struct DeviceDataSection: View {
    @Environment(AppModel.self) private var model
    @State private var busy = false

    var body: some View {
        Section("This device") {
            LabeledContent("Unlink this device") {
                Button("How to unlink …") { Task { await model.explainUnlink() } }
            }
            LabeledContent("Delete all data") {
                Button("Delete all data …", role: .destructive) {
                    busy = true
                    Task {
                        await model.deleteAllLocalData()
                        busy = false
                    }
                }
                .disabled(busy)
            }
        }
    }
}

extension AppModel {
    private var signalAccount: String {
        chats.account.isEmpty ? (UserDefaults.standard.string(forKey: "account") ?? "") : chats.account
    }

    /// signal-cli cannot unlink a linked device: `removeDevice` is refused on anything but the primary device,
    /// and `unregister` would only stop this device from fetching messages (on a primary device it would
    /// unregister the number). Unlinking is done on the phone.
    func explainUnlink() async {
        let choice = await Dialogs.ask(
            "Unlink this device",
            "Linked devices are removed on your phone: open Signal → Settings → Linked devices and remove this computer.\n\n"
                + "Afterwards you can delete Corvus's data on this computer.",
            buttons: ["Delete all data …", "Close"])
        if choice == 0 { await deleteAllLocalData() }
    }

    /// Deletes signal-cli's data of this linked account (`deleteLocalAccountData --ignore-registered`) and Corvus's
    /// chat history, caches, history key and settings, then quits. Refused on a primary device: there it would
    /// throw away the account's identity while the number stays registered.
    func deleteAllLocalData() async {
        let account = signalAccount
        if !account.isEmpty {
            let deviceId = SignalCliAccountData.deviceId(dataDir: SignalCliAccountData.defaultDataDir(), account: account)
            if deviceId == SignalCliAccountData.primaryDeviceId {
                await Dialogs.warn("This computer is the primary device",
                                   "signal-cli registered the number on this computer. Deleting its data would cut you off from "
                                       + "your Signal account, so Corvus does not do it.")
                return
            }
            if deviceId == nil {
                await Dialogs.warn("Delete all data",
                                   "Corvus could not confirm that this computer is a linked device, so it does not delete the account data.")
                return
            }
        }
        guard await Dialogs.confirm(
            "Delete all data?",
            "This deletes all messages, the chat history, settings and the Signal account data of this computer. "
                + "Your phone and other linked devices keep their messages.\n\nCorvus quits afterwards. This cannot be undone.",
            ok: "Delete all data", destructive: true)
        else { return }
        guard let typed = await Dialogs.text("Type DELETE to confirm", "All data of Corvus and signal-cli on this computer will be deleted.",
                                             placeholder: "DELETE"),
              typed.trimmingCharacters(in: .whitespaces) == "DELETE"
        else { return }

        if !account.isEmpty {
            cli.stop()
            setConnected(false, info: "deleting data")
            let r = await cli.run(["-a", account, "deleteLocalAccountData", "--ignore-registered"], timeout: 120)
            guard r.ok else {
                let detail = [r.err, r.startError].first { !$0.isEmpty } ?? "exit code \(r.exitCode)"
                await Dialogs.error("The data could not be deleted", "signal-cli: \(SignalCli.maskNumbers(detail))\n\nNothing of Corvus was deleted.")
                reconnect()
                return
            }
        }

        shutdown() // closes the history and stops signal-cli
        let fm = FileManager.default
        let dir = AppPaths.dataDir
        for name in (try? fm.contentsOfDirectory(atPath: dir.path)) ?? [] where name != "history.lock" {
            try? fm.removeItem(at: dir.appendingPathComponent(name))
        }
        try? HistoryKeychain.clear()
        if let id = Bundle.main.bundleIdentifier { UserDefaults.standard.removePersistentDomain(forName: id) }
        UserDefaults.standard.synchronize()

        await Dialogs.info("All data deleted",
                           account.isEmpty ? "Corvus quits now."
                               : "Corvus quits now. If this computer is still listed under Linked devices on your phone, remove it there.")
        exit(0)
    }
}
