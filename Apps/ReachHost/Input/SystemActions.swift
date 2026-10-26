import AppKit
import ApplicationServices
import ReachCore
import ReachProtocol

/// How a `SystemAction` is carried out.
enum ActionMechanism: Equatable {
    /// One of Apple's tiny "docklet" launcher apps (Mission Control.app, Launchpad.app / Apps.app).
    /// Each just posts a Dock notification via `CoreDockSendNotification` and exits, so this works
    /// without Accessibility permission and regardless of keyboard-shortcut customisation.
    /// Mission Control.app takes argv[1] as an index: 0 = Mission Control, 1 = Show Desktop,
    /// 2 = App Exposé (verified by disassembling the macOS 27 binary).
    case docklet(URL, argument: String?)
    /// Launch an app through Launch Services.
    case openApplication(URL)
    /// Press a keyboard shortcut.
    case chord(KeyChord)
    /// ⌘Tab with ⌘ kept down so the switcher stays up (see `InputInjector`).
    case appSwitcher
    /// Press the clock in the menu bar via Accessibility; fall back to the user's shortcut, if any.
    case notificationCenter(fallback: KeyChord?)
    case wakeDisplay
    case unavailable(String)

    /// Whether the mechanism posts events or uses Accessibility (and so needs that permission).
    var needsAccessibility: Bool {
        switch self {
        case .chord, .appSwitcher, .notificationCenter: return true
        case .docklet, .openApplication, .wakeDisplay, .unavailable: return false
        }
    }
}

enum SystemActionResolver {
    static let missionControlApp = "/System/Applications/Mission Control.app"
    /// Launchpad (macOS 14–15) was replaced by the Apps launcher in macOS 26.
    static let launcherApps = ["/System/Applications/Launchpad.app", "/System/Applications/Apps.app"]
    static let screenshotApp = "/System/Applications/Utilities/Screenshot.app"

    static func mechanism(for action: SystemAction,
                          fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) },
                          hotKey: (SymbolicHotKey) -> KeyChord? = SymbolicHotKeys.current) -> ActionMechanism {
        func missionControl(_ argument: String?, else fallback: SymbolicHotKey) -> ActionMechanism {
            if fileExists(missionControlApp) {
                return .docklet(URL(fileURLWithPath: missionControlApp), argument: argument)
            }
            return hotKey(fallback).map(ActionMechanism.chord) ?? .unavailable("This Mac has no shortcut for that.")
        }

        switch action {
        case .missionControl:
            return missionControl(nil, else: .missionControl)
        case .appExpose:
            return missionControl("2", else: .applicationWindows)
        case .showDesktop:
            return missionControl("1", else: .showDesktop)
        case .launchpad:
            if let path = launcherApps.first(where: fileExists) {
                return .docklet(URL(fileURLWithPath: path), argument: nil)
            }
            return .unavailable("Launchpad isn't available on this Mac.")
        case .spotlight:
            return hotKey(.spotlight).map(ActionMechanism.chord)
                ?? .unavailable("Spotlight's keyboard shortcut is turned off on this Mac.")
        case .notificationCenter:
            return .notificationCenter(fallback: hotKey(.notificationCenter))
        case .previousSpace:
            return hotKey(.previousSpace).map(ActionMechanism.chord)
                ?? .unavailable("The “Move left a space” shortcut is turned off on this Mac.")
        case .nextSpace:
            return hotKey(.nextSpace).map(ActionMechanism.chord)
                ?? .unavailable("The “Move right a space” shortcut is turned off on this Mac.")
        case .appSwitcher:
            return .appSwitcher
        case .lockScreen:
            // ⌃⌘Q is the system's fixed Lock Screen shortcut (Apple menu); there's no public API.
            return .chord(KeyChord(keyCode: MacKey.q, modifiers: [.control, .command]))
        case .screenshot:
            // Opening Screenshot.app shows the same toolbar as ⇧⌘5 without depending on the shortcut.
            if fileExists(screenshotApp) { return .openApplication(URL(fileURLWithPath: screenshotApp)) }
            return hotKey(.screenshotOptions).map(ActionMechanism.chord)
                ?? .unavailable("Screenshot isn't available on this Mac.")
        case .forceQuit:
            // ⌥⌘⎋ is handled by the window server itself; no app or API opens this window.
            return .chord(KeyChord(keyCode: MacKey.escape, modifiers: [.option, .command]))
        case .wakeDisplay:
            return .wakeDisplay
        }
    }
}

/// Executes the non-keyboard mechanisms. Keyboard chords are pressed by `InputInjector`.
enum SystemActionRunner {
    static func runDocklet(_ app: URL, argument: String?) -> Bool {
        guard let executable = Bundle(url: app)?.executableURL else {
            ReachLog.error("host", "no executable in \(app.path)")
            return false
        }
        let process = Process()
        process.executableURL = executable
        process.arguments = argument.map { [$0] } ?? []
        do {
            try process.run()
            return true
        } catch {
            ReachLog.error("host", "couldn't run \(app.lastPathComponent): \(error.localizedDescription)")
            return false
        }
    }

    static func openApplication(_ app: URL) {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.openApplication(at: app, configuration: configuration) { _, error in
            if let error { ReachLog.error("host", "couldn't open \(app.lastPathComponent): \(error.localizedDescription)") }
        }
    }

    /// The menu bar clock; pressing it opens Notification Center. Blocks for up to the AX timeout,
    /// so call off the input path.
    static func menuBarClock() -> AXUIElement? {
        guard let controlCenter = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.controlcenter").first else {
            return nil
        }
        let app = AXUIElementCreateApplication(controlCenter.processIdentifier)
        AXUIElementSetMessagingTimeout(app, 1.0)
        guard let menuBar = AXHelpers.element(app, kAXExtrasMenuBarAttribute),
              let items = AXHelpers.elements(menuBar, kAXChildrenAttribute) else { return nil }
        return items.first { AXHelpers.string($0, kAXIdentifierAttribute) == "com.apple.menuextra.clock" }
    }

    static func press(_ element: AXUIElement) -> Bool {
        AXUIElementPerformAction(element, kAXPressAction as CFString) == .success
    }
}

/// Small typed wrappers over the AXUIElement C API.
enum AXHelpers {
    static func value(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value
    }

    static func element(_ element: AXUIElement, _ attribute: String) -> AXUIElement? {
        guard let value = value(element, attribute), CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement) // type checked above
    }

    static func elements(_ element: AXUIElement, _ attribute: String) -> [AXUIElement]? {
        value(element, attribute) as? [AXUIElement]
    }

    static func string(_ element: AXUIElement, _ attribute: String) -> String? {
        value(element, attribute) as? String
    }

    static func bool(_ element: AXUIElement, _ attribute: String) -> Bool? {
        (value(element, attribute) as? NSNumber)?.boolValue
    }

    static func frame(_ element: AXUIElement) -> CGRect? {
        guard let positionValue = value(element, kAXPositionAttribute), let sizeValue = value(element, kAXSizeAttribute),
              CFGetTypeID(positionValue) == AXValueGetTypeID(), CFGetTypeID(sizeValue) == AXValueGetTypeID() else { return nil }
        var origin = CGPoint.zero
        var size = CGSize.zero
        // Type IDs were checked above, so these casts can't fail.
        guard AXValueGetValue(positionValue as! AXValue, .cgPoint, &origin),
              AXValueGetValue(sizeValue as! AXValue, .cgSize, &size) else { return nil }
        return CGRect(origin: origin, size: size)
    }

    @discardableResult
    static func set(_ element: AXUIElement, _ attribute: String, _ value: Bool) -> Bool {
        AXUIElementSetAttributeValue(element, attribute as CFString, (value ? kCFBooleanTrue : kCFBooleanFalse) as CFTypeRef) == .success
    }
}
