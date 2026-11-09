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
                VoiceNoteView(message: message, index: index, attachment: att, foreground: foreground)
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
        let kind = FileKind.of(filename: attachment.filename, contentType: attachment.contentType)
        Button(action: open) {
            HStack(spacing: 10) {
                FileKindIcon(kind: kind)
                VStack(alignment: .leading, spacing: 1) {
                    Text(attachment.filename.isEmpty ? "Attachment" : attachment.filename)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(FileKind.detail(filename: attachment.filename, contentType: attachment.contentType, size: attachment.size))
                        .font(.caption)
                        .opacity(0.75)
                }
            }
            .foregroundStyle(foreground)
            .padding(.vertical, 2)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Open or save …")
    }
}

/// A document-shaped icon per kind of file (PDF, archive, audio, …), coloured like the file type.
struct FileKindIcon: View {
    let kind: FileKind

    var body: some View {
        let (symbol, color) = FileKindIcon.style(kind)
        ZStack {
            RoundedRectangle(cornerRadius: 7, style: .continuous).fill(color)
            Image(systemName: symbol)
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(.white)
        }
        .frame(width: 36, height: 40)
    }

    static func style(_ kind: FileKind) -> (String, Color) {
        switch kind {
        case .pdf: return ("doc.richtext.fill", Color(red: 0.86, green: 0.24, blue: 0.20))
        case .archive: return ("doc.zipper", Color(red: 0.55, green: 0.45, blue: 0.33))
        case .audio: return ("waveform", Color(red: 0.93, green: 0.36, blue: 0.47))
        case .video: return ("film.fill", Color(red: 0.49, green: 0.34, blue: 0.84))
        case .image: return ("photo.fill", Color(red: 0.16, green: 0.62, blue: 0.56))
        case .code: return ("chevron.left.forwardslash.chevron.right", Color(red: 0.30, green: 0.36, blue: 0.45))
        case .text: return ("doc.plaintext.fill", Color(red: 0.45, green: 0.50, blue: 0.56))
        case .document: return ("doc.text.fill", Color(red: 0.17, green: 0.42, blue: 0.82))
        case .spreadsheet: return ("tablecells.fill", Color(red: 0.13, green: 0.55, blue: 0.29))
        case .presentation: return ("play.rectangle.fill", Color(red: 0.90, green: 0.47, blue: 0.13))
        case .generic: return ("doc.fill", Color(red: 0.52, green: 0.55, blue: 0.60))
        }
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
