import SwiftUI

enum ImportProgress: Equatable {
    case running
    case finished(String)
    case failed(String)
}

/// Progress and result of "Import from Signal Desktop".
struct ImportProgressSheet: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let state = model.importProgress ?? .running
        VStack(alignment: .leading, spacing: 14) {
            Text("Import from Signal Desktop").font(.title3.weight(.semibold))
            switch state {
            case .running:
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text("Importing the Signal Desktop history …")
                }
                ProgressView().progressViewStyle(.linear)
                Text("This can take a few minutes for a long history.").font(.caption).foregroundStyle(.secondary)
            case .finished(let summary):
                Label("Import finished", systemImage: "checkmark.circle.fill").foregroundStyle(.green).font(.headline)
                Text(summary).fixedSize(horizontal: false, vertical: true)
            case .failed(let error):
                Label("Import failed", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red).font(.headline)
                Text(error).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button("Done") { model.importProgress = nil }
                    .keyboardShortcut(.defaultAction)
                    .disabled(state == .running)
            }
        }
        .padding(20)
        .frame(width: 420)
        .interactiveDismissDisabled(state == .running)
    }
}
