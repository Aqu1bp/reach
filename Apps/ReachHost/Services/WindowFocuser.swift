import AppKit
import ApplicationServices
import ReachCore

/// Raises a specific window and brings its app forward using the Accessibility API.
///
/// AX calls are synchronous IPC to the target app and can stall if it's busy, so everything here runs
/// on a private queue with a short messaging timeout — never on the main thread.
final class WindowFocuser: @unchecked Sendable {
    private let queue = DispatchQueue(label: "reach.host.windows.ax", qos: .userInitiated)
    private static let timeout: Float = 1.0

    /// Makes the app frontmost. Under macOS 14's cooperative activation a background agent's
    /// `NSRunningApplication.activate` may be ignored; setting AXFrontmost isn't subject to that.
    /// Changes are made through `whileCurrent`, which skips them if the session that asked has ended.
    func bringToFront(pid: pid_t, whileCurrent: @escaping @Sendable (() -> Void) -> Bool) {
        queue.async {
            let app = AXUIElementCreateApplication(pid)
            AXUIElementSetMessagingTimeout(app, Self.timeout)
            _ = whileCurrent { AXHelpers.set(app, kAXFrontmostAttribute, true) }
        }
    }

    /// Raises the window of `pid` whose frame (global points) and title match, then activates the app.
    /// Changes are made through `whileCurrent` (finding the window isn't), which skips them if the
    /// session that asked has ended.
    func focusWindow(pid: pid_t, frame: CGRect, title: String, whileCurrent: @escaping @Sendable (() -> Void) -> Bool,
                     completion: @escaping @Sendable (Bool) -> Void) {
        queue.async {
            let app = AXUIElementCreateApplication(pid)
            AXUIElementSetMessagingTimeout(app, Self.timeout)
            guard let windows = AXHelpers.elements(app, kAXWindowsAttribute),
                  let window = Self.bestMatch(in: windows, frame: frame, title: title) else {
                if whileCurrent({ AXHelpers.set(app, kAXFrontmostAttribute, true) }) { completion(false) }
                return
            }
            let minimized = AXHelpers.bool(window, kAXMinimizedAttribute) == true
            let acted = whileCurrent {
                if minimized { AXHelpers.set(window, kAXMinimizedAttribute, false) }
                AXUIElementPerformAction(window, kAXRaiseAction as CFString)
                AXHelpers.set(window, kAXMainAttribute, true)
                // Activate last so the app comes forward with the raised window on top.
                AXHelpers.set(app, kAXFrontmostAttribute, true)
            }
            if acted { completion(true) }
        }
    }

    /// Frame and title together identify a window; either alone is a fallback (titles need Screen
    /// Recording permission to be known, and two windows can share a frame).
    private static func bestMatch(in windows: [AXUIElement], frame: CGRect, title: String) -> AXUIElement? {
        let candidates = windows.map { window in
            (window: window, frame: AXHelpers.frame(window), title: AXHelpers.string(window, kAXTitleAttribute) ?? "")
        }
        let sameFrame = candidates.filter { $0.frame.map { framesMatch($0, frame) } ?? false }
        if !title.isEmpty, let exact = sameFrame.first(where: { $0.title == title }) { return exact.window }
        if let byFrame = sameFrame.first { return byFrame.window }
        if !title.isEmpty, let byTitle = candidates.first(where: { $0.title == title }) { return byTitle.window }
        return nil
    }

    private static func framesMatch(_ a: CGRect, _ b: CGRect) -> Bool {
        abs(a.minX - b.minX) <= 2 && abs(a.minY - b.minY) <= 2 && abs(a.width - b.width) <= 2 && abs(a.height - b.height) <= 2
    }
}
