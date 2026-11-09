import AppKit
import CorvusCore
import SwiftUI

/// Creating and uploading a sticker pack (`uploadStickerPack <manifest.json>`), like Signal Desktop's sticker
/// pack creator. The images are converted in CorvusCore (StickerImageConverter); the pack directory lives in the
/// temporary directory only while signal-cli uploads it.
extension AppModel {
    /// Writes the pack, uploads it and removes the files again. Returns the pack's link or the error text.
    func uploadStickerPack(_ manifest: StickerManifest, images: [String: Data]) async -> Result<StickerPackLink, StickerUploadError> {
        let dir = AppPaths.tempDir.appendingPathComponent("stickerpack-" + UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let manifestURL = dir.appendingPathComponent("manifest.json")
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            for (name, data) in images where !name.contains("/") && !name.contains("..") {
                try data.write(to: dir.appendingPathComponent(name))
            }
            try manifest.data().write(to: manifestURL)
        } catch {
            return .failure(StickerUploadError(text: "Could not prepare the pack: \(error.localizedDescription)"))
        }
        let result: Any
        do { result = try await cli.call("uploadStickerPack", ["path": manifestURL.path]) } catch {
            return .failure(StickerUploadError(text: "Could not upload the pack: \(error.localizedDescription)"))
        }
        guard let link = StickerUploadResult.link(result) else {
            return .failure(StickerUploadError(text: "signal-cli did not report the link of the uploaded pack."))
        }
        return .success(link)
    }
}

struct StickerUploadError: Error {
    let text: String
}

struct StickerPackCreatorSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    struct Item: Identifiable {
        let id = UUID()
        let name: String            // original file name
        var png: Data?
        var animated = false
        var emoji = ""
        var error: String?
        var thumbnail: NSImage?
    }

    @State private var items: [Item] = []
    @State private var cover: UUID?
    @State private var title = ""
    @State private var author = ""
    @State private var busy = false
    @State private var error: String?
    @State private var link: StickerPackLink?
    @State private var installed = false
    @State private var emojiFor: UUID?

    private let columns = Array(repeating: GridItem(.fixed(96), spacing: 10), count: 5)

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Create sticker pack").font(.title3.weight(.semibold))
            if let link {
                done(link)
            } else {
                editor
            }
        }
        .padding(20)
        .frame(width: 600)
    }

    // MARK: Editor

    private var ready: [Item] { items.filter { $0.png != nil } }

    private var manifest: StickerManifest {
        let stickers = ready.enumerated().map { i, it in StickerDraft(file: "\(i).png", emoji: it.emoji, animated: it.animated) }
        let coverIndex = ready.firstIndex { $0.id == cover } ?? 0
        return StickerManifest(title: title, author: author, stickers: stickers, cover: coverIndex)
    }

    @ViewBuilder
    private var editor: some View {
        ScrollView {
            LazyVGrid(columns: columns, alignment: .leading, spacing: 10) {
                ForEach(items) { tile($0) }
                if items.count < StickerRules.maxStickers {
                    Button(action: pick) {
                        VStack(spacing: 4) {
                            Image(systemName: "plus").font(.title2)
                            Text("Add stickers").font(.caption)
                        }
                        .frame(width: 96, height: 96)
                        .background(RoundedRectangle(cornerRadius: 10).strokeBorder(.secondary.opacity(0.5), style: StrokeStyle(lineWidth: 1, dash: [5, 4])))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(busy)
                }
            }
            .padding(2)
        }
        .frame(height: 260)
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            for p in providers {
                _ = p.loadObject(ofClass: URL.self) { url, _ in
                    guard let url else { return }
                    Task { @MainActor in add([url]) }
                }
            }
            return true
        }
        Text("Click a sticker to choose its emoji. The star marks the cover.")
            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        TextField("Title", text: $title).textFieldStyle(.roundedBorder)
        TextField("Author", text: $author).textFieldStyle(.roundedBorder)
        let problem = items.contains { $0.png == nil && $0.error == nil } ? "Converting …" : manifest.problem
        if let error { InlineError(text: error) }
        HStack {
            if let problem, !items.isEmpty || !title.isEmpty { Text(problem).font(.caption).foregroundStyle(.secondary) }
            if busy { ProgressView().controlSize(.small) }
            Spacer()
            Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
            Button("Upload …", action: upload)
                .keyboardShortcut(.defaultAction)
                .disabled(problem != nil || busy || !model.connected)
        }
    }

    private func tile(_ it: Item) -> some View {
        ZStack(alignment: .topTrailing) {
            Button { if it.png != nil { emojiFor = it.id } } label: {
                ZStack(alignment: .bottomLeading) {
                    Group {
                        if let t = it.thumbnail {
                            Image(nsImage: t).resizable().interpolation(.high).scaledToFit()
                        } else if let e = it.error {
                            Image(systemName: "exclamationmark.triangle").font(.title2).foregroundStyle(.orange).help(e)
                        } else {
                            ProgressView().controlSize(.small)
                        }
                    }
                    .frame(width: 96, height: 96)
                    Text(it.emoji.isEmpty ? "＋😀" : it.emoji)
                        .font(it.emoji.isEmpty ? .caption2 : .title3)
                        .padding(3)
                        .background(Capsule().fill(.background.opacity(0.85)))
                        .opacity(it.png == nil ? 0 : 1)
                }
                .background(RoundedRectangle(cornerRadius: 10).fill(Color.secondary.opacity(0.08)))
                .overlay(RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(it.emoji.isEmpty && it.png != nil ? Color.orange.opacity(0.7) : .clear, lineWidth: 1.5))
            }
            .buttonStyle(.plain)
            .help(it.error ?? (it.emoji.isEmpty ? "Choose an emoji for this sticker" : it.name))
            .popover(isPresented: Binding(get: { emojiFor == it.id }, set: { if !$0 { emojiFor = nil } })) {
                EmojiPicker { e in
                    if let i = items.firstIndex(where: { $0.id == it.id }) { items[i].emoji = e }
                    emojiFor = nil
                }
                .padding(8)
                .frame(width: 340)
            }
            VStack(spacing: 2) {
                Button { items.removeAll { $0.id == it.id }; if cover == it.id { cover = nil } } label: {
                    Image(systemName: "xmark.circle.fill").symbolRenderingMode(.hierarchical)
                }
                .help("Remove")
                if it.png != nil {
                    let isCover = (cover ?? ready.first?.id) == it.id
                    Button { cover = it.id } label: {
                        Image(systemName: isCover ? "star.fill" : "star").foregroundStyle(isCover ? .yellow : .secondary)
                    }
                    .help(isCover ? "Cover" : "Use as cover")
                }
            }
            .buttonStyle(.borderless)
            .padding(3)
            .disabled(busy)
        }
    }

    private func pick() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = StickerRules.inputTypes
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        add(panel.urls)
    }

    private func add(_ urls: [URL]) {
        for url in urls {
            guard items.count < StickerRules.maxStickers else { break }
            let item = Item(name: url.lastPathComponent)
            items.append(item)
            let id = item.id
            Task {
                let r: Result<StickerImageConverter.Output, Error> = await Task.detached(priority: .userInitiated) {
                    do {
                        return .success(try StickerImageConverter.convert(try Data(contentsOf: url)))
                    } catch {
                        return .failure(error)
                    }
                }.value
                guard let i = items.firstIndex(where: { $0.id == id }) else { return }
                switch r {
                case .success(let out):
                    items[i].png = out.data
                    items[i].animated = out.animated
                    items[i].thumbnail = NSImage(data: out.data)
                case .failure(let e):
                    items[i].error = "\(url.lastPathComponent): \(e.localizedDescription)"
                }
            }
        }
    }

    private func upload() {
        let m = manifest
        guard m.problem == nil else { return }
        var images: [String: Data] = [:]
        for (s, it) in zip(m.stickers, ready) { images[s.file] = it.png }
        Task {
            guard await Dialogs.confirm("Upload sticker pack?",
                                        "Anyone with the link can see and install the pack. Stickers cannot be changed or deleted after uploading.",
                                        ok: "Upload") else { return }
            busy = true
            error = nil
            let r = await model.uploadStickerPack(m, images: images)
            busy = false
            switch r {
            case .success(let l): link = l
            case .failure(let e): error = e.text
            }
        }
    }

    // MARK: Done

    @ViewBuilder
    private func done(_ link: StickerPackLink) -> some View {
        Label("Your sticker pack is uploaded.", systemImage: "checkmark.circle.fill")
            .foregroundStyle(.green)
        Text(link.uri).font(.caption.monospaced()).lineLimit(3).textSelection(.enabled)
        if let error { InlineError(text: error) }
        HStack {
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(link.uri, forType: .string)
                model.showFlash("Sticker pack link copied.", seconds: 3)
            } label: { Label("Copy link", systemImage: "doc.on.doc") }
            Button {
                busy = true
                Task {
                    error = await model.addStickerPack(link)
                    installed = error == nil
                    busy = false
                }
            } label: { Label(installed ? "Installed" : "Install", systemImage: installed ? "checkmark" : "square.and.arrow.down") }
                .disabled(installed || busy || !model.connected)
            if busy { ProgressView().controlSize(.small) }
            Spacer()
            Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
        }
    }
}
