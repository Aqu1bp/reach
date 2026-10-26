import AppKit
import SwiftUI

/// Owns the app's standalone windows. A menu-bar (LSUIElement) app has no Window menu or Dock icon,
/// so windows are created with AppKit, where reopening, fronting and closing are explicit.
@MainActor
final class WindowCoordinator: NSObject, NSWindowDelegate {
    private var pairingWindow: NSWindow?
    private var onboardingWindow: NSWindow?
    private weak var model: AppModel?
    private var pairingCloseWork: DispatchWorkItem?

    /// How long the pairing window shows its success state before closing by itself.
    private static let successDismissDelay: TimeInterval = 2.2

    func showPairing(model: AppModel) {
        self.model = model
        pairingCloseWork?.cancel()
        if let pairingWindow {
            if case .paired = model.pairing.state { model.pairing.refresh() }
            present(pairingWindow)
            return
        }
        let window = makeWindow(title: "Pair iPhone", rootView: PairingView(model: model, onDone: { [weak self] in
            self?.pairingWindow?.close()
        }))
        pairingWindow = window
        model.pairing.setVisible(true, for: .pairingWindow)
        present(window)
    }

    func showOnboarding(model: AppModel) {
        self.model = model
        if let onboardingWindow {
            present(onboardingWindow)
            return
        }
        let window = makeWindow(title: "Welcome to Reach", rootView: OnboardingView(model: model))
        onboardingWindow = window
        present(window)
    }

    func closeOnboarding() {
        onboardingWindow?.close()
    }

    /// Lets the success state register, then closes the pairing window.
    func pairingSucceeded() {
        guard pairingWindow != nil else { return }
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.pairingWindow?.close() }
        }
        pairingCloseWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.successDismissDelay, execute: work)
    }

    // MARK: - NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        if window === pairingWindow {
            pairingCloseWork?.cancel()
            pairingWindow = nil
            model?.pairing.setVisible(false, for: .pairingWindow)
        } else if window === onboardingWindow {
            onboardingWindow = nil
            model?.pairing.setVisible(false, for: .onboarding)
        }
        // Drop the SwiftUI hierarchy now rather than whenever AppKit releases the window.
        window.contentViewController = nil
    }

    // MARK: - Private

    /// Fixed-size windows sized by their SwiftUI content, under a transparent title bar that blends
    /// into the window background.
    private func makeWindow<Content: View>(title: String, rootView: Content) -> NSWindow {
        let controller = NSHostingController(rootView: rootView)
        controller.sizingOptions = [.preferredContentSize]
        let window = NSWindow(contentViewController: controller)
        window.title = title
        window.styleMask = [.titled, .closable]
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.collectionBehavior.insert(.moveToActiveSpace)
        window.delegate = self
        window.center()
        return window
    }

    private func present(_ window: NSWindow) {
        // An accessory app isn't active after a menu-bar click; without activating, the window
        // would open behind the frontmost app.
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }
}
