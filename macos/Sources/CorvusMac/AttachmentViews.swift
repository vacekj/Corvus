import AppKit
import AVKit
import CorvusCore
import SwiftUI

/// One attachment inside a bubble: inline image / GIF, inline video, audio player or a file row.
struct AttachmentView: View {
    @Environment(AppModel.self) private var model
    let message: Message
    let index: Int
    let attachment: Attachment
    let foreground: Color
    /// Photo-only bubbles: the image fills the bubble, which clips it.
    var edgeToEdge = false
    @Environment(\.conversationKey) private var conversationKey

    var body: some View {
        let att = attachment
        let token = model.attachmentToken(message, index)
        Group {
            if att.isSticker {
                StickerView(attachment: att)
            } else if att.isVideo {
                VideoAttachment(message: message, index: index, token: token, attachment: att, foreground: foreground,
                                maxSide: edgeToEdge ? 340 : 300) { model.openAttachment(message, index) }
            } else if att.isAudio {
                AudioAttachment(token: token, attachment: att, foreground: foreground) { model.toggleAudio(message, index) }
            } else if att.isImage {
                FullImageView(conversation: conversationKey, message: message, index: index,
                              maxSide: edgeToEdge ? 340 : 300, cornerRadius: edgeToEdge ? 0 : 10)
            } else {
                FileRow(attachment: att, foreground: foreground) { model.openAttachment(message, index) }
            }
        }
    }
}

private struct FileRow: View {
    let attachment: Attachment
    let foreground: Color
    let open: () -> Void

    var body: some View {
        Button(action: open) {
            HStack(spacing: 10) {
                Image(systemName: "doc.fill")
                    .font(.system(size: 16))
                    .frame(width: 36, height: 36)
                    .background(Circle().fill(foreground.opacity(0.15)))
                VStack(alignment: .leading, spacing: 1) {
                    Text(attachment.filename.isEmpty ? "Attachment" : attachment.filename).lineLimit(1)
                    Text([attachment.contentType, attachment.size > 0 ? Media.humanSize(attachment.size) : ""]
                            .filter { !$0.isEmpty }.joined(separator: " · "))
                        .font(.caption)
                        .opacity(0.75)
                }
            }
            .foregroundStyle(foreground)
            .padding(.vertical, 2)
        }
        .buttonStyle(.plain)
        .help("Open or save …")
    }
}

private struct VideoAttachment: View {
    @Environment(AppModel.self) private var model
    @Environment(\.conversationKey) private var conversationKey
    @Environment(\.displayScale) private var displayScale
    let message: Message
    let index: Int
    let token: String
    let attachment: Attachment
    let foreground: Color
    let maxSide: CGFloat
    let load: () -> Void
    @State private var player: AVPlayer?
    @State private var poster: NSImage?

    var body: some View {
        // Shaped like the video (rotation applied); the poster is its first frame.
        let size = AppModel.mediaFrame(width: poster.map { Int($0.size.width) } ?? attachment.width,
                                       height: poster.map { Int($0.size.height) } ?? attachment.height, maxSide: maxSide)
        Group {
            if let player {
                VideoPlayer(player: player)
            } else {
                Button(action: load) {
                    ZStack {
                        if let poster {
                            Image(nsImage: poster).resizable().interpolation(.high).aspectRatio(contentMode: .fill)
                        } else {
                            Rectangle().fill(Color.black.opacity(0.6))
                        }
                        if model.videoLoading.contains(token) {
                            ProgressView().controlSize(.small)
                        } else {
                            Image(systemName: "play.circle.fill").font(.system(size: 40)).foregroundStyle(.white).shadow(radius: 4)
                        }
                    }
                    .frame(width: size.width, height: size.height)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(attachment.filename)
            }
        }
        .frame(width: size.width, height: size.height)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .task(id: token) {
            if poster == nil, !conversationKey.isEmpty {
                poster = await model.videoPoster(conversationKey, message, index, maxPixel: Int(maxSide * max(displayScale, 2)))
            }
        }
        .onChange(of: model.videoURLs[token]) { _, url in
            guard let url else { return }
            let p = AVPlayer(url: url)
            player = p
            p.play()
        }
        .onAppear {
            if player == nil, let url = model.videoURLs[token] { player = AVPlayer(url: url) }
        }
        .onDisappear { player?.pause() }
    }
}

private struct AudioAttachment: View {
    @Environment(AppModel.self) private var model
    let token: String
    let attachment: Attachment
    let foreground: Color
    let toggle: () -> Void

    var body: some View {
        let active = model.audioToken == token
        HStack(spacing: 8) {
            Button(action: toggle) {
                if active && model.audioLoading {
                    ProgressView().controlSize(.small).frame(width: 28, height: 28)
                } else {
                    Image(systemName: active && model.audioPlaying ? "pause.circle.fill" : "play.circle.fill")
                        .font(.system(size: 28))
                }
            }
            .buttonStyle(.plain)
            VStack(alignment: .leading, spacing: 3) {
                Text(attachment.filename.isEmpty ? "Audio" : attachment.filename).font(.caption).lineLimit(1)
                ProgressView(value: active && model.audioDuration > 0 ? min(1, model.audioPosition / model.audioDuration) : 0)
                    .progressViewStyle(.linear)
                    .tint(foreground)
                    .frame(width: 160)
                Text(active ? "\(Self.time(model.audioPosition)) / \(Self.time(model.audioDuration))"
                        : (attachment.size > 0 ? Media.humanSize(attachment.size) : ""))
                    .font(.caption2.monospacedDigit())
                    .opacity(0.75)
            }
        }
        .foregroundStyle(foreground)
    }

    static func time(_ s: Double) -> String {
        guard s.isFinite, s > 0 else { return "0:00" }
        let t = Int(s)
        return String(format: "%d:%02d", t / 60, t % 60)
    }
}

/// Animated GIF (NSImageView animates GIF data by itself).
struct AnimatedImage: NSViewRepresentable {
    let data: Data

    func makeNSView(context: Context) -> NSImageView {
        let v = NSImageView()
        v.animates = true
        v.imageScaling = .scaleProportionallyUpOrDown
        v.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        v.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        v.image = NSImage(data: data)
        return v
    }

    func updateNSView(_ v: NSImageView, context: Context) {
        if context.coordinator.data != data {
            context.coordinator.data = data
            v.image = NSImage(data: data)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(data: data) }
    final class Coordinator {
        var data: Data
        init(data: Data) { self.data = data }
    }
}

/// Full-size image shown over the main window (Esc, a click outside or the close button closes it).
@MainActor @Observable
final class ImageViewerWindow {
    static let shared = ImageViewerWindow()
    struct Item: Identifiable {
        let id = UUID()
        let data: Data
        let image: NSImage
        let title: String
        /// View Once media: no saving, kept out of screenshots and screen sharing while shown.
        var viewOnce = false
        var player: AVPlayer?
        var videoFile: URL?
    }
    var item: Item? {
        didSet { if let old = oldValue, old.id != item?.id { ImageViewerWindow.finish(old) } }
    }
    private var savedSharingType: NSWindow.SharingType?

    static func show(data: Data, title: String) {
        guard let image = NSImage(data: data) else { return }
        shared.item = Item(data: data, image: image, title: title)
    }

    static func showViewOnce(image data: Data) {
        guard let image = NSImage(data: data) else { return }
        shared.protectWindow()
        shared.item = Item(data: data, image: image, title: "View once", viewOnce: true)
    }

    static func showViewOnce(video url: URL) {
        let player = AVPlayer(url: url)
        shared.protectWindow()
        shared.item = Item(data: Data(), image: NSImage(), title: "View once", viewOnce: true, player: player, videoFile: url)
        player.play()
    }

    static func close() { shared.item = nil }

    private func protectWindow() {
        guard let w = MainWindowTracker.shared.window else { return }
        if savedSharingType == nil { savedSharingType = w.sharingType }
        w.sharingType = .none
    }

    private static func finish(_ old: Item) {
        old.player?.pause()
        if let f = old.videoFile { try? FileManager.default.removeItem(at: f) }
        if old.viewOnce, shared.item?.viewOnce != true, let t = shared.savedSharingType {
            MainWindowTracker.shared.window?.sharingType = t
            shared.savedSharingType = nil
        }
    }
}

/// The image viewer layer of the main window.
struct ImageViewerOverlay: View {
    private let viewer = ImageViewerWindow.shared
    @State private var escMonitor: Any?

    var body: some View {
        if let item = viewer.item {
            ZStack(alignment: .topTrailing) {
                Color.black.opacity(0.9)
                    .contentShape(Rectangle())
                    .onTapGesture { ImageViewerWindow.close() }
                Group {
                    if let player = item.player {
                        AVPlayerViewRepresentable(player: player)
                    } else {
                        ImageViewerContent(data: item.data, image: item.image)
                    }
                }
                    .padding(EdgeInsets(top: 52, leading: 24, bottom: 24, trailing: 24))
                    .allowsHitTesting(false)
                HStack(spacing: 14) {
                    if !item.title.isEmpty {
                        Text(item.title).foregroundStyle(.white.opacity(0.8)).lineLimit(1)
                    }
                    if !item.viewOnce {
                        Button { saveCopy(item) } label: { Image(systemName: "square.and.arrow.down") }
                            .help("Save …")
                    }
                    Button { ImageViewerWindow.close() } label: { Image(systemName: "xmark") }
                        .help("Close (Esc)")
                }
                .buttonStyle(.borderless)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white)
                .padding(16)
            }
            .ignoresSafeArea()
            .transition(.opacity)
            .onAppear { installEsc() }
            .onDisappear { removeEsc() }
            .id(item.id)
        }
    }

    // Esc must work wherever the focus is (the composer keeps it while the image is shown).
    private func installEsc() {
        removeEsc()
        escMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { e in
            if e.keyCode == 53, ImageViewerWindow.shared.item != nil {
                ImageViewerWindow.close()
                return nil
            }
            return e
        }
    }

    private func removeEsc() {
        if let m = escMonitor { NSEvent.removeMonitor(m) }
        escMonitor = nil
    }

    private func saveCopy(_ item: ImageViewerWindow.Item) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = item.title.isEmpty ? "Image" : item.title
        if panel.runModal() == .OK, let url = panel.url { try? item.data.write(to: url) }
    }
}

private struct ImageViewerContent: View {
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
