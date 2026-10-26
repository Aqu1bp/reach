import AppKit
import SwiftUI

/// `--render-snapshots <dir>`: renders each UI state, light and dark, to PNGs for review.
///
/// Rendering goes through an offscreen `NSHostingView` (`cacheDisplay`) rather than only
/// `ImageRenderer`, because `ImageRenderer` can't draw AppKit-backed controls (buttons, switches)
/// and leaves placeholders where they would be. Pass `--image-renderer` to compare.
@MainActor
enum SnapshotRenderer {
    private struct Snapshot {
        let name: String
        let background: NSColor
        let view: AnyView
        /// Windows have a transparent title bar above their content; reproduce its band.
        var titleBarHeight: CGFloat = 0
    }

    private static let titleBarHeight: CGFloat = 32

    static func render(to directory: URL) -> Bool {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            print("can't create \(directory.path): \(error.localizedDescription)")
            return false
        }
        let useImageRenderer = CommandLine.arguments.contains("--image-renderer")
        var ok = true
        for snapshot in snapshots() {
            for dark in [false, true] {
                let url = directory.appendingPathComponent("\(snapshot.name)\(dark ? "-dark" : "").png")
                let image = useImageRenderer ? renderWithImageRenderer(snapshot, dark: dark) : renderWithHostingView(snapshot, dark: dark)
                guard let image, let png = ImageEncoding.png(image) else {
                    print("✗ \(url.lastPathComponent): render failed")
                    ok = false
                    continue
                }
                do {
                    try png.write(to: url)
                    print("✓ \(url.path) (\(image.width)×\(image.height))")
                } catch {
                    print("✗ \(url.lastPathComponent): \(error.localizedDescription)")
                    ok = false
                }
            }
        }
        return ok
    }

    private static func snapshots() -> [Snapshot] {
        let popover = NSColor.windowBackgroundColor
        let window = NSColor.windowBackgroundColor
        func menu(_ name: String, _ model: AppModel, confirming: String? = nil, editingRelay: Bool = false) -> Snapshot {
            Snapshot(name: name, background: popover,
                     view: AnyView(MenuContentView(model: model, confirmingRemovalID: confirming, editingRelayServer: editingRelay)))
        }
        func onboarding(_ name: String, _ model: AppModel, _ step: OnboardingView.Step) -> Snapshot {
            Snapshot(name: name, background: window, view: AnyView(OnboardingView(model: model, initialStep: step)),
                     titleBarHeight: titleBarHeight)
        }
        return [
            menu("popover-idle", PreviewData.idle()),
            menu("popover-connected", PreviewData.connected()),
            menu("popover-missing-permissions", PreviewData.missingPermissions()),
            menu("popover-needs-relaunch", PreviewData.missingPermissions(needsRelaunch: true)),
            menu("popover-offline", PreviewData.offline()),
            menu("popover-remove-confirmation", PreviewData.idle(), confirming: PreviewData.iPhone.id),
            menu("popover-relay-on", PreviewData.withRelayServer()),
            menu("popover-relay-setup", PreviewData.idle(), editingRelay: true),
            menu("popover-relay-edit", PreviewData.withRelayServer(), editingRelay: true),
            Snapshot(name: "pairing", background: window, view: AnyView(PairingView(model: PreviewData.pairing(), onDone: {})),
                     titleBarHeight: titleBarHeight),
            Snapshot(name: "pairing-success", background: window, view: AnyView(PairingView(model: PreviewData.paired(), onDone: {})),
                     titleBarHeight: titleBarHeight),
            onboarding("onboarding-1-welcome", PreviewData.onboarding(screenRecording: false, accessibility: false), .welcome),
            onboarding("onboarding-2-screen-recording", PreviewData.onboarding(screenRecording: false, accessibility: false), .screenRecording),
            onboarding("onboarding-2b-screen-recording-relaunch",
                       PreviewData.onboarding(screenRecording: false, accessibility: false, needsRelaunch: true), .screenRecording),
            onboarding("onboarding-3-accessibility-granted", PreviewData.onboarding(screenRecording: true, accessibility: true), .accessibility),
            onboarding("onboarding-4-pair", PreviewData.onboarding(screenRecording: true, accessibility: true), .pair),
        ]
    }

    private static func renderWithHostingView(_ snapshot: Snapshot, dark: Bool) -> CGImage? {
        let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        let root = snapshot.view
            .padding(.top, snapshot.titleBarHeight)
            .background(Color(nsColor: snapshot.background))
            .environment(\.controlActiveState, .key)
        let hosting = NSHostingView(rootView: root)
        hosting.appearance = appearance
        let size = hosting.fittingSize
        hosting.frame = CGRect(origin: .zero, size: size)
        let window = KeyAppearingWindow(contentRect: hosting.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = appearance
        window.contentView = hosting
        hosting.layoutSubtreeIfNeeded()
        // Let SwiftUI finish its first update pass (onAppear, timelines, AppKit control layout).
        RunLoop.current.run(until: Date().addingTimeInterval(0.25))
        hosting.layoutSubtreeIfNeeded()
        guard let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else { return nil }
        hosting.cacheDisplay(in: hosting.bounds, to: rep)
        window.contentView = nil
        return rep.cgImage
    }

    private static func renderWithImageRenderer(_ snapshot: Snapshot, dark: Bool) -> CGImage? {
        let root = snapshot.view
            .padding(.top, snapshot.titleBarHeight)
            .background(Color(nsColor: snapshot.background))
            .environment(\.colorScheme, dark ? .dark : .light)
        let renderer = ImageRenderer(content: root)
        renderer.scale = 2
        var image: CGImage?
        (NSAppearance(named: dark ? .darkAqua : .aqua) ?? NSAppearance.currentDrawing()).performAsCurrentDrawingAppearance {
            image = renderer.cgImage
        }
        return image
    }
}

/// Offscreen windows are never key, so AppKit would draw every control in its inactive (grey)
/// state. The real popover and windows are key while in use, so render them that way.
private final class KeyAppearingWindow: NSWindow {
    override var isKeyWindow: Bool { true }
    override var isMainWindow: Bool { true }
}
