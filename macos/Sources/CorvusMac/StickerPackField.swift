import AppKit
import CorvusCore
import SwiftUI

/// Inline "add sticker pack" field of the sticker picker. A signal.art link on the clipboard is filled in,
/// and a pasted text is reduced to the link it contains.
struct AddStickerPackField: View {
    @Environment(AppModel.self) private var model
    let finished: () -> Void
    @State private var text = ""
    @State private var error: String?
    @State private var busy = false
    @FocusState private var focused: Bool

    var body: some View {
        let link = StickerPackLink.find(in: text)
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                TextField("Paste a signal.art sticker link", text: $text)
                    .textFieldStyle(.roundedBorder)
                    .focused($focused)
                    .onSubmit { if let link { add(link) } }
                    .onChange(of: text) { _, new in
                        error = nil
                        // A pasted message: keep just the link.
                        if let l = StickerPackLink.find(in: new), StickerPackLink.parse(new) == nil { text = l.uri }
                    }
                    .disabled(busy)
                if busy {
                    ProgressView().controlSize(.small)
                } else {
                    Button("Add") { if let link { add(link) } }
                        .disabled(link == nil || !model.connected)
                }
            }
            if let error {
                Text(error).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            } else if !text.isEmpty && link == nil {
                Text("Not a Signal sticker pack link (https://signal.art/addstickers/#pack_id=…&pack_key=…).")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(minWidth: 300)
        .onAppear {
            if let s = NSPasteboard.general.string(forType: .string), let l = StickerPackLink.find(in: s) { text = l.uri }
            focused = true
        }
    }

    private func add(_ link: StickerPackLink) {
        busy = true
        Task {
            let e = await model.addStickerPack(link)
            busy = false
            if let e { error = e } else { text = ""; finished() }
        }
    }
}
