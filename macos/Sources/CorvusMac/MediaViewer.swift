import AppKit
import AVKit
import CorvusCore
import SwiftUI

/// Pictures and videos shown over the main window: zoom (pinch, ⌘+ / ⌘− / ⌘0, double-click), pan,
/// ← → through the chat's media, Save and Forward. Esc, a click outside or the close button closes it.
@MainActor @Observable
final class ImageViewerWindow {
    static let shared = ImageViewerWindow()

    struct Item: Identifiable {
        var id = UUID()
        var data = Data()             // original bytes of a picture (Save)
        var image: NSImage?           // the picture; while loading a smaller decoded copy (or a video poster)
        var animated = false          // GIF: `image` was made from `data` and animates
        var pixelSize = CGSize.zero   // full size, so the picture keeps its place when the original arrives
        var title = ""                // file name
        var viewOnce = false          // View Once media: no saving, kept out of screenshots and screen sharing
        var player: AVPlayer?
        var videoFile: URL?
        var deleteVideoFile = false
        var isVideo = false
        var ref: MediaRef?
        var sender = ""
        var date: Date?
        var loading = false
        var blocked = false           // not shown by the app (AttachmentPolicy), only saved
        var failed = false
    }

    var item: Item? {
        didSet { if let old = oldValue, old.id != item?.id { finish(old) } }
    }
    private(set) var refs: [MediaRef] = []
    private(set) var position = 0

    @ObservationIgnored weak var zoomView: ZoomScrollView?
    @ObservationIgnored private var loader: ((MediaRef) async -> Item?)?
    @ObservationIgnored private var placeholder: ((MediaRef) -> Item?)?
    @ObservationIgnored private var loadTask: Task<Void, Never>?
    @ObservationIgnored private var prefetched: [MediaRef: Item] = [:]
    @ObservationIgnored private var prefetching: Set<MediaRef> = []
    @ObservationIgnored private var savedSharingType: NSWindow.SharingType?

    var canGoBack: Bool { item?.viewOnce == false && position > 0 && !refs.isEmpty }
    var canGoForward: Bool { item?.viewOnce == false && position + 1 < refs.count }

    static func show(data: Data, title: String) {
        guard let image = NSImage(data: data) else { return }
        shared.reset()
        shared.item = Item(data: data, image: image, animated: data.starts(with: Data("GIF8".utf8)),
                           pixelSize: pixelSize(image), title: title)
    }

    static func showViewOnce(image data: Data) {
        guard let image = NSImage(data: data) else { return }
        shared.reset()
        shared.protectWindow()
        shared.item = Item(data: data, image: image, title: "View once", viewOnce: true)
    }

    static func showViewOnce(video url: URL) {
        let player = AVPlayer(url: url)
        shared.reset()
        shared.protectWindow()
        shared.item = Item(title: "View once", viewOnce: true, player: player, videoFile: url, deleteVideoFile: true, isVideo: true)
        player.play()
    }

    static func close() {
        shared.reset()
        shared.item = nil
    }

    /// Opens the viewer at `ref` among `refs`: at once with `placeholder`, then with what `loader` returns.
    func present(refs: [MediaRef], at ref: MediaRef, placeholder: @escaping (MediaRef) -> Item?,
                 loader: @escaping (MediaRef) async -> Item?) {
        reset()
        self.refs = refs
        position = refs.firstIndex(of: ref) ?? 0
        self.placeholder = placeholder
        self.loader = loader
        show(position)
    }

    func step(_ delta: Int) {
        guard item?.viewOnce == false else { return }
        let n = position + delta
        guard refs.indices.contains(n) else { return }
        position = n
        show(n)
    }

    private func reset() {
        loadTask?.cancel()
        loadTask = nil
        prefetched = [:]
        prefetching = []
        loader = nil
        placeholder = nil
        if !refs.isEmpty { refs = [] }
        if position != 0 { position = 0 }
    }

    private func show(_ pos: Int) {
        loadTask?.cancel()
        let ref = refs[pos]
        if let ready = prefetched[ref] {
            var it = ready
            it.id = UUID()
            item = it
            prefetchNeighbours()
            return
        }
        var ph = placeholder?(ref) ?? Item(ref: ref)
        ph.loading = true
        item = ph
        let id = ph.id
        loadTask = Task { [weak self] in
            let loaded = await self?.loader?(ref)
            guard let self, !Task.isCancelled, self.item?.id == id else {
                loaded?.player?.pause()
                return
            }
            guard var it = loaded else { // the message is gone (deleted or expired meanwhile)
                self.item?.loading = false
                self.item?.failed = true
                return
            }
            it.id = id
            self.item = it
            it.player?.play()
            self.prefetchNeighbours()
        }
    }

    /// The pictures next to the shown one are decoded ahead, so ← → show them at once.
    private func prefetchNeighbours() {
        let wanted = Set([position - 1, position + 1].filter { refs.indices.contains($0) }.map { refs[$0] })
        prefetched = prefetched.filter { wanted.contains($0.key) }
        for ref in wanted where prefetched[ref] == nil && !prefetching.contains(ref) {
            guard let ph = placeholder?(ref), !ph.isVideo else { continue }
            prefetching.insert(ref)
            Task { [weak self] in
                let it = await self?.loader?(ref)
                guard let self else { return }
                self.prefetching.remove(ref)
                let near = self.refs.indices.contains(self.position)
                    && abs((self.refs.firstIndex(of: ref) ?? -10) - self.position) == 1
                if let it, !it.failed, near { self.prefetched[ref] = it }
            }
        }
    }

    private func protectWindow() {
        guard let w = MainWindowTracker.shared.window else { return }
        if savedSharingType == nil { savedSharingType = w.sharingType }
        w.sharingType = .none
    }

    private func finish(_ old: Item) {
        old.player?.pause()
        if old.deleteVideoFile, let f = old.videoFile { try? FileManager.default.removeItem(at: f) }
        if old.viewOnce, item?.viewOnce != true, let t = savedSharingType {
            MainWindowTracker.shared.window?.sharingType = t
            savedSharingType = nil
        }
    }

    static func pixelSize(_ image: NSImage) -> CGSize {
        if let rep = image.representations.first, rep.pixelsWide > 0, rep.pixelsHigh > 0 {
            return CGSize(width: rep.pixelsWide, height: rep.pixelsHigh)
        }
        return image.size
    }
}

// MARK: - Loading

extension AppModel {
    /// Opens the viewer at attachment `i` of `m`, with the pictures and videos of the open chat to page through.
    /// `data`: the attachment was already fetched.
    func openMediaViewer(_ m: Message, _ i: Int, data: Data? = nil) {
        guard let key = current, let c = chats.convs[key], i < m.attachments.count else { return }
        let ref = MediaRef(messageId: m.id, index: i)
        var refs = MediaViewerList.refs(c.msgs)
        if !refs.contains(ref) { refs = [ref] }
        ImageViewerWindow.shared.present(refs: refs, at: ref, placeholder: { [weak self] r in
            self?.viewerPlaceholder(key, r)
        }, loader: { [weak self] r in
            await self?.viewerItem(key, r, data: r == ref ? data : nil)
        })
    }

    private func viewerMessage(_ key: String, _ ref: MediaRef) -> Message? {
        guard let c = chats.convs[key], let m = c.msgs.last(where: { $0.id == ref.messageId }),
              ref.index < m.attachments.count else { return nil }
        return m
    }

    private func viewerBase(_ m: Message, _ ref: MediaRef) -> ImageViewerWindow.Item {
        let att = m.attachments[ref.index]
        var it = ImageViewerWindow.Item()
        it.ref = ref
        it.title = (att.filename as NSString).lastPathComponent
        it.sender = m.outgoing ? "You" : (m.sender.isEmpty ? displayName(m.authorKey) : m.sender)
        it.date = m.time
        it.isVideo = att.isVideo
        if att.width > 0 && att.height > 0 { it.pixelSize = CGSize(width: att.width, height: att.height) }
        return it
    }

    /// What is shown at once: the picture as decoded for the chat (or the video's poster), at full size.
    private func viewerPlaceholder(_ key: String, _ ref: MediaRef) -> ImageViewerWindow.Item? {
        guard let m = viewerMessage(key, ref) else { return nil }
        var it = viewerBase(m, ref)
        guard let img = anyCachedImage(m.attachments[ref.index]) else { return it }
        it.image = img
        let s = ImageViewerWindow.pixelSize(img)
        if it.pixelSize == .zero || abs(it.pixelSize.width / it.pixelSize.height - s.width / s.height) > 0.02 {
            // Unknown or unrotated stored size: the decoded copy's shape, at the stored long side.
            let long = max(it.pixelSize.width, it.pixelSize.height), k = long > 0 ? long / max(s.width, s.height) : 1
            it.pixelSize = CGSize(width: (s.width * k).rounded(), height: (s.height * k).rounded())
        }
        return it
    }

    private func viewerItem(_ key: String, _ ref: MediaRef, data given: Data?) async -> ImageViewerWindow.Item? {
        guard let m = viewerMessage(key, ref) else { return nil }
        let att = m.attachments[ref.index]
        var it = viewerBase(m, ref)
        if att.isVideo {
            if AttachmentPolicy.classify(filename: att.filename, contentType: att.contentType, isMedia: true) != .inApp {
                it.blocked = true
                return it
            }
            do {
                let url = try await videoFile(key, att, token: attachmentToken(m, ref.index))
                it.videoFile = url
                it.player = AVPlayer(url: url)
            } catch {
                it.failed = true
                it.image = anyCachedImage(att)
            }
            return it
        }
        let data: Data
        if let given {
            data = given
        } else {
            do { data = try await fetchAttachmentData(key, att) } catch {
                if att.thumb.isEmpty {
                    it.failed = true
                    return it
                }
                data = att.thumb // the stored preview is better than nothing
            }
        }
        let gif = data.starts(with: Data("GIF8".utf8))
        let image: NSImage? = await Task.detached(priority: .userInitiated) {
            if gif { return NSImage(data: data) }
            return MediaDecode.image(data, maxPixel: 6144) ?? NSImage(data: data)
        }.value
        it.data = data
        let name = it.title.isEmpty ? "image." + Media.preferredSuffix(forMime: att.contentType) : it.title
        guard AttachmentPolicy.classify(filename: name, contentType: att.contentType, isMedia: image != nil) == .inApp,
              let image else {
            it.blocked = image != nil
            it.failed = image == nil
            return it
        }
        it.image = image
        it.animated = gif
        it.pixelSize = ImageViewerWindow.pixelSize(image)
        return it
    }
}

// MARK: - Views

/// The viewer layer of the main window.
struct ImageViewerOverlay: View {
    @Environment(AppModel.self) private var model
    private let viewer = ImageViewerWindow.shared
    @State private var keyMonitor: Any?

    var body: some View {
        if let item = viewer.item {
            ZStack {
                Color.black.opacity(0.92)
                    .contentShape(Rectangle())
                    .onTapGesture { ImageViewerWindow.close() }
                VStack(spacing: 0) {
                    header(item)
                    content(item)
                        .id(item.id)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                if !item.viewOnce && viewer.refs.count > 1 { navigation }
            }
            .ignoresSafeArea()
            .transition(.opacity)
            .onAppear { installKeys() }
            .onDisappear { removeKeys() }
        }
    }

    private func header(_ item: ImageViewerWindow.Item) -> some View {
        HStack(spacing: 16) {
            if item.viewOnce {
                Text(item.title).foregroundStyle(.white.opacity(0.8)).lineLimit(1)
            } else {
                VStack(alignment: .leading, spacing: 1) {
                    Text(item.sender).font(.headline).foregroundStyle(.white).lineLimit(1)
                    if let d = item.date {
                        Text(d.formatted(date: .abbreviated, time: .shortened))
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.7))
                    }
                }
                if viewer.refs.count > 1 {
                    Text("\(viewer.position + 1) of \(viewer.refs.count)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.white.opacity(0.6))
                }
            }
            Spacer(minLength: 8)
            if !item.viewOnce {
                if let ref = item.ref {
                    Button {
                        ImageViewerWindow.close()
                        model.forwardMessageId = ref.messageId
                    } label: { Image(systemName: "arrowshape.turn.up.right") }
                        .help("Forward …")
                }
                Button { save(item) } label: { Image(systemName: "square.and.arrow.down") }
                    .help("Save …")
                    .disabled(item.data.isEmpty && item.videoFile == nil)
            }
            Button { ImageViewerWindow.close() } label: { Image(systemName: "xmark") }
                .help("Close (Esc)")
        }
        .buttonStyle(.borderless)
        .font(.system(size: 15, weight: .semibold))
        .foregroundStyle(.white)
        .padding(.horizontal, 18)
        .frame(height: 56)
    }

    @ViewBuilder
    private func content(_ item: ImageViewerWindow.Item) -> some View {
        if item.viewOnce {
            Group {
                if let player = item.player {
                    AVPlayerViewRepresentable(player: player)
                } else if let image = item.image {
                    ViewOnceImage(data: item.data, image: image)
                }
            }
            .padding(EdgeInsets(top: 0, leading: 24, bottom: 24, trailing: 24))
            .allowsHitTesting(false)
        } else if let player = item.player {
            VideoPlayer(player: player)
                .padding(EdgeInsets(top: 0, leading: 64, bottom: 24, trailing: 64))
        } else if item.blocked || item.failed {
            VStack(spacing: 10) {
                Image(systemName: item.blocked ? "exclamationmark.shield" : "photo")
                    .font(.system(size: 34))
                Text(item.blocked ? "Corvus does not show this file. You can save it and check it first."
                                  : "This attachment is not available.")
                    .multilineTextAlignment(.center)
            }
            .foregroundStyle(.white.opacity(0.8))
            .allowsHitTesting(false)
        } else if let image = item.image {
            ZoomableImage(image: image, size: item.pixelSize == .zero ? ImageViewerWindow.pixelSize(image) : item.pixelSize,
                          animated: item.animated) { ImageViewerWindow.close() }
                .padding(.bottom, 16)
                .overlay(alignment: .center) {
                    if item.loading && item.isVideo { ProgressView().controlSize(.large).tint(.white) }
                }
        } else if item.loading {
            ProgressView().controlSize(.large).tint(.white).allowsHitTesting(false)
        }
    }

    private var navigation: some View {
        HStack {
            if viewer.canGoBack { navButton("chevron.left", help: "Previous (←)") { viewer.step(-1) } }
            Spacer()
            if viewer.canGoForward { navButton("chevron.right", help: "Next (→)") { viewer.step(1) } }
        }
        .padding(.horizontal, 14)
    }

    private func navButton(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 40, height: 40)
                .background(Circle().fill(.white.opacity(0.14)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(help)
    }

    // The keys must work wherever the focus is (the composer keeps it while the viewer is shown).
    private func installKeys() {
        removeKeys()
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { e in
            let viewer = ImageViewerWindow.shared
            guard let item = viewer.item, e.window == nil || e.window === MainWindowTracker.shared.window else { return e }
            let mods = e.modifierFlags.intersection([.command, .control, .option, .shift])
            let chars = e.charactersIgnoringModifiers ?? ""
            switch e.keyCode {
            case KeyCode.escape:
                ImageViewerWindow.close()
                return nil
            case KeyCode.leftArrow where mods.isEmpty:
                viewer.step(-1)
                return nil
            case KeyCode.rightArrow where mods.isEmpty:
                viewer.step(1)
                return nil
            default:
                break
            }
            if mods.contains(.command), !mods.contains(.control), !mods.contains(.option), !item.viewOnce {
                switch chars {
                case "=", "+": viewer.zoomView?.zoomStep(in: true); return nil
                case "-", "_": viewer.zoomView?.zoomStep(in: false); return nil
                case "0": viewer.zoomView?.zoomToFit(); return nil
                default: break
                }
            }
            if e.keyCode == 49, mods.isEmpty, let p = item.player { // space: play / pause
                if p.rate == 0 { p.play() } else { p.pause() }
                return nil
            }
            return e
        }
    }

    private func removeKeys() {
        if let m = keyMonitor { NSEvent.removeMonitor(m) }
        keyMonitor = nil
    }

    private func save(_ item: ImageViewerWindow.Item) {
        let panel = NSSavePanel()
        panel.title = "Save attachment"
        panel.nameFieldStringValue = item.title.isEmpty ? (item.isVideo ? "Video" : "Image") : item.title
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            if !item.data.isEmpty {
                try item.data.write(to: url)
            } else if let f = item.videoFile {
                if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
                try FileManager.default.copyItem(at: f, to: url)
            }
            Media.quarantine(url)
        } catch {
            Task { await Dialogs.warn("Attachment", "The file could not be written.") }
        }
    }
}

private struct ViewOnceImage: View {
    let data: Data
    let image: NSImage

    var body: some View {
        Group {
            if data.starts(with: Data("GIF8".utf8)) {
                AnimatedImage(data: data)
            } else {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fit)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Zoom

/// A picture that can be zoomed (pinch, double-click, ⌘+ / ⌘− / ⌘0) and panned (drag, scroll) when zoomed.
struct ZoomableImage: NSViewRepresentable {
    let image: NSImage
    let size: CGSize
    let animated: Bool
    let close: () -> Void

    func makeNSView(context: Context) -> ZoomScrollView {
        let v = ZoomScrollView()
        v.onBackgroundClick = close
        v.configure(image: image, size: size, animated: animated)
        ImageViewerWindow.shared.zoomView = v
        return v
    }

    func updateNSView(_ v: ZoomScrollView, context: Context) {
        v.onBackgroundClick = close
        if v.imageView.image !== image || v.contentPixelSize != size { v.configure(image: image, size: size, animated: animated) }
        ImageViewerWindow.shared.zoomView = v
    }
}

final class ZoomScrollView: NSScrollView {
    let imageView = NSImageView()
    private(set) var contentPixelSize = CGSize.zero
    /// Showing the whole picture: it is refitted when the window size changes.
    private var fitted = true
    var onBackgroundClick: (() -> Void)?
    private var dragStart: NSPoint?
    private var dragOrigin = NSPoint.zero
    private var dragged = false
    private var lastViewport = CGSize.zero

    init() {
        super.init(frame: .zero)
        contentView = CenteringClipView()
        drawsBackground = false
        contentView.drawsBackground = false
        hasHorizontalScroller = false
        hasVerticalScroller = false
        allowsMagnification = true
        horizontalScrollElasticity = .none
        verticalScrollElasticity = .none
        maxMagnification = ViewerZoom.maxScale
        imageView.imageScaling = .scaleAxesIndependently
        imageView.imageFrameStyle = .none
        imageView.isEditable = false
        documentView = imageView
    }

    required init?(coder: NSCoder) { fatalError() }

    func configure(image: NSImage, size: CGSize, animated: Bool) {
        imageView.animates = animated
        imageView.image = image
        guard size != contentPixelSize, size.width > 0, size.height > 0 else { return }
        contentPixelSize = size
        imageView.frame = CGRect(origin: .zero, size: size)
        fitted = true
        refit()
    }

    private var fitScale: CGFloat { ViewerZoom.fit(image: contentPixelSize, in: bounds.size) }

    private func refit() {
        guard bounds.width > 0, bounds.height > 0, contentPixelSize != .zero else { return }
        minMagnification = ViewerZoom.minScale(fit: fitScale)
        if fitted { setMagnification(fitScale, centeredAt: NSPoint(x: contentPixelSize.width / 2, y: contentPixelSize.height / 2)) }
    }

    override func layout() {
        super.layout()
        viewportChanged()
    }

    override func tile() {
        super.tile()
        viewportChanged()
    }

    private func viewportChanged() {
        guard bounds.size != lastViewport else { return }
        lastViewport = bounds.size
        refit()
    }

    private func zoom(to scale: CGFloat, at point: NSPoint? = nil) {
        let fit = fitScale
        let s = min(max(scale, ViewerZoom.minScale(fit: fit)), ViewerZoom.maxScale)
        let b = contentView.bounds
        let p = point ?? NSPoint(x: b.midX, y: b.midY)
        fitted = abs(s - fit) < 0.001
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.16
            ctx.allowsImplicitAnimation = true
            animator().setMagnification(s, centeredAt: fitted ? NSPoint(x: contentPixelSize.width / 2, y: contentPixelSize.height / 2) : p)
        }
    }

    func zoomStep(in zoomIn: Bool) { zoom(to: ViewerZoom.step(current: magnification, fit: fitScale, zoomIn: zoomIn)) }
    func zoomToFit() { zoom(to: fitScale) }

    override func magnify(with event: NSEvent) {
        super.magnify(with: event)
        fitted = abs(magnification - fitScale) < 0.005
    }

    override func smartMagnify(with event: NSEvent) {
        zoom(to: ViewerZoom.toggled(current: magnification, fit: fitScale), at: imageView.convert(event.locationInWindow, from: nil))
    }

    // The scroll view takes all clicks itself (pan, double-click zoom, a click beside the picture closes).
    override func hitTest(_ point: NSPoint) -> NSView? { super.hitTest(point) != nil ? self : nil }

    override func mouseDown(with event: NSEvent) {
        let p = imageView.convert(event.locationInWindow, from: nil)
        if event.clickCount == 2 {
            dragStart = nil
            if imageView.bounds.contains(p) { zoom(to: ViewerZoom.toggled(current: magnification, fit: fitScale), at: p) }
            return
        }
        dragStart = event.locationInWindow
        dragOrigin = contentView.bounds.origin
        dragged = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = dragStart else { return }
        let dx = event.locationInWindow.x - start.x, dy = event.locationInWindow.y - start.y
        if !dragged && abs(dx) + abs(dy) > 3 { dragged = true }
        guard dragged else { return }
        let doc = imageView.frame.size, view = contentView.bounds.size
        guard doc.width > view.width + 0.5 || doc.height > view.height + 0.5 else { return }
        NSCursor.closedHand.set()
        let origin = NSPoint(x: dragOrigin.x - dx / magnification, y: dragOrigin.y - dy / magnification)
        contentView.scroll(to: contentView.constrainBoundsRect(NSRect(origin: origin, size: view)).origin)
        reflectScrolledClipView(contentView)
    }

    override func mouseUp(with event: NSEvent) {
        defer { dragStart = nil }
        if dragged { NSCursor.arrow.set() }
        guard dragStart != nil, !dragged, event.clickCount == 1 else { return }
        if !imageView.bounds.contains(imageView.convert(event.locationInWindow, from: nil)) { onBackgroundClick?() }
    }
}

/// Keeps a picture smaller than the visible area in its middle.
private final class CenteringClipView: NSClipView {
    override func constrainBoundsRect(_ proposed: NSRect) -> NSRect {
        var r = super.constrainBoundsRect(proposed)
        guard let doc = documentView?.frame else { return r }
        if r.width >= doc.width { r.origin.x = (doc.width - r.width) / 2 }
        if r.height >= doc.height { r.origin.y = (doc.height - r.height) / 2 }
        return r
    }
}
