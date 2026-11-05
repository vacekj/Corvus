import AppKit
import AVKit
import CoreImage
import CorvusCore
import SwiftUI

// MARK: - Stickers

/// Sticker in a bubble (no bubble background, like the official clients).
struct StickerView: View {
    @Environment(AppModel.self) private var model
    let attachment: Attachment
    var size: CGFloat = 160

    var body: some View {
        let k = AppModel.stickerKey(attachment.stickerPackId, attachment.stickerId)
        Group {
            if let data = model.stickerImages[k], NSImage(data: data) != nil {
                AnimatedImage(data: data)
            } else {
                RoundedRectangle(cornerRadius: 12).fill(Theme.field)
                    .overlay(Image(systemName: "face.smiling").font(.system(size: 30)).foregroundStyle(.secondary))
            }
        }
        .frame(width: size, height: size)
        .onAppear { model.loadSticker(packId: attachment.stickerPackId, stickerId: attachment.stickerId) }
        .help("Sticker")
    }
}

struct StickerPicker: View {
    @Environment(AppModel.self) private var model
    let done: () -> Void
    @State private var packIndex = 0

    var body: some View {
        VStack(spacing: 0) {
            if model.stickerPacks.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "face.smiling").font(.system(size: 34)).foregroundStyle(.secondary)
                    Text("No sticker packs installed").font(.headline)
                    Text("Install packs on your phone (they sync to Corvus) or add one from a signal.art link.")
                        .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    Button("Add sticker pack …") { Task { await model.addStickerPack() } }
                }
                .padding(20)
                .frame(width: 320, height: 220)
            } else {
                let pack = model.stickerPacks[min(packIndex, model.stickerPacks.count - 1)]
                HStack {
                    Picker("Pack", selection: $packIndex) {
                        ForEach(Array(model.stickerPacks.enumerated()), id: \.offset) { i, p in
                            Text(p.title.isEmpty ? "Sticker pack" : p.title).tag(i)
                        }
                    }
                    .labelsHidden()
                    Spacer()
                    Button { Task { await model.addStickerPack() } } label: { Image(systemName: "plus") }
                        .buttonStyle(.borderless)
                        .help("Add sticker pack …")
                }
                .padding(10)
                Divider()
                ScrollView {
                    LazyVGrid(columns: Array(repeating: GridItem(.fixed(72), spacing: 8), count: 5), spacing: 8) {
                        ForEach(pack.stickers) { st in
                            Button {
                                model.sendSticker(packId: pack.id, stickerId: st.id)
                                done()
                            } label: {
                                StickerView(attachment: Attachment.sticker(packId: pack.id, stickerId: st.id), size: 72)
                            }
                            .buttonStyle(.plain)
                            .help(st.emoji)
                        }
                    }
                    .padding(10)
                }
                .frame(width: 420, height: 320)
            }
        }
        .onAppear { if model.stickerPacks.isEmpty { model.loadStickerPacks() } }
    }
}

// MARK: - Polls

struct PollView: View {
    @Environment(AppModel.self) private var model
    let message: Message
    let foreground: Color

    var body: some View {
        let poll = message.poll
        let mine = Set(poll.votes[model.account] ?? [])
        let total = max(poll.totalVoters, 1)
        VStack(alignment: .leading, spacing: 8) {
            Label(poll.ended ? "Poll · ended" : (poll.allowMultiple ? "Poll · select one or more" : "Poll"),
                  systemImage: "chart.bar.xaxis")
                .font(.caption.weight(.semibold))
                .opacity(0.8)
            Text(poll.question).font(.system(size: NSFont.systemFontSize + 2, weight: .semibold))
                .fixedSize(horizontal: false, vertical: true)
            ForEach(Array(poll.options.enumerated()), id: \.offset) { i, option in
                let voters = poll.voters(for: i)
                Button { toggle(i, mine: mine) } label: {
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 8) {
                            Image(systemName: mine.contains(i) ? (poll.allowMultiple ? "checkmark.square.fill" : "largecircle.fill.circle")
                                    : (poll.allowMultiple ? "square" : "circle"))
                            Text(option).fixedSize(horizontal: false, vertical: true)
                            Spacer(minLength: 8)
                            Text("\(voters.count)").monospacedDigit().opacity(0.75)
                        }
                        GeometryReader { g in
                            ZStack(alignment: .leading) {
                                Capsule().fill(foreground.opacity(0.15))
                                Capsule().fill(foreground.opacity(0.6))
                                    .frame(width: g.size.width * CGFloat(voters.count) / CGFloat(total))
                            }
                        }
                        .frame(height: 4)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(poll.ended || !model.connected)
                .help(voters.isEmpty ? "No votes" : voters.map(model.displayName).joined(separator: ", "))
            }
            Text(poll.totalVoters == 1 ? "1 vote" : "\(poll.totalVoters) votes").font(.caption).opacity(0.7)
            if message.outgoing && !poll.ended {
                Button("End poll") { model.endPoll(message.id) }
                    .buttonStyle(.link)
                    .font(.caption)
            }
        }
        .foregroundStyle(foreground)
        .frame(width: 300, alignment: .leading)
    }

    private func toggle(_ i: Int, mine: Set<Int>) {
        var chosen = mine
        if message.poll.allowMultiple {
            if chosen.contains(i) { chosen.remove(i) } else { chosen.insert(i) }
        } else {
            chosen = mine.contains(i) ? [] : [i]
        }
        model.votePoll(message.id, options: chosen.sorted())
    }
}

struct PollComposerSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var question = ""
    @State private var options = ["", ""]
    @State private var allowMultiple = false

    var body: some View {
        let valid = !question.trimmingCharacters(in: .whitespaces).isEmpty
            && options.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.count >= 2
        VStack(alignment: .leading, spacing: 12) {
            Text("New poll").font(.title3.weight(.semibold))
            TextField("Question", text: $question).textFieldStyle(.roundedBorder)
            ForEach(options.indices, id: \.self) { i in
                HStack {
                    TextField("Option \(i + 1)", text: $options[i]).textFieldStyle(.roundedBorder)
                    if options.count > 2 {
                        Button { options.remove(at: i) } label: { Image(systemName: "minus.circle") }.buttonStyle(.borderless)
                    }
                }
            }
            if options.count < 10 {
                Button { options.append("") } label: { Label("Add option", systemImage: "plus") }.buttonStyle(.borderless)
            }
            Toggle("Allow multiple answers", isOn: $allowMultiple)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Send") {
                    model.createPoll(question: question, options: options, allowMultiple: allowMultiple)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!valid)
            }
        }
        .padding(20)
        .frame(width: 380)
    }
}

// MARK: - View Once

struct ViewOnceBubbleContent: View {
    @Environment(AppModel.self) private var model
    let message: Message
    let foreground: Color

    var body: some View {
        let isVideo = message.attachments.first?.isVideo == true
        let consumed = message.viewOnceConsumed
        Button { model.openViewOnce(message.id) } label: {
            HStack(spacing: 8) {
                Image(systemName: consumed ? "circle.dashed" : "1.circle")
                    .font(.system(size: 20))
                Text(consumed ? (message.outgoing ? "View once media" : "Viewed") : (isVideo ? "View once video" : "View once photo"))
            }
            .foregroundStyle(foreground)
            .opacity(consumed ? 0.65 : 1)
        }
        .buttonStyle(.plain)
        .disabled(consumed)
        .help(consumed ? "" : "Opens once; afterwards the media is gone")
    }
}

// MARK: - Safety number

struct SafetyNumberSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let key: String
    @State private var info: IdentityInfo?
    @State private var loading = true

    var body: some View {
        let title = model.chats.convs[key]?.title ?? key
        VStack(spacing: 14) {
            Text("Safety number with \(title)").font(.title3.weight(.semibold))
            if loading {
                ProgressView().padding(30)
            } else if let info, !info.safetyNumber.isEmpty {
                if let qr = SafetyNumberSheet.qrImage(info.scannable) {
                    Image(nsImage: qr).interpolation(.none).resizable().frame(width: 180, height: 180)
                        .padding(8).background(Color.white).clipShape(RoundedRectangle(cornerRadius: 8))
                }
                Grid(horizontalSpacing: 14, verticalSpacing: 6) {
                    ForEach(0..<3, id: \.self) { row in
                        GridRow {
                            ForEach(0..<4, id: \.self) { col in
                                let i = row * 4 + col
                                Text(i < info.blocks.count ? info.blocks[i] : "").font(.system(.title3, design: .monospaced))
                            }
                        }
                    }
                }
                .textSelection(.enabled)
                Label(info.isVerified ? "Verified" : (info.trustLevel == "UNTRUSTED" ? "Safety number changed – not trusted" : "Not verified"),
                      systemImage: info.isVerified ? "checkmark.seal.fill" : "exclamationmark.shield")
                    .foregroundStyle(info.isVerified ? .green : .secondary)
                Text("Compare these numbers with \(title), in person or over a trusted channel, or scan the code with their phone. "
                     + "If they match, mark the contact as verified.")
                    .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    if info.isVerified {
                        Button("Clear verification") { Task { if await model.trustKnownKeys(key) { await reload() } } }
                    } else {
                        Button("Mark as verified") { Task { if await model.markVerified(key, info) { await reload() } } }
                            .buttonStyle(.borderedProminent)
                    }
                    Spacer()
                    Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
                }
            } else {
                Text("No safety number is known for this contact yet. Exchange a message first.")
                    .foregroundStyle(.secondary)
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(22)
        .frame(width: 420)
        .task { await reload() }
    }

    private func reload() async {
        loading = info == nil
        info = await model.loadIdentity(key)
        loading = false
    }

    static func qrImage(_ base64: String) -> NSImage? {
        guard let data = Data(base64Encoded: base64), !data.isEmpty, let f = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        f.setValue(data, forKey: "inputMessage")
        f.setValue("M", forKey: "inputCorrectionLevel")
        guard let out = f.outputImage?.transformed(by: CGAffineTransform(scaleX: 8, y: 8)) else { return nil }
        let rep = NSCIImageRep(ciImage: out)
        let img = NSImage(size: rep.size)
        img.addRepresentation(rep)
        return img
    }
}

// MARK: - Forward

struct ForwardSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let messageId: String
    @State private var selected: [String] = []
    @State private var filter = ""

    var body: some View {
        let q = filter.trimmingCharacters(in: .whitespaces)
        let list = (model.chats.sortedConversations(archived: false) + model.chats.sortedConversations(archived: true))
            .filter { q.isEmpty || $0.title.localizedCaseInsensitiveContains(q) }
        VStack(alignment: .leading, spacing: 10) {
            Text("Forward to …").font(.title3.weight(.semibold))
            TextField("Search chats", text: $filter).textFieldStyle(.roundedBorder)
            List(list) { c in
                let on = selected.contains(c.key)
                Button {
                    if on { selected.removeAll { $0 == c.key } } else if selected.count < AppModel.maxForwardTargets { selected.append(c.key) }
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: on ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(on ? Theme.signalBlue : .secondary)
                        AvatarView(image: model.avatarImage(c), size: 28)
                        Text(c.title).lineLimit(1)
                        Spacer()
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(!on && selected.count >= AppModel.maxForwardTargets)
            }
            .frame(height: 300)
            HStack {
                Text("\(selected.count) of \(AppModel.maxForwardTargets) chats").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Forward") {
                    model.forward(messageId: messageId, to: selected)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(selected.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 400)
    }
}

// MARK: - Media gallery

struct MediaGallerySheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var tab = 0

    private struct Item: Identifiable {
        var message: Message
        var index: Int
        var id: String { "\(message.id)#\(index)" }
        var attachment: Attachment { message.attachments[index] }
    }

    private struct LinkItem: Identifiable {
        var url: URL
        var message: Message
        var id: String { message.id + url.absoluteString }
    }

    var body: some View {
        let msgs = model.currentConversation?.msgs.filter { !$0.deleted && !$0.viewOnce } ?? []
        let items = msgs.reversed().flatMap { m in m.attachments.indices.map { Item(message: m, index: $0) } }
            .filter { !$0.attachment.isSticker }
        let media = items.filter { $0.attachment.isImage || $0.attachment.isVideo }
        let audio = items.filter { $0.attachment.isAudio }
        let files = items.filter { !$0.attachment.isImage && !$0.attachment.isVideo && !$0.attachment.isAudio }
        let links = msgs.reversed().flatMap { m in MediaGallerySheet.links(in: m.text).map { LinkItem(url: $0, message: m) } }

        VStack(spacing: 0) {
            HStack {
                Picker("", selection: $tab) {
                    Text("Media (\(media.count))").tag(0)
                    Text("Audio (\(audio.count))").tag(1)
                    Text("Files (\(files.count))").tag(2)
                    Text("Links (\(links.count))").tag(3)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding(12)
            Divider()
            ScrollView {
                switch tab {
                case 0:
                    LazyVGrid(columns: Array(repeating: GridItem(.fixed(120), spacing: 6), count: 5), spacing: 6) {
                        ForEach(media) { it in
                            Button { model.openAttachment(it.message, it.index) } label: { tile(it.attachment) }
                                .buttonStyle(.plain)
                                .help(it.message.time.formatted())
                        }
                    }
                    .padding(12)
                case 1, 2:
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(tab == 1 ? audio : files) { it in
                            HStack(spacing: 10) {
                                Image(systemName: tab == 1 ? "waveform" : "doc.fill").frame(width: 28)
                                VStack(alignment: .leading) {
                                    Text(it.attachment.filename.isEmpty ? "Attachment" : it.attachment.filename).lineLimit(1)
                                    Text([it.message.time.formatted(date: .abbreviated, time: .shortened),
                                          it.attachment.size > 0 ? Media.humanSize(it.attachment.size) : ""]
                                            .filter { !$0.isEmpty }.joined(separator: " · "))
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Button { model.openAttachment(it.message, it.index) } label: {
                                    Image(systemName: tab == 1 ? "play.circle" : "arrow.up.forward.square")
                                }
                                .buttonStyle(.borderless)
                                Button { model.saveAttachment(it.message, it.index) } label: { Image(systemName: "square.and.arrow.down") }
                                    .buttonStyle(.borderless)
                            }
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                            Divider()
                        }
                    }
                default:
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(links) { l in
                            HStack {
                                Image(systemName: "link").frame(width: 28)
                                VStack(alignment: .leading) {
                                    Link(l.url.absoluteString, destination: l.url).lineLimit(1)
                                    Text(l.message.time.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                            }
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                            Divider()
                        }
                    }
                }
                if [media.count, audio.count, files.count, links.count][tab] == 0 {
                    Text("Nothing here yet").foregroundStyle(.secondary).padding(40)
                }
            }
        }
        .frame(width: 680, height: 520)
    }

    @ViewBuilder
    private func tile(_ a: Attachment) -> some View {
        ZStack {
            if let img = NSImage(data: a.thumb) {
                Image(nsImage: img).resizable().aspectRatio(contentMode: .fill)
            } else {
                Rectangle().fill(Theme.field)
                Image(systemName: a.isVideo ? "film" : "photo").font(.title2).foregroundStyle(.secondary)
            }
            if a.isVideo {
                Image(systemName: "play.circle.fill").font(.system(size: 28)).foregroundStyle(.white).shadow(radius: 3)
            }
        }
        .frame(width: 120, height: 120)
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private static let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)

    static func links(in text: String) -> [URL] {
        guard !text.isEmpty, let detector else { return [] }
        return detector.matches(in: text, range: NSRange(location: 0, length: (text as NSString).length)).compactMap { m in
            guard let u = m.url, ["http", "https"].contains(u.scheme?.lowercased() ?? "") else { return nil }
            return u
        }
    }
}

// MARK: - Stories

struct StoriesSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var openId: String?
    @State private var allowReplies = true

    var body: some View {
        let stories = model.activeStories
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text("Stories").font(.title3.weight(.semibold))
                    Spacer()
                    Menu {
                        Button("My Story …") { post(group: nil) }
                        let groups = model.chats.convs.values.filter(\.isGroup).sorted { $0.title < $1.title }
                        if !groups.isEmpty {
                            Divider()
                            ForEach(groups) { g in Button("\(g.title) …") { post(group: g.key) } }
                        }
                        Divider()
                        Toggle("Allow replies", isOn: $allowReplies)
                    } label: { Label("New story", systemImage: "plus.circle") }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .disabled(!model.connected)
                }
                .padding(12)
                Divider()
                List(stories, selection: $openId) { st in
                    HStack(spacing: 10) {
                        Circle().strokeBorder(st.viewed || st.outgoing ? Color.secondary.opacity(0.4) : Theme.signalBlue, lineWidth: 2.5)
                            .frame(width: 34, height: 34)
                            .overlay(Image(systemName: st.attachment?.isVideo == true ? "film" : (st.attachment == nil ? "textformat" : "photo"))
                                        .font(.caption))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(model.storyTitle(st)).fontWeight(st.viewed ? .regular : .semibold).lineLimit(1)
                            Text(st.time.formatted(.relative(presentation: .named))).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .tag(st.id)
                }
                .listStyle(.sidebar)
                if stories.isEmpty {
                    Text("No stories in the last 24 hours.\nStories received while Corvus is running appear here.")
                        .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center).padding()
                }
            }
            .frame(width: 250)
            Divider()
            ZStack(alignment: .topTrailing) {
                if let id = openId, let st = stories.first(where: { $0.id == id }) {
                    StoryViewer(story: st).id(st.id)
                } else {
                    Text("Choose a story").foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction).padding(10)
            }
        }
        .frame(width: 760, height: 560)
        .onChange(of: openId) { _, id in if let id { model.markStoryViewed(id) } }
    }

    private func post(group: String?) {
        guard let f = model.chooseStoryFile() else { return }
        model.postStory(file: f, groupKey: group, allowReplies: allowReplies)
    }
}

private struct StoryViewer: View {
    @Environment(AppModel.self) private var model
    let story: Story
    @State private var data: Data?
    @State private var videoURL: URL?
    @State private var error = ""
    @State private var reply = ""

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                Color.black
                if let a = story.attachment {
                    if a.isVideo, let videoURL {
                        VideoPlayer(player: AVPlayer(url: videoURL))
                    } else if let data, let img = NSImage(data: data) {
                        Image(nsImage: img).resizable().aspectRatio(contentMode: .fit)
                    } else if !error.isEmpty {
                        Text(error).foregroundStyle(.white.opacity(0.7)).padding()
                    } else {
                        ProgressView().colorScheme(.dark)
                    }
                } else {
                    TextStory(story: story)
                }
            }
            if !story.outgoing && story.allowsReplies {
                HStack(spacing: 6) {
                    ForEach(EmojiCatalog.quickReactions.prefix(6), id: \.self) { e in
                        Button(e) { model.reactToStory(story, emoji: e) }.buttonStyle(.borderless)
                    }
                    TextField("Reply …", text: $reply)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { send() }
                    Button("Send") { send() }.disabled(reply.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                .padding(10)
                .disabled(!model.connected)
            } else {
                Text(story.outgoing ? "Your story" : "Replies are turned off for this story")
                    .font(.caption).foregroundStyle(.secondary).padding(10)
            }
        }
        .task { await load() }
    }

    private func send() {
        model.replyToStory(story, text: reply)
        reply = ""
    }

    private func load() async {
        guard let a = story.attachment else { return }
        do {
            let d = try await model.fetchStoryMedia(story)
            guard !d.isEmpty else { throw RpcError("The story media is empty.") }
            if a.isVideo {
                let suffix = AttachmentPolicy.mediaSuffix(filename: a.filename, contentType: a.contentType, fallback: "mp4")
                videoURL = try Media.writeAttachmentTemp(d, name: "story." + suffix)
            } else {
                data = d
            }
        } catch {
            self.error = "The story could not be loaded: \(error.localizedDescription)"
        }
    }
}

private struct TextStory: View {
    let story: Story

    var body: some View {
        ZStack {
            if story.gradient.count >= 2 {
                LinearGradient(colors: story.gradient.map { Color(hexARGB: $0) ?? .gray }, startPoint: .top, endPoint: .bottom)
            } else {
                Color(hexARGB: story.backgroundColor) ?? Color(red: 0.2, green: 0.3, blue: 0.6)
            }
            VStack(spacing: 10) {
                Text(story.text).font(.system(size: 28, weight: .semibold)).multilineTextAlignment(.center)
                    .foregroundStyle(Color(hexARGB: story.textColor) ?? .white)
                if let u = URL(string: story.previewUrl), !story.previewUrl.isEmpty { Link(story.previewUrl, destination: u) }
            }
            .padding(30)
        }
    }
}

extension Color {
    /// "#AARRGGBB", "#RRGGBB", "AARRGGBB" or a decimal ARGB integer.
    init?(hexARGB s: String) {
        var t = s.trimmingCharacters(in: .whitespaces)
        if t.hasPrefix("#") { t.removeFirst() }
        var v: UInt64 = 0
        if t.count == 6 || t.count == 8, let x = UInt64(t, radix: 16) {
            v = t.count == 6 ? (0xFF00_0000 | x) : x
        } else if let d = Int64(t) {
            v = UInt64(bitPattern: d) & 0xFFFF_FFFF
        } else {
            return nil
        }
        self.init(.sRGB, red: Double((v >> 16) & 0xFF) / 255, green: Double((v >> 8) & 0xFF) / 255,
                  blue: Double(v & 0xFF) / 255, opacity: Double((v >> 24) & 0xFF) / 255)
    }
}

// MARK: - Voice message recording

struct RecordingBar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 12) {
            Circle().fill(.red).frame(width: 10, height: 10)
            TimelineView(.periodic(from: .now, by: 0.5)) { ctx in
                let t = Int(ctx.date.timeIntervalSince(model.recordingStarted ?? ctx.date))
                Text(String(format: "%d:%02d", t / 60, t % 60)).monospacedDigit()
            }
            Text("Recording voice message …").foregroundStyle(.secondary)
            Spacer()
            Button("Cancel") { model.stopRecording(send: false) }
            Button { model.stopRecording(send: true) } label: {
                Image(systemName: "arrow.up").font(.system(size: 15, weight: .bold)).foregroundStyle(.white)
                    .frame(width: 32, height: 32).background(Circle().fill(Theme.signalBlue))
            }
            .buttonStyle(.borderless)
            .help("Send voice message")
        }
        .padding(.horizontal, 10)
        .frame(height: 40)
        .background(RoundedRectangle(cornerRadius: 17, style: .continuous).fill(Theme.field))
    }
}
