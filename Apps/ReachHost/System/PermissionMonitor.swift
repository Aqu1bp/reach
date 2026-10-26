import AppKit
import ApplicationServices
import Observation
import ReachCore
import ReachProtocol

/// The two privacy permissions Reach Host needs, kept current by polling (macOS posts no
/// notification when they change).
@MainActor
@Observable
final class PermissionMonitor {
    enum Kind: CaseIterable {
        case screenRecording
        case accessibility

        /// Deep link to the exact Privacy & Security pane.
        var settingsURL: URL? {
            switch self {
            case .screenRecording: return URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")
            case .accessibility: return URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
            }
        }
    }

    private(set) var screenRecording: Bool
    private(set) var accessibility: Bool
    /// The user has been sent to grant Screen Recording but it isn't active yet. macOS applies that
    /// grant only to newly launched processes, so the UI offers a relaunch.
    private(set) var screenRecordingNeedsRelaunch = false

    @ObservationIgnored var onChange: ((HostPermissions) -> Void)?
    /// Thread-safe view of the Accessibility grant for the input path.
    @ObservationIgnored let trust = AccessibilityTrust()

    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var activationObserver: NSObjectProtocol?
    @ObservationIgnored private let isLive: Bool
    @ObservationIgnored private let defaults = UserDefaults.standard

    var current: HostPermissions { HostPermissions(screenRecording: screenRecording, accessibility: accessibility) }
    var allGranted: Bool { screenRecording && accessibility }

    init() {
        isLive = true
        screenRecording = CGPreflightScreenCaptureAccess()
        accessibility = AXIsProcessTrusted()
    }

    /// Fixed state for UI snapshots.
    init(previewScreenRecording: Bool, accessibility: Bool, needsRelaunch: Bool = false) {
        isLive = false
        screenRecording = previewScreenRecording
        self.accessibility = accessibility
        screenRecordingNeedsRelaunch = needsRelaunch
    }

    func startMonitoring() {
        guard isLive else { return }
        refresh()
        log()
        activationObserver = NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification,
                                                                    object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        reschedule()
    }

    func refresh() {
        guard isLive else { return }
        let screen = CGPreflightScreenCaptureAccess()
        let access = AXIsProcessTrusted()
        trust.record(access)
        if screen { screenRecordingNeedsRelaunch = false }
        guard screen != screenRecording || access != accessibility else { return }
        screenRecording = screen
        accessibility = access
        log()
        reschedule()
        onChange?(current)
    }

    private func log() {
        ReachLog.info("host", "permissions: screen recording \(screenRecording ? "granted" : "missing"), accessibility \(accessibility ? "granted" : "missing")")
    }

    /// The first time, shows the system prompt (which itself links to System Settings); after that,
    /// goes straight to the right Settings pane — macOS never re-prompts once asked.
    func request(_ kind: Kind) {
        let key = "didRequest.\(kind)"
        let askedBefore = defaults.bool(forKey: key)
        defaults.set(true, forKey: key)
        if kind == .screenRecording { screenRecordingNeedsRelaunch = true }
        if askedBefore {
            openSettings(kind)
        } else {
            switch kind {
            case .screenRecording:
                _ = CGRequestScreenCaptureAccess()
            case .accessibility:
                let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
                _ = AXIsProcessTrustedWithOptions(options)
            }
        }
        refresh()
    }

    func openSettings(_ kind: Kind) {
        guard let url = kind.settingsURL else { return }
        NSWorkspace.shared.open(url)
    }

    /// Poll quickly while something is missing (to react as soon as the user flips the switch), and
    /// slowly otherwise (to notice a revocation).
    private func reschedule() {
        timer?.invalidate()
        let interval: TimeInterval = allGranted ? 10 : 1.5
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        timer.tolerance = interval / 5
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }
}
