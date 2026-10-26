import AppKit
import ReachCore
import ReachProtocol

/// Running apps and on-screen windows, for the iPhone's app switcher. Main thread only.
@MainActor
final class AppsService {
    /// The frontmost app changed.
    var onFrontmostChange: ((_ pid: Int32, _ name: String) -> Void)?
    /// The set of running apps (or their hidden/active state) changed. Debounced.
    var onAppsChange: (() -> Void)?

    static let iconPoints: CGFloat = 64
    private let focuser = WindowFocuser()
    private var iconCache: [String: Data] = [:]
    private var observers: [NSObjectProtocol] = []
    private var pendingChange: DispatchWorkItem?

    func startObserving() {
        guard observers.isEmpty else { return }
        let center = NSWorkspace.shared.notificationCenter
        observers.append(center.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            MainActor.assumeIsolated {
                if let app { self?.onFrontmostChange?(app.processIdentifier, app.localizedName ?? "") }
                self?.scheduleAppsChange()
            }
        })
        let listChanges: [Notification.Name] = [
            NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification,
            NSWorkspace.didHideApplicationNotification, NSWorkspace.didUnhideApplicationNotification,
        ]
        for name in listChanges {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.scheduleAppsChange() }
            })
        }
    }

    func stopObserving() {
        observers.forEach(NSWorkspace.shared.notificationCenter.removeObserver)
        observers = []
        pendingChange?.cancel()
    }

    var frontmost: (pid: Int32, name: String)? {
        NSWorkspace.shared.frontmostApplication.map { ($0.processIdentifier, $0.localizedName ?? "") }
    }

    /// Regular (Dock) apps, alphabetically. Icons are included only where `includeIcon` says so —
    /// the iPhone keeps icons it has already received.
    func runningApps(includeIcon: (Int32) -> Bool) -> [AppInfo] {
        let frontPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        return NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && !$0.isTerminated }
            .map { app in
                AppInfo(pid: app.processIdentifier, bundleID: app.bundleIdentifier,
                        name: app.localizedName ?? app.bundleURL?.deletingPathExtension().lastPathComponent ?? "App",
                        icon: includeIcon(app.processIdentifier) ? icon(for: app) : nil,
                        isActive: app.processIdentifier == frontPID, isHidden: app.isHidden)
            }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// Visible, normal-level windows, front to back. Titles are empty without Screen Recording.
    func windows() -> [WindowInfo] {
        let ownPID = ProcessInfo.processInfo.processIdentifier
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]] else { return [] }
        return list.compactMap { entry -> WindowInfo? in
            guard (entry[kCGWindowLayer as String] as? Int) == 0,
                  let id = entry[kCGWindowNumber as String] as? UInt32,
                  let pid = entry[kCGWindowOwnerPID as String] as? Int32, pid != ownPID,
                  let boundsDictionary = entry[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsDictionary as CFDictionary),
                  bounds.width >= 40, bounds.height >= 40,
                  ((entry[kCGWindowAlpha as String] as? Double) ?? 1) > 0.01 else { return nil }
            return WindowInfo(id: id, pid: pid, appName: entry[kCGWindowOwnerName as String] as? String ?? "",
                              title: entry[kCGWindowName as String] as? String ?? "",
                              frame: Rect(x: bounds.minX, y: bounds.minY, width: bounds.width, height: bounds.height),
                              isOnScreen: entry[kCGWindowIsOnscreen as String] as? Bool ?? true)
        }
    }

    /// Brings an app forward the way clicking its Dock icon does — unhidden, activated, and with a
    /// window reopened if it had none. Returns `false` if the app is gone.
    @discardableResult
    func activate(pid: Int32, whileCurrent: @escaping @Sendable (() -> Void) -> Bool) -> Bool {
        guard let app = NSRunningApplication(processIdentifier: pid), !app.isTerminated else { return false }
        if app.isHidden { app.unhide() }
        if let bundleURL = app.bundleURL {
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true
            // For a running app this activates it and sends the "reopen" event, like a Dock click.
            NSWorkspace.shared.openApplication(at: bundleURL, configuration: configuration) { _, error in
                if let error { ReachLog.error("host", "activate \(pid): \(error.localizedDescription)") }
            }
        } else {
            app.activate(options: [.activateAllWindows])
        }
        focuser.bringToFront(pid: pid, whileCurrent: whileCurrent)
        return true
    }

    /// Raises one window. Returns `false` if it no longer exists.
    @discardableResult
    func focusWindow(id: UInt32, whileCurrent: @escaping @Sendable (() -> Void) -> Bool) -> Bool {
        guard let window = windows().first(where: { $0.id == id }) ?? Self.windowInfo(id: id) else { return false }
        if let app = NSRunningApplication(processIdentifier: window.pid), app.isHidden { app.unhide() }
        let frame = CGRect(x: window.frame.x, y: window.frame.y, width: window.frame.width, height: window.frame.height)
        focuser.focusWindow(pid: window.pid, frame: frame, title: window.title, whileCurrent: whileCurrent) { found in
            if !found { ReachLog.info("host", "window \(id) not found via Accessibility; activated its app instead") }
        }
        return true
    }

    // MARK: - Private

    private func scheduleAppsChange() {
        pendingChange?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.onAppsChange?() }
        pendingChange = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
    }

    private func icon(for app: NSRunningApplication) -> Data? {
        let key = app.bundleURL?.path ?? "pid:\(app.processIdentifier)"
        if let cached = iconCache[key] { return cached }
        let image = app.icon ?? app.bundleURL.map { NSWorkspace.shared.icon(forFile: $0.path) }
        guard let image, let png = ImageEncoding.png(image, points: CGSize(width: Self.iconPoints, height: Self.iconPoints), scale: 2) else {
            return nil
        }
        iconCache[key] = png
        return png
    }

    /// Looks a window up directly (it may be off-screen, e.g. on another Space).
    private static func windowInfo(id: UInt32) -> WindowInfo? {
        guard let list = CGWindowListCopyWindowInfo(.optionIncludingWindow, CGWindowID(id)) as? [[String: Any]],
              let entry = list.first,
              let pid = entry[kCGWindowOwnerPID as String] as? Int32,
              let boundsDictionary = entry[kCGWindowBounds as String] as? NSDictionary,
              let bounds = CGRect(dictionaryRepresentation: boundsDictionary as CFDictionary) else { return nil }
        return WindowInfo(id: id, pid: pid, appName: entry[kCGWindowOwnerName as String] as? String ?? "",
                          title: entry[kCGWindowName as String] as? String ?? "",
                          frame: Rect(x: bounds.minX, y: bounds.minY, width: bounds.width, height: bounds.height),
                          isOnScreen: false)
    }
}
