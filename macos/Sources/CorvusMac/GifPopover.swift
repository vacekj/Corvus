import AppKit
import SwiftUI

/// Content of the GIF button's popover: the GIPHY picker, or (without an API key) a field to enter one.
struct GifPopover: View {
    @Environment(AppModel.self) private var model
    let done: () -> Void
    @State private var key: String?
    @State private var loadError: String?
    @State private var editingKey = false

    var body: some View {
        Group {
            if let key, !key.isEmpty, !editingKey {
                GiphyPicker(apiKey: key, onSelect: { url, analytics in
                    done()
                    model.sendGif(url: url, analytics: analytics)
                }, onChangeKey: { editingKey = true })
            } else {
                GiphyKeyForm(initial: key ?? "", loadError: loadError) { saved in
                    key = saved
                    editingKey = false
                }
                .padding(16)
                .frame(width: 340)
            }
        }
        .onAppear {
            do { key = try model.loadGiphyApiKey() } catch { key = ""; loadError = error.localizedDescription }
        }
    }
}

/// GIPHY API key field with a link to get one; used by the GIF popover and Settings.
struct GiphyKeyForm: View {
    @Environment(AppModel.self) private var model
    var initial = ""
    var loadError: String?
    var compact = false
    let saved: (String) -> Void
    @State private var text = ""
    @State private var error: String?
    @State private var loaded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !compact {
                Text("GIPHY API key").font(.headline)
                Text("GIF search needs a free API key from GIPHY.").font(.callout).foregroundStyle(.secondary)
            }
            HStack {
                SecureField("API key", text: $text)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(save)
                Button(compact && text.isEmpty && !initial.isEmpty ? "Remove" : "Save", action: save)
                    .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines) == initial && !text.isEmpty
                              || (text.isEmpty && initial.isEmpty))
            }
            HStack {
                Link("Get a key", destination: AppModel.giphyDashboard)
                Spacer()
                if let e = error ?? loadError { Text(e).foregroundStyle(.red).lineLimit(2) }
            }
            .font(.caption)
        }
        .onAppear {
            if !loaded { text = initial; loaded = true }
        }
    }

    private func save() {
        let k = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let e = model.saveGiphyApiKey(k) {
            error = e
        } else {
            error = nil
            saved(k)
        }
    }
}
