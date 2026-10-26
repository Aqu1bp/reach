import AppKit
import SwiftUI

/// The QR code, its expiry countdown, and Copy / New Code actions.
struct PairingCodePanel: View {
    let pairing: PairingSession
    var qrSize: CGFloat = 200
    @State private var copied = false

    var body: some View {
        VStack(spacing: 10) {
            QRTile(code: code, size: qrSize)
            if let code {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Text("Expires in \(Formatting.countdown(code.expiresAt.timeIntervalSince(context.date)))")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                HStack(spacing: 8) {
                    Button {
                        copy(code.link)
                    } label: {
                        Label(copied ? "Copied" : "Copy Code", systemImage: copied ? "checkmark" : "doc.on.doc")
                    }
                    .help("Copy the pairing link to paste into Reach on your iPhone (via Universal Clipboard).")
                    Button {
                        pairing.refresh()
                    } label: {
                        Label("New Code", systemImage: "arrow.clockwise")
                    }
                    .help("Replace this code with a new one.")
                }
                .controlSize(.small)
                .labelStyle(.titleAndIcon)
            }
        }
    }

    private var code: PairingSession.Code? {
        if case .showing(let code) = pairing.state { return code }
        return nil
    }

    private func copy(_ link: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(link, forType: .string)
        copied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { copied = false }
    }
}

/// A white tile holding the QR code, scaled by whole device pixels per module so it stays sharp.
struct QRTile: View {
    let code: PairingSession.Code?
    let size: CGFloat
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(.white)
                .shadow(color: .black.opacity(0.10), radius: 6, y: 2)
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.black.opacity(0.08), lineWidth: 0.5)
            if let code, let image = scaledImage(code.qr) {
                Image(image, scale: displayScale, label: Text("Pairing code"))
                    .interpolation(.none)
            } else {
                ProgressView()
                    .controlSize(.small)
            }
        }
        .frame(width: size, height: size)
    }

    private static let inset: CGFloat = 12

    /// The QR code at a whole number of device pixels per module, as large as fits the tile.
    private func scaledImage(_ qr: CGImage) -> CGImage? {
        let side = Self.pixelExactSide(modules: qr.width, target: size - 2 * Self.inset, scale: displayScale)
        let factor = Int((side * displayScale / CGFloat(qr.width)).rounded())
        return QRCodeRenderer.scaled(qr, by: factor)
    }

    /// The largest side ≤ `target` points at which every module covers a whole number of pixels.
    static func pixelExactSide(modules: Int, target: CGFloat, scale: CGFloat) -> CGFloat {
        guard modules > 0, scale > 0 else { return target }
        let pixelsPerModule = max(1, floor(target * scale / CGFloat(modules)))
        return pixelsPerModule * CGFloat(modules) / scale
    }
}
