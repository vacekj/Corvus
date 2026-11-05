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
                FullImageView(conversation: model.current ?? "", message: message, index: index,
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
            if poster == nil, let key = model.current {
                poster = await model.videoPoster(key, message, index, maxPixel: Int(maxSide * max(displayScale, 2)))
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

/// Full-size image in a window of its own.
@MainActor
enum ImageViewerWindow {
    private static var windows: [NSWindow] = []

    static func show(data: Data, title: String) {
        guard let image = NSImage(data: data) else { return }
        let screen = NSScreen.main?.visibleFrame.size ?? NSSize(width: 1200, height: 800)
        let scale = min(1, screen.width * 0.85 / max(image.size.width, 1), screen.height * 0.85 / max(image.size.height, 1))
        let size = NSSize(width: max(200, image.size.width * scale), height: max(150, image.size.height * scale))
        let view = NSHostingView(rootView: ImageViewerContent(data: data, image: image))
        let w = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled, .closable, .resizable, .miniaturizable],
                         backing: .buffered, defer: false)
        w.title = title.isEmpty ? "Image" : title
        w.contentView = view
        w.isReleasedWhenClosed = false
        w.center()
        w.makeKeyAndOrderFront(nil)
        windows.append(w)
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: w, queue: .main) { _ in
            MainActor.assumeIsolated { windows.removeAll { $0 === w } }
        }
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
        .background(Color.black)
    }
}
