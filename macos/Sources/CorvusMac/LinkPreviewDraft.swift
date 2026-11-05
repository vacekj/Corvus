import CorvusCore
import Foundation
import Observation

/// The preview of the link in the composer text: generated while typing, shown as a removable chip and
/// sent with the message (port of the draft preview logic of src/MainWindow.cpp).
@MainActor
@Observable
final class LinkPreviewDraft {
    /// Ready to send and shown above the composer.
    private(set) var preview: LinkPreview?
    /// A link was found and its page is being (or about to be) fetched.
    private(set) var loading = false

    @ObservationIgnored private var imageData: Data?
    @ObservationIgnored private var imageSuffix = "jpg"
    @ObservationIgnored private var requestedUrl = ""
    @ObservationIgnored private var dismissedUrl = ""
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored var thumbPending: Set<String> = []   // incoming preview images being fetched
    @ObservationIgnored var deferredSend: Task<Void, Never>?
    @ObservationIgnored var bypassWait = false   // send now, with or without the preview

    /// Waiting for typing to settle keeps half-typed addresses from being requested one by one.
    static let debounce: Duration = .milliseconds(600)

    /// What the chip shows.
    var visiblePreview: LinkPreview? {
        guard let p = preview, p.url != dismissedUrl else { return nil }
        return p
    }

    /// Follows the composer. `enabled` is the Settings switch; no previews while editing a message.
    func update(text: String, enabled: Bool, editing: Bool) {
        let url = LinkPreviews.firstHttpsLink(in: text) ?? ""
        if !enabled || editing || url.isEmpty {
            cancel()
            requestedUrl = ""
            if url.isEmpty { dismissedUrl = "" }
            return
        }
        if url == dismissedUrl || url == requestedUrl { return }
        cancel()
        requestedUrl = url
        loading = true
        generation += 1
        let gen = generation
        task = Task { [weak self] in
            try? await Task.sleep(for: LinkPreviewDraft.debounce)
            guard !Task.isCancelled else { return }
            let fetched = await LinkPreviewFetcher.fetch(link: url)
            guard let self, !Task.isCancelled, gen == self.generation else { return }
            self.preview = fetched?.preview
            self.imageData = fetched?.imageData
            self.imageSuffix = fetched?.imageSuffix ?? "jpg"
            self.loading = false
        }
    }

    /// The user closed the chip: no preview for this link.
    func dismiss() {
        dismissedUrl = preview?.url ?? requestedUrl
        cancel()
    }

    func reset() {
        cancel()
        requestedUrl = ""
        dismissedUrl = ""
    }

    private func cancel() {
        generation += 1
        task?.cancel()
        task = nil
        loading = false
        preview = nil
        imageData = nil
    }

    /// True while the link of `text` still gets its preview.
    func isPending(for text: String) -> Bool {
        !bypassWait && loading && LinkPreviews.firstHttpsLink(in: text) == requestedUrl
    }

    /// Waits for the preview, at most `seconds`: a slow site must not block sending forever.
    func waitUntilReady(seconds: Double = 8) async {
        let deadline = Date().addingTimeInterval(seconds)
        while loading && Date() < deadline { try? await Task.sleep(for: .milliseconds(100)) }
    }

    /// The preview to send with `text`, or nil (none, other link, dismissed).
    func previewToSend(for text: String) -> LinkPreview? {
        guard let p = preview, p.isValid, p.url != dismissedUrl, LinkPreviews.firstHttpsLink(in: text) == p.url else { return nil }
        return p
    }

    /// Writes the image of the preview into `dir` for signal-cli (`previewImage` takes a file path).
    func stageImage(in dir: URL) -> String? {
        guard let data = imageData else { return nil }
        let folder = dir.appendingPathComponent("link-preview", isDirectory: true)
        let file = folder.appendingPathComponent("preview.\(imageSuffix)")
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try data.write(to: file)
            return file.path
        } catch {
            return nil
        }
    }
}
