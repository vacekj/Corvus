import AppKit
import CoreImage.CIFilterBuiltins
import CorvusCore
import SwiftUI

/// Links this Mac as a secondary device: runs `signal-cli link -n <name>` and shows the
/// returned URI as a QR code (rendered with Core Image, no qrencode needed).
struct LinkView: View {
    let executable: String
    let onFinish: (Bool) -> Void

    @State private var name = "corvus (\(Host.current().localizedName ?? "Mac"))"
    @State private var uri = ""
    @State private var qrImage: NSImage?        // rendered once per URI
    @State private var status = ""
    @State private var running = false
    @State private var process: Process?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Link device").font(.title2.bold())
            Text("Open Signal on your phone → Settings → Linked devices → “Link new device” and scan the QR code.")
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Text("Device name:")
                TextField("Device name", text: $name).onSubmit { start() }
                Button("Restart") { start() }.disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                    .help("Start again, for example with another device name")
            }
            ZStack {
                RoundedRectangle(cornerRadius: 8).fill(Color.white)
                if let qr = qrImage {
                    Image(nsImage: qr).interpolation(.none).resizable().scaledToFit().padding(12)
                } else if running {
                    ProgressView()
                }
            }
            .frame(width: 260, height: 260)
            .frame(maxWidth: .infinity)
            HStack {
                TextField("Link URI", text: .constant(uri)).textFieldStyle(.roundedBorder)
                Button("Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(uri, forType: .string)
                }
                .disabled(uri.isEmpty)
            }
            Text(status).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Cancel") { cancel() }.keyboardShortcut(.cancelAction)
            }
        }
        .padding(20)
        .frame(width: 460)
        .onChange(of: uri) { qrImage = LinkView.qrImage(uri) }
        .onAppear { if process == nil && uri.isEmpty { start() } } // no extra click: the QR code comes right away
    }

    private static func qrImage(_ uri: String) -> NSImage? {
        guard !uri.isEmpty else { return nil }
        let f = CIFilter.qrCodeGenerator()
        f.message = Data(uri.utf8)
        f.correctionLevel = "M"
        guard let out = f.outputImage?.transformed(by: CGAffineTransform(scaleX: 8, y: 8)),
              let cg = CIContext().createCGImage(out, from: out.extent) else { return nil }
        return NSImage(cgImage: cg, size: out.extent.size)
    }

    private func start() {
        guard !name.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        if let old = process { // a new name: the running link request is replaced
            process = nil
            old.terminate()
        }
        uri = ""
        status = "Waiting for signal-cli …"
        running = true
        let p = Process()
        SignalCli.configure(p, executable: executable,
                            arguments: SignalProxy.arguments(ProxySetting.value) + ["link", "-n", name.trimmingCharacters(in: .whitespaces)])
        p.environment = SignalCli.childEnvironment()
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        p.standardInput = FileHandle.nullDevice
        var buffer = ""
        out.fileHandleForReading.readabilityHandler = { h in
            let d = h.availableData
            if d.isEmpty { h.readabilityHandler = nil; return }
            let s = String(decoding: d, as: UTF8.self)
            Task { @MainActor in
                buffer += s
                for line in buffer.split(separator: "\n") {
                    let t = line.trimmingCharacters(in: .whitespaces)
                    if t.hasPrefix("sgnl://") || t.hasPrefix("tsdevice:") {
                        if uri != t {
                            uri = t
                            status = "Please scan the QR code with your phone …"
                        }
                        break
                    }
                }
            }
        }
        p.terminationHandler = { proc in
            let code = proc.terminationStatus
            let e = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            Task { @MainActor in
                guard process === proc else { return }
                process = nil
                running = false
                if code == 0 {
                    onFinish(true)
                } else {
                    status = "Linking failed (exit code \(code)).\n\(e)"
                }
            }
        }
        do {
            try p.run()
            process = p
        } catch {
            running = false
            status = "signal-cli could not be started: \(error.localizedDescription)"
        }
    }

    private func cancel() {
        if let p = process {
            process = nil
            p.terminate()
        }
        onFinish(false)
    }
}
