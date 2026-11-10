import AppKit
import CorvusCore
import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettings().tabItem { Label("General", systemImage: "gearshape") }
            AppearanceSettings().tabItem { Label("Appearance", systemImage: "paintpalette") }
            ChatFolderSettings().tabItem { Label("Chats", systemImage: "folder") }
            NotificationSettingsView().tabItem { Label("Notifications", systemImage: "bell.badge") }
            PrivacySettingsView().tabItem { Label("Privacy", systemImage: "hand.raised") }
            ProfileEditor().tabItem { Label("Profile", systemImage: "person.crop.circle") }
            AdvancedSettings().tabItem { Label("Advanced", systemImage: "slider.horizontal.3") }
        }
        .frame(width: 540, height: 600) // one size for all tabs: the window does not jump
    }
}

// MARK: - General

private struct GeneralSettings: View {
    @Environment(AppModel.self) private var model
    @AppStorage(MessageInput.spellCheckKey) private var spellCheck = false
    @State private var giphyKey: String?

    @AppStorage(SentMediaQuality.key) private var sentMediaQuality = SentMediaQuality.standard

    var body: some View {
        Form {
            AppGeneralSections()
            Section("Signal backend") {
                LabeledContent("Version", value: model.version.isEmpty ? "–" : model.version)
                HStack {
                    Spacer()
                    Button("Reconnect") { model.reconnect() }
                }
            }
            HistoryProtectionSection()
            Section("Message field") {
                Toggle("Check spelling while typing", isOn: $spellCheck)
                EmojiSkinToneSetting()
            }
            Section("Media") {
                Picker("Sent media quality", selection: $sentMediaQuality) {
                    Text("Standard").tag(SentMediaQuality.standard)
                    Text("High").tag(SentMediaQuality.high)
                }
            }
            Section("GIPHY") {
                if let giphyKey {
                    GiphyKeyForm(initial: giphyKey, compact: true) { self.giphyKey = $0 }
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { giphyKey = (try? model.loadGiphyApiKey()) ?? "" }
    }
}

// MARK: - Appearance

private struct AppearanceSettings: View {
    @Environment(AppModel.self) private var model
    @State private var a = Appearance()
    @State private var loaded = false

    var body: some View {
        Form {
            DisplaySettingsSections()
            Section("Bubbles") {
                colorRow("Your messages", \.outBg, a.outBgColor)
                colorRow("Text of your messages", \.outText, a.outTextColor)
                colorRow("Received messages", \.inBg, a.inBgColor)
                colorRow("Text of received messages", \.inText, a.inTextColor)
                colorRow("Chat background", \.background, a.backgroundColor)
                Stepper("Corner radius: \(a.radius) pt", value: $a.radius, in: 0...28)
            }
            Section("Chat list") {
                Toggle("Show contact avatars", isOn: $a.showAvatars)
            }
            Section("Messages") {
                Toggle("Generate link previews", isOn: $a.generateLinkPreviews)
            }
            Section("Preview") {
                VStack(spacing: 6) {
                    previewBubble("Hi! How are you?", outgoing: false)
                    previewBubble("Great, thanks – and you?", outgoing: true)
                }
                .padding(10)
                .frame(maxWidth: .infinity)
                .background(a.backgroundColor)
            }
            HStack {
                Button("Reset to defaults") { a = Appearance() }
                Spacer()
                Text("Untouched colours follow the light or dark system appearance.").font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear {
            if !loaded { a = model.appearance; loaded = true }
        }
        .onChange(of: a) { _, new in model.applyAppearance(new) } // live
    }

    private func colorRow(_ title: String, _ kp: WritableKeyPath<Appearance, String?>, _ current: Color) -> some View {
        HStack {
            ColorPicker(title, selection: Binding(get: { current }, set: { a[keyPath: kp] = Appearance.hex($0) }), supportsOpacity: false)
            if a[keyPath: kp] != nil {
                Button { a[keyPath: kp] = nil } label: { Image(systemName: "arrow.uturn.backward") }
                    .buttonStyle(.borderless)
                    .iconHelp("Back to the default colour")
            }
        }
    }

    private func previewBubble(_ text: String, outgoing: Bool) -> some View {
        HStack {
            if outgoing { Spacer() }
            Text(text)
                .foregroundStyle(outgoing ? a.outTextColor : a.inTextColor)
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(RoundedRectangle(cornerRadius: CGFloat(a.radius), style: .continuous)
                    .fill(outgoing ? a.outBgColor : a.inBgColor))
            if !outgoing { Spacer() }
        }
    }
}

// MARK: - Notifications

private struct NotificationSettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var n = NotificationSettings()
    @State private var loaded = false
    @State private var soundError: String?

    var body: some View {
        Form {
            Section("Notifications") {
                Toggle("Show notifications for new messages", isOn: $n.notifications)
                Picker("Notifications show", selection: $n.content) {
                    Text("Name and message").tag(NotificationSettings.Content.nameAndText)
                    Text("Name only").tag(NotificationSettings.Content.nameOnly)
                    Text("Nothing (just “New message”)").tag(NotificationSettings.Content.hidden)
                }
                .disabled(!n.notifications)
                if !model.notifier.available {
                    Text("Notifications need the app bundle (run it via scripts/build-app.sh, not swift run).")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Button("Notification settings in System Settings …") {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension")!)
                }
            }
            Section("Sound") {
                Toggle("Play a sound for new messages", isOn: $n.sound)
                Picker("Sound", selection: $n.soundId) {
                    ForEach(SoundPlayer.builtins, id: \.id) { Text($0.title).tag($0.id) }
                    Text("Custom file").tag("custom")
                }
                .disabled(!n.sound)
                if n.soundId == "custom" {
                    HStack {
                        Text(n.soundFile.isEmpty ? "No file chosen" : (n.soundFile as NSString).lastPathComponent)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Choose …") { chooseSound() }
                    }
                }
                HStack {
                    Button("Test") { soundError = model.sound.play(n) }
                    if let soundError { Text(soundError).font(.caption).foregroundStyle(.red) }
                }
                Text("Muted chats (right-click a chat) and the chat you are looking at never alert.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Menu bar") {
                Toggle("Show icon in the menu bar", isOn: $n.trayIcon)
                Toggle("Keep running in the menu bar when the window is closed", isOn: $n.closeToTray)
                    .disabled(!n.trayIcon)
                Toggle("Start with the window hidden", isOn: $n.startMinimizedInTray)
                    .disabled(!n.trayIcon)
            }
        }
        .formStyle(.grouped)
        .onAppear {
            if !loaded { n = model.notify; loaded = true }
        }
        .onChange(of: n) { _, new in model.applyNotifications(new) }
    }

    private func chooseSound() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.audio]
        if panel.runModal() == .OK, let url = panel.url { n.soundFile = url.path }
    }
}
