import SwiftUI
import UniformTypeIdentifiers
import ReachProtocol

/// Display, quality, clipboard, view and session controls.
struct MoreSheet: View {
    let controller: SessionController
    var onShowGuide: () -> Void = {}

    @Environment(\.dismiss) private var dismiss
    @AppStorage(SettingsKey.showStats) private var alwaysShowStatus = false
    @State private var sendingImage = false

    var body: some View {
        NavigationStack {
            List {
                if controller.displays.count > 1 {
                    Section("Display") {
                        ForEach(controller.displays) { d in
                            Button {
                                controller.selectDisplay(d)
                                Haptics.shared.play(.click)
                                dismiss()
                            } label: {
                                CheckRow(symbol: d.isMain ? "laptopcomputer" : "display", title: d.name,
                                         detail: "\(Int(d.frame.width)) × \(Int(d.frame.height)) pt",
                                         checked: d.id == controller.activeDisplayID)
                            }
                        }
                    }
                }

                Section {
                    ForEach(QualityMode.allCases, id: \.self) { mode in
                        Button {
                            controller.setQualityMode(mode)
                            Haptics.shared.play(.detent)
                        } label: {
                            CheckRow(symbol: mode.symbol, title: mode.title, detail: mode.detail,
                                     checked: controller.quality.mode == mode)
                        }
                    }
                    Picker(selection: Binding(get: { controller.quality.maxFramesPerSecond },
                                              set: { controller.setMaxFramesPerSecond($0) })) {
                        Text("30 fps").tag(30)
                        Text("60 fps").tag(60)
                    } label: {
                        Label("Frame Rate", systemImage: "speedometer")
                    }
                } header: {
                    Text("Quality")
                }

                Section {
                    // PasteButton reads the clipboard without the "Allow Paste" prompt, but its title is
                    // fixed by the system — so the row carries the "Paste to Mac" label.
                    HStack(spacing: 12) {
                        Label("Paste to Mac", systemImage: "arrow.up.doc.on.clipboard")
                        Spacer(minLength: 8)
                        if sendingImage {
                            ProgressView()
                        } else {
                            PasteButton(supportedContentTypes: [.plainText, .image]) { providers in
                                paste(providers)
                            }
                            .labelStyle(.titleAndIcon)
                            .buttonBorderShape(.capsule)
                            .tint(Theme.accent)
                        }
                    }
                } header: {
                    Text("Clipboard")
                } footer: {
                    Text("Paste puts your iPhone’s clipboard on the Mac. Anything you copy on the Mac appears on your iPhone automatically.")
                }

                Section("View") {
                    Button {
                        controller.canvas?.fitToScreen()
                        dismiss()
                    } label: {
                        Label("Fit to Screen", systemImage: "arrow.down.right.and.arrow.up.left")
                    }
                    Toggle(isOn: Binding(get: { controller.statsExpanded }, set: { controller.statsExpanded = $0 })) {
                        Label("Connection Details", systemImage: "chart.bar.xaxis")
                    }
                    .tint(Theme.accent)
                    Toggle(isOn: $alwaysShowStatus) {
                        Label("Always Show Status", systemImage: "antenna.radiowaves.left.and.right")
                    }
                    .tint(Theme.accent)
                    Button {
                        dismiss()
                        onShowGuide()
                    } label: {
                        Label("Gesture Guide", systemImage: "hand.draw")
                    }
                }

                Section {
                    Toggle(isOn: Binding(get: { controller.log.isVisible }, set: { controller.log.isVisible = $0 })) {
                        Label("Input Log", systemImage: "list.bullet.rectangle")
                    }
                    .tint(Theme.accent)
                    if controller.host.isDemo {
                        Button {
                            dismiss()
                            controller.restartTransport()
                        } label: {
                            Label("Simulate Network Drop", systemImage: "wifi.exclamationmark")
                        }
                    }
                } header: {
                    Text("Diagnostics")
                }

                Section {
                    Button(role: .destructive) {
                        dismiss()
                        controller.disconnect()
                    } label: {
                        Label("Disconnect", systemImage: "xmark.circle")
                            .foregroundStyle(Theme.danger)
                    }
                }
            }
            .tint(.white)
            .navigationTitle(controller.host.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    // MARK: Clipboard

    private func paste(_ providers: [NSItemProvider]) {
        guard let provider = providers.first else { return }
        if provider.canLoadObject(ofClass: String.self) {
            _ = provider.loadObject(ofClass: String.self) { text, _ in
                guard let text else { return }
                Task { @MainActor in
                    controller.sendClipboard(text: text, imagePNG: nil)
                    dismiss()
                }
            }
        } else if provider.canLoadObject(ofClass: UIImage.self) {
            sendingImage = true
            _ = provider.loadObject(ofClass: UIImage.self) { object, _ in
                // Encoding happens off the main thread; big photos take a moment.
                let png = (object as? UIImage).flatMap { ClipboardImage.png(fitting: $0, maxBytes: ClipboardImage.maxBytes) }
                Task { @MainActor in
                    sendingImage = false
                    if let png {
                        controller.sendClipboard(text: nil, imagePNG: png)
                        dismiss()
                    } else {
                        controller.showToast(symbol: "exclamationmark.triangle", "That image couldn’t be sent")
                    }
                }
            }
        }
    }
}

/// A row with a leading glyph, title, optional detail and a trailing checkmark.
struct CheckRow: View {
    var symbol: String
    var title: String
    var detail: String?
    var checked: Bool

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: symbol)
                .font(.system(size: 17))
                .foregroundStyle(checked ? Theme.accent : .secondary)
                .frame(width: 26)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).foregroundStyle(.primary)
                if let detail {
                    Text(detail).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 8)
            if checked {
                Image(systemName: "checkmark")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(Theme.accent)
            }
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(checked ? .isSelected : [])
    }
}

/// Clipboard images travel as PNG inside a JSON control message (base64, so ~4/3 the size). WebRTC data
/// channels refuse very large messages, so images are scaled down until the PNG fits a safe budget.
enum ClipboardImage {
    /// Fragmented over ReachCore's bulk channel; base64 on the wire must stay under its 8 MB cap.
    static let maxBytes = 4 * 1024 * 1024

    static func png(fitting image: UIImage, maxBytes: Int) -> Data? {
        var longest = min(max(image.size.width, image.size.height) * image.scale, 2048)
        while longest >= 160 {
            if let data = render(image, longest: longest), data.count <= maxBytes { return data }
            longest *= 0.75
        }
        return nil
    }

    private static func render(_ image: UIImage, longest: CGFloat) -> Data? {
        let pxW = image.size.width * image.scale, pxH = image.size.height * image.scale
        guard pxW > 0, pxH > 0 else { return nil }
        let s = min(1, longest / max(pxW, pxH))
        let size = CGSize(width: (pxW * s).rounded(), height: (pxH * s).rounded())
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: size, format: format).pngData { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }
    }
}
