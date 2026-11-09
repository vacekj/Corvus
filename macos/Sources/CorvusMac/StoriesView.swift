import AppKit
import AVKit
import CorvusCore
import SwiftUI

// MARK: - Stories

/// Story list and viewer. ←/→ go to the previous/next story, Esc closes; photos and text stories advance
/// after a few seconds, videos when they end; pointing at the story pauses it.
struct StoriesSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var openId: String?
    @State private var allowReplies = true

    var body: some View {
        let stories = model.activeStories
        let model = model, open = $openId // for the key handler, which runs outside of body
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
                Divider()
                HStack {
                    Text("← → to switch stories").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
                }
                .padding(10)
            }
            .frame(width: 250)
            Divider()
            Group {
                if let id = openId, let st = stories.first(where: { $0.id == id }) {
                    StoryViewer(story: st) { Self.step(1, model, open) }.id(st.id)
                } else {
                    Text("Choose a story").foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .frame(minWidth: 700, idealWidth: 760, minHeight: 480, idealHeight: 560)
        .onChange(of: openId) { _, id in if let id { model.markStoryViewed(id) } }
        .onAppear { if openId == nil { openId = stories.first(where: { !$0.viewed && !$0.outgoing })?.id ?? stories.first?.id } }
        .onLocalKeyDown(overrideTextFields: false) { e in
            guard e.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty else { return false }
            switch e.keyCode {
            case KeyCode.leftArrow: Self.step(-1, model, open); return true
            case KeyCode.rightArrow: Self.step(1, model, open); return true
            default: return false
            }
        }
    }

    /// Moves to the neighbouring story (stays at the ends); the list is read anew on every key press.
    private static func step(_ d: Int, _ model: AppModel, _ open: Binding<String?>) {
        let ids = model.activeStories.map(\.id)
        guard !ids.isEmpty else { return }
        guard let id = open.wrappedValue, let i = ids.firstIndex(of: id) else { open.wrappedValue = ids.first; return }
        if ids.indices.contains(i + d) { open.wrappedValue = ids[i + d] }
    }

    private func post(group: String?) {
        guard let f = model.chooseStoryFile() else { return }
        model.postStory(file: f, groupKey: group, allowReplies: allowReplies)
    }
}

private struct StoryViewer: View {
    @Environment(AppModel.self) private var model
    let story: Story
    let finished: () -> Void
    @State private var data: Data?
    @State private var player: AVPlayer?
    @State private var error = ""
    @State private var reply = ""
    @State private var hovering = false
    @State private var elapsed: Double = 0
    @FocusState private var replyFocused: Bool

    static let stillSeconds: Double = 5

    private var paused: Bool { hovering || replyFocused || !reply.isEmpty }
    private var loaded: Bool { story.attachment == nil || data != nil || player != nil || !error.isEmpty }

    var body: some View {
        VStack(spacing: 0) {
            ZStack(alignment: .top) {
                Color.black
                if let a = story.attachment {
                    if a.isVideo, let player {
                        VideoPlayer(player: player)
                    } else if let data, let img = NSImage(data: data) {
                        Image(nsImage: img).resizable().aspectRatio(contentMode: .fit)
                    } else if !error.isEmpty {
                        Text(error).foregroundStyle(.white.opacity(0.7)).padding().frame(maxHeight: .infinity)
                    } else {
                        ProgressView().colorScheme(.dark).frame(maxHeight: .infinity)
                    }
                } else {
                    TextStory(story: story)
                }
                if player == nil {
                    // Time left for photos and text stories.
                    ProgressView(value: min(1, elapsed / Self.stillSeconds))
                        .progressViewStyle(.linear)
                        .tint(.white)
                        .padding(.horizontal, 10)
                        .padding(.top, 8)
                        .opacity(loaded ? 1 : 0)
                }
                if paused && hovering {
                    Image(systemName: "pause.fill").font(.system(size: 13)).foregroundStyle(.white.opacity(0.8))
                        .padding(8).background(Circle().fill(.black.opacity(0.4)))
                        .padding(.top, 20)
                }
            }
            .onHover { hovering = $0 }
            if !story.outgoing && story.allowsReplies {
                HStack(spacing: 6) {
                    ForEach(EmojiCatalog.quickReactions.prefix(6), id: \.self) { e in
                        Button(e) { model.reactToStory(story, emoji: e) }.buttonStyle(.borderless)
                    }
                    TextField("Reply …", text: $reply)
                        .textFieldStyle(.roundedBorder)
                        .focused($replyFocused)
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
        .task { await runTimer() }
        .onChange(of: paused) { _, p in if p { player?.pause() } else { player?.play() } }
        .onReceive(NotificationCenter.default.publisher(for: .AVPlayerItemDidPlayToEndTime)) { n in
            if let item = n.object as? AVPlayerItem, item === player?.currentItem { finished() }
        }
        .onDisappear { player?.pause() }
    }

    /// Photos and text stories move on after `stillSeconds` of (unpaused) viewing.
    private func runTimer() async {
        while !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(50))
            guard loaded, player == nil, !paused else { continue }
            elapsed += 0.05
            if elapsed >= Self.stillSeconds {
                finished()
                return
            }
        }
    }

    private func send() {
        model.replyToStory(story, text: reply)
        reply = ""
        replyFocused = false
    }

    private func load() async {
        guard let a = story.attachment else { return }
        do {
            let d = try await model.fetchStoryMedia(story)
            guard !d.isEmpty else { throw RpcError("The story media is empty.") }
            if a.isVideo {
                let suffix = AttachmentPolicy.mediaSuffix(filename: a.filename, contentType: a.contentType, fallback: "mp4")
                let p = AVPlayer(url: try Media.writeAttachmentTemp(d, name: "story." + suffix))
                player = p
                if !paused { p.play() }
            } else {
                data = d
            }
        } catch {
            self.error = "The story could not be loaded: \(error.localizedDescription)"
        }
    }
}
