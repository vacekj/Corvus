import AppKit
import CorvusCore
import SwiftUI

/// Corvus's own update check: once a day and from
/// Help / Settings. A newer release shows a banner above the chat list with its notes and a link to the
/// release page; nothing is downloaded or installed.
@MainActor @Observable
final class AppUpdater {
    static let shared = AppUpdater()

    static let autoCheckKey = "corvusUpdateCheck"
    private static let lastCheckKey = "corvusUpdateLastCheck"
    private static let dismissedKey = "corvusUpdateDismissed"

    /// A newer release than the running build (cleared when the user dismisses it).
    private(set) var available: AppUpdate.Release?
    private(set) var checking = false
    /// The result of the last check, for Settings ("Up to date", "Could not reach GitHub").
    private(set) var lastResult: String?
    private(set) var lastCheck: Date? = UserDefaults.standard.object(forKey: AppUpdater.lastCheckKey) as? Date

    @ObservationIgnored private var started = false

    let installed = AppUpdate.Installed(infoDictionary: Bundle.main.infoDictionary)

    var autoCheck: Bool {
        get { access(keyPath: \.autoCheck); return UserDefaults.standard.object(forKey: Self.autoCheckKey) as? Bool ?? true }
        set {
            withMutation(keyPath: \.autoCheck) { UserDefaults.standard.set(newValue, forKey: Self.autoCheckKey) }
            if newValue { check(silent: true, onlyIfDue: true) }
        }
    }

    /// Checks shortly after launch and then hourly whether a day has passed since the last check.
    func startAutomaticChecks() {
        guard !started else { return }
        started = true
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(20)) // not while the app is starting
            while let self {
                self.check(silent: true, onlyIfDue: true)
                try? await Task.sleep(for: .seconds(3600))
            }
        }
    }

    func check(silent: Bool, onlyIfDue: Bool = false) {
        if onlyIfDue && (!autoCheck || !AppUpdate.isCheckDue(last: lastCheck, now: Date())) { return }
        guard !checking else { return }
        checking = true
        Task {
            defer { checking = false }
            let outcome = await fetch()
            let now = Date()
            lastCheck = now
            UserDefaults.standard.set(now, forKey: Self.lastCheckKey)
            switch outcome {
            case .newer(let r):
                lastResult = "Corvus \(r.displayVersion) is available."
                let dismissed = UserDefaults.standard.string(forKey: Self.dismissedKey)
                if !silent || dismissed != r.tag { available = r }
                if !silent { await announce(r) }
            case .current(let r):
                lastResult = "Corvus is up to date."
                if available != nil { available = nil }
                if !silent {
                    await Dialogs.info("Corvus is up to date", "Installed: \(installed.displayVersion)\nLatest release: \(r.displayVersion)")
                }
            case .unknown(let r):
                lastResult = "This build cannot be compared with the releases."
                if !silent {
                    await offerReleasePage(r, title: "Update check",
                                           message: "Installed: \(installed.displayVersion)\nLatest release: \(r.displayVersion)\n\n"
                                               + "This build does not say which commit it was built from, so Corvus cannot tell whether it is up to date.")
                }
            case .noReleases:
                lastResult = "No releases have been published yet."
                if !silent { await Dialogs.info("Update check", "\(AppUpdate.repository) has not published any releases yet.") }
            case .failed(let why):
                lastResult = "Could not check: \(why)"
                if !silent { await Dialogs.warn("Update check", "Could not reach GitHub:\n\(why)") }
            }
        }
    }

    /// The banner's close button: this release is not offered again by the automatic check.
    func dismiss() {
        if let r = available { UserDefaults.standard.set(r.tag, forKey: Self.dismissedKey) }
        available = nil
    }

    // MARK: Network

    private enum Outcome {
        case newer(AppUpdate.Release), current(AppUpdate.Release), unknown(AppUpdate.Release), noReleases, failed(String)
    }

    private static func request(_ path: String) -> URLRequest {
        var req = URLRequest(url: URL(string: "https://api.github.com/repos/\(AppUpdate.repository)/\(path)")!)
        req.setValue("corvus", forHTTPHeaderField: "User-Agent")
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.timeoutInterval = 30
        return req
    }

    private static func json(_ path: String) async throws -> (status: Int, object: [String: Any]) {
        let (data, response) = try await URLSession.shared.data(for: request(path))
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        return (status, (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:])
    }

    private func fetch() async -> Outcome {
        do {
            let (status, o) = try await Self.json("releases/latest")
            if status == 404 { return .noReleases }
            guard status == 200 else { return .failed("GitHub answered \(status).") }
            guard let r = AppUpdate.release(fromGitHub: o) else { return .failed("The latest release could not be read.") }
            switch AppUpdate.verdict(installed: installed, latest: r) {
            case .newer: return .newer(r)
            case .upToDate: return .current(r)
            case .unknown: return .unknown(r)
            case .compareCommits(let base, let head):
                let (cs, cmp) = try await Self.json("compare/\(base)...\(head)")
                // An unknown commit (a local build) cannot be compared.
                if cs == 404 { return .unknown(r) }
                guard cs == 200 else { return .failed("GitHub answered \(cs).") }
                return AppUpdate.isNewer(compareStatus: cmp["status"] as? String ?? "") ? .newer(r) : .current(r)
            }
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    private func announce(_ r: AppUpdate.Release) async {
        await offerReleasePage(r, title: "Corvus \(r.displayVersion) is available",
                               message: "Installed: \(installed.displayVersion)\n\nDownload the new version from the release page "
                                   + "and replace Corvus in Applications. Your chats and settings are kept.")
    }

    private func offerReleasePage(_ r: AppUpdate.Release, title: String, message: String) async {
        if await Dialogs.ask(title, message, buttons: ["Open release page", "Close"]) == 0 {
            NSWorkspace.shared.open(r.url)
        }
    }
}

/// Above the chat list while a newer Corvus is available.
struct AppUpdateBanner: View {
    private let updater = AppUpdater.shared
    @State private var notesShown = false

    var body: some View {
        if let r = updater.available {
            HStack(spacing: 10) {
                Image(systemName: "arrow.down.circle.fill").font(.system(size: 20)).foregroundStyle(Theme.signalBlue)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Update available").font(.callout.weight(.semibold))
                    Text("Corvus \(r.displayVersion)").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 4)
                Button("What's new") { notesShown = true }
                    .buttonStyle(.link)
                    .popover(isPresented: $notesShown, arrowEdge: .bottom) { ReleaseNotesView(release: r) }
                Button { updater.dismiss() } label: { Image(systemName: "xmark") }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                    .iconHelp("Dismiss", tooltip: "Not now")
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.signalBlue.opacity(0.1)))
            .padding(.horizontal, 10)
            .padding(.bottom, 6)
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Corvus update available")
        }
    }
}

private struct ReleaseNotesView: View {
    let release: AppUpdate.Release

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(release.name).font(.headline)
            if let d = release.publishedAt {
                Text(d.formatted(date: .long, time: .omitted)).font(.caption).foregroundStyle(.secondary)
            }
            ScrollView {
                Text(Self.notes(release.notes))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 280)
            HStack {
                Spacer()
                Button("Open release page") { NSWorkspace.shared.open(release.url) }
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(14)
        .frame(width: 380)
    }

    /// GitHub release notes are Markdown; headings and lists keep their lines.
    static func notes(_ md: String) -> AttributedString {
        if md.isEmpty { return AttributedString("No release notes.") }
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return (try? AttributedString(markdown: md, options: options)) ?? AttributedString(md)
    }
}

/// Settings → General: the running version, the daily check and "Check now".
struct AppUpdateSettingsSection: View {
    private let updater = AppUpdater.shared

    var body: some View {
        @Bindable var updater = updater
        Section("Corvus") {
            LabeledContent("Version", value: updater.installed.displayVersion)
            Toggle("Check for updates daily", isOn: $updater.autoCheck)
            HStack {
                Button("Check for updates") { updater.check(silent: false) }
                    .disabled(updater.checking)
                if updater.checking {
                    ProgressView().controlSize(.small)
                } else if let result = updater.lastResult {
                    Text(result).font(.caption).foregroundStyle(.secondary)
                }
            }
            if let r = updater.available {
                Link("Download Corvus \(r.displayVersion)", destination: r.url)
            }
        }
    }
}
