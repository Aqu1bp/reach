import UIKit
import Observation
import ReachCore
import ReachProtocol

/// Describes the Mac a session is for (works for real and demo hosts).
struct SessionHost: Equatable {
    var id: String
    var name: String
    var model: String?
    var isDemo: Bool
}

/// One remote-control session: owns the connection source, the renderer, cursor tracking and input
/// sending, and exposes everything the session UI shows. Main-actor; the renderer and cursor tracker are
/// thread-safe and are fed directly from the network/decode threads.
@MainActor
@Observable
final class SessionController: Identifiable {
    enum ConnectStage: Int, Comparable {
        case finding, securing, streaming
        static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }
    }

    enum Phase: Equatable {
        /// First connection; nothing on screen yet.
        case connecting(ConnectStage)
        case live
        /// Was live; recovering. The last frame stays on screen, dimmed.
        case reconnecting
        /// Closed because the app went to the background; reconnects when it returns.
        case suspended
        case failed(String)
        /// The Mac ended the session.
        case ended(String)
    }

    struct Toast: Equatable, Identifiable {
        let id = UUID()
        var symbol: String
        var message: String
    }

    let id = UUID()
    let host: SessionHost

    private(set) var phase: Phase = .connecting(.finding)
    private(set) var hasFirstFrame = false
    private(set) var hostInfo: HostInfo?
    private(set) var displays: [DisplayInfo] = []
    private(set) var activeDisplayID: DisplayID?
    private(set) var stream: StreamInfo?
    private(set) var apps: [AppInfo] = []
    private(set) var windows: [WindowInfo] = []
    private(set) var frontmostApp: (pid: Int32, name: String)?
    private(set) var permissions: HostPermissions?
    private(set) var stats: ConnectionStats?
    private(set) var quality: QualityPreference
    private(set) var isDegraded = false

    var toast: Toast?
    var inputMode: InputMode {
        didSet {
            guard inputMode != oldValue else { return }
            UserDefaults.standard.set(inputMode.rawValue, forKey: SettingsKey.inputMode)
            input.releaseAll()
            canvas?.inputModeChanged()
        }
    }
    /// Desired soft-keyboard visibility (the canvas makes it so and reports user dismissals back).
    var keyboardVisible = false {
        didSet { if keyboardVisible != oldValue { canvas?.setKeyboardVisible(keyboardVisible) } }
    }
    var statsExpanded = false
    private(set) var pillVisible = false

    @ObservationIgnored let renderer: RemoteRenderer?
    @ObservationIgnored let cursor = CursorTracker()
    @ObservationIgnored let input: InputSender
    let log: InputLog
    let modifiers: StickyModifiers
    @ObservationIgnored weak var canvas: RemoteScreenView?
    /// Called when the session is over and the UI should be dismissed.
    @ObservationIgnored var onFinish: (() -> Void)?

    @ObservationIgnored private var source: RemoteSessionSource?
    @ObservationIgnored private let makeSource: (QualityPreference) -> RemoteSessionSource
    @ObservationIgnored private var everConnected = false
    @ObservationIgnored private var userClosed = false
    /// How many phone pixels the Mac's display covers; the Mac matches its stream resolution to it.
    @ObservationIgnored private var viewportHint: ViewportHint?
    @ObservationIgnored private var sentViewportHint: ViewportHint?
    @ObservationIgnored private var viewportWork: DispatchWorkItem?
    @ObservationIgnored private var statsTask: Task<Void, Never>?
    @ObservationIgnored private var pillTask: Task<Void, Never>?
    @ObservationIgnored private var toastTask: Task<Void, Never>?
    @ObservationIgnored private var graceTask: Task<Void, Never>?
    @ObservationIgnored private var backgroundTask: UIBackgroundTaskIdentifier = .invalid
    @ObservationIgnored private var iconCache: [String: Data] = [:]
    @ObservationIgnored private var lastWindowsRequest: Date = .distantPast
    @ObservationIgnored private var degradedSince: Date?
    @ObservationIgnored private var healthySince: Date?

    init(host: SessionHost, settings: AppSettings = .current, makeSource: @escaping (QualityPreference) -> RemoteSessionSource) {
        self.host = host
        self.makeSource = makeSource
        self.quality = settings.quality
        self.inputMode = LaunchOptions.inputMode ?? settings.inputMode
        let log = InputLog(visible: LaunchOptions.inputLog)
        let modifiers = StickyModifiers()
        self.log = log
        self.modifiers = modifiers
        self.input = InputSender(log: log, modifiers: modifiers)
        self.renderer = RemoteRenderer()
    }

    // MARK: Lifecycle

    func start() {
        guard source == nil else { return }
        UIApplication.shared.isIdleTimerDisabled = true
        Haptics.shared.prepare()
        renderer?.onFirstFrame = { [weak self] in
            DispatchQueue.main.async { self?.firstFrameArrived() }
        }
        connect()
        startStatsLoop()
    }

    private func connect() {
        let s = makeSource(quality)
        source = s
        input.source = s
        sentViewportHint = nil
        sendViewportHint(force: true)
        cursor.reset()
        renderer?.resetFirstFrame()
        phase = everConnected ? .reconnecting : .connecting(.finding)

        s.onState = { [weak self, weak s] state in
            MainActor.assumeIsolated {
                guard let self, let s, self.source === s else { return }
                self.sourceStateChanged(state)
            }
        }
        s.onMessage = { [weak self, weak s] message in
            MainActor.assumeIsolated {
                guard let self, let s, self.source === s else { return }
                self.handle(message)
            }
        }
        let cursor = self.cursor, renderer = self.renderer
        s.onCursor = { packet in cursor.hostReported(packet) }
        s.onVideoFrame = { buffer, _ in renderer?.submit(buffer) }
    }

    /// The canvas zoomed: `displayedPixels` is the Mac display's size on screen in physical pixels.
    /// Sent once the zoom has settled, not on every frame of a pinch.
    func viewportDidChange(displayedPixels: CGSize) {
        guard displayedPixels.width > 0, displayedPixels.height > 0 else { return }
        let hint = ViewportHint(displayedPixelWidth: Int(displayedPixels.width.rounded()),
                                displayedPixelHeight: Int(displayedPixels.height.rounded()))
        guard hint != viewportHint else { return }
        viewportHint = hint
        viewportWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.sendViewportHint(force: false) }
        }
        viewportWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
    }

    /// Also called before the connection is up: the hint then rides along in the hello.
    private func sendViewportHint(force: Bool) {
        guard let hint = viewportHint, let source, force || hint != sentViewportHint else { return }
        sentViewportHint = hint
        source.setViewport(hint)
    }

    /// Tear down the current connection and start a fresh one (Retry, return from background).
    func reconnect() {
        detachSource(close: true)
        userClosed = false
        connect()
    }

    /// User-initiated disconnect.
    func disconnect() {
        userClosed = true
        input.releaseAll()
        detachSource(close: true)
        finish()
    }

    private func detachSource(close: Bool) {
        guard let s = source else { return }
        s.onState = nil
        s.onMessage = nil
        s.onCursor = nil
        s.onVideoFrame = nil
        if close { s.close() }
        source = nil
        input.source = nil
    }

    private func finish() {
        statsTask?.cancel()
        pillTask?.cancel()
        graceTask?.cancel()
        endBackgroundTask()
        input.invalidate()
        UIApplication.shared.isIdleTimerDisabled = false
        onFinish?()
    }

    // MARK: App lifecycle

    func appDidEnterBackground() {
        guard source != nil, phase == .live || phase == .reconnecting || isConnecting else { return }
        input.releaseAll()
        keyboardVisible = false
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "reach.session.close") { [weak self] in
            MainActor.assumeIsolated { self?.suspendNow() }
        }
        graceTask?.cancel()
        // A short grace period: glancing at a notification or the app switcher shouldn't drop the session.
        graceTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled else { return }
            self?.suspendNow()
        }
    }

    func appDidBecomeActive() {
        graceTask?.cancel()
        graceTask = nil
        endBackgroundTask()
        if phase == .suspended { reconnect() }
    }

    private func suspendNow() {
        graceTask?.cancel()
        graceTask = nil
        if source != nil, phase != .suspended {
            detachSource(close: true)
            phase = .suspended
        }
        endBackgroundTask()
    }

    private func endBackgroundTask() {
        guard backgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTask)
        backgroundTask = .invalid
    }

    private var isConnecting: Bool {
        if case .connecting = phase { return true }
        return false
    }

    // MARK: State

    private func sourceStateChanged(_ state: ClientSession.State) {
        switch state {
        case .signaling:
            phase = everConnected ? .reconnecting : .connecting(.finding)
        case .connecting:
            if !everConnected { phase = .connecting(.securing) }
        case .connected:
            let first = !everConnected
            everConnected = true
            phase = hasFirstFrame ? .live : .connecting(.streaming)
            if first { Haptics.shared.play(.connected) }
            source?.send(.requestApps)
            requestWindows(force: true)
            sendViewportHint(force: true)
            flashPill()
        case .reconnecting:
            phase = .reconnecting
        case .failed(let message):
            input.releaseAll()
            keyboardVisible = false
            phase = .failed(message)
            Haptics.shared.play(.failure)
        case .closed(let reason):
            input.releaseAll()
            if userClosed { return }
            if phase == .suspended { return }
            keyboardVisible = false
            phase = .ended(reason)
        }
    }

    private func firstFrameArrived() {
        hasFirstFrame = true
        if case .connecting = phase, source?.state == .connected { phase = .live }
        if phase == .reconnecting, source?.state == .connected { phase = .live }
    }

    // MARK: Host messages

    private func handle(_ message: HostMessage) {
        switch message {
        case .hello(let hello):
            hostInfo = hello.info
            displays = hello.displays
            setActiveDisplay(hello.activeDisplayID)
            updatePermissions(hello.permissions)
        case .displays(let list, let active):
            displays = list
            setActiveDisplay(active)
        case .stream(let info):
            stream = info
            canvas?.contentSizeDidChange()
        case .cursorImage(let image):
            renderer?.addCursorImage(image)
        case .cursorShape(let id):
            renderer?.setCursorShape(id)
        case .clipboard(let content):
            receiveClipboard(content)
        case .apps(let list):
            apps = list.map { app in
                var a = app
                let key = app.bundleID ?? "pid:\(app.pid)"
                if let icon = app.icon { iconCache[key] = icon } else { a.icon = iconCache[key] }
                return a
            }
        case .windows(let list):
            windows = list
        case .frontmostApp(let pid, let name):
            frontmostApp = (pid, name)
            requestWindows(force: false)
        case .permissions(let p):
            updatePermissions(p)
        case .notice(let notice):
            let symbol = notice.level == .info ? "info.circle" : "exclamationmark.triangle"
            showToast(symbol: symbol, notice.message)
        case .pong:
            break
        }
    }

    private func setActiveDisplay(_ id: DisplayID) {
        let changed = activeDisplayID != id
        activeDisplayID = id
        canvas?.contentSizeDidChange()
        if changed { canvas?.displayDidChange() }
    }

    private func updatePermissions(_ p: HostPermissions) {
        let previous = permissions
        permissions = p
        if !p.screenRecording, previous?.screenRecording != false {
            showToast(symbol: "rectangle.dashed.badge.record", "Allow Screen Recording for Reach Host on your Mac")
        } else if !p.accessibility, previous?.accessibility != false {
            showToast(symbol: "accessibility", "Allow Accessibility for Reach Host on your Mac to control it")
        }
    }

    private func receiveClipboard(_ content: ClipboardContent) {
        if let text = content.text, !text.isEmpty {
            UIPasteboard.general.string = text
            showToast(symbol: "doc.on.clipboard", "Copied from Mac")
        } else if let png = content.imagePNG, let image = UIImage(data: png) {
            UIPasteboard.general.image = image
            showToast(symbol: "photo.on.rectangle", "Image copied from Mac")
        }
    }

    // MARK: Geometry

    var activeDisplay: DisplayInfo? { displays.first { $0.id == activeDisplayID } }

    /// The active display in Mac points (the canvas's content space).
    var contentSize: CGSize {
        if let d = activeDisplay, d.frame.width > 0, d.frame.height > 0 {
            return CGSize(width: d.frame.width, height: d.frame.height)
        }
        if let s = stream, s.width > 0, s.height > 0 {
            return CGSize(width: Double(s.width) / 2, height: Double(s.height) / 2)
        }
        return CGSize(width: 1512, height: 982)
    }

    /// A window's frame in content coordinates, clipped to the active display.
    func contentRect(for window: WindowInfo) -> CGRect? {
        guard let d = activeDisplay else { return nil }
        let r = CGRect(x: window.frame.x - d.frame.x, y: window.frame.y - d.frame.y,
                       width: window.frame.width, height: window.frame.height)
        let clipped = r.intersection(CGRect(origin: .zero, size: contentSize))
        return clipped.isNull || clipped.width < 40 || clipped.height < 30 ? nil : clipped
    }

    /// Frontmost on-screen window under a content point (the list is front-to-back).
    func window(at contentPoint: CGPoint) -> WindowInfo? {
        windows.first { $0.isOnScreen && (contentRect(for: $0)?.contains(contentPoint) ?? false) }
    }

    // MARK: Commands

    func requestWindows(force: Bool) {
        guard force || Date().timeIntervalSince(lastWindowsRequest) > 1.5 else { return }
        lastWindowsRequest = Date()
        source?.send(.requestWindows)
    }

    func requestApps() {
        source?.send(.requestApps)
        requestWindows(force: true)
    }

    func activate(_ app: AppInfo) {
        input.send(.activateApp(pid: app.pid))
        Haptics.shared.play(.click)
    }

    func focus(_ window: WindowInfo) {
        input.send(.focusWindow(id: window.id))
        if let rect = contentRect(for: window) {
            canvas?.zoom(toContentRect: rect)
        }
        Haptics.shared.play(.click)
    }

    func selectDisplay(_ display: DisplayInfo) {
        guard display.id != activeDisplayID else { return }
        input.send(.selectDisplay(id: display.id))
    }

    func setQualityMode(_ mode: QualityMode) {
        quality.mode = mode
        UserDefaults.standard.set(mode.rawValue, forKey: SettingsKey.qualityMode)
        source?.setQuality(quality)
        input.log.record(.setQuality(quality))
    }

    func setMaxFramesPerSecond(_ fps: Int) {
        quality.maxFramesPerSecond = fps
        UserDefaults.standard.set(fps, forKey: SettingsKey.maxFPS)
        source?.setQuality(quality)
        input.log.record(.setQuality(quality))
    }

    /// Ask the transport to re-establish its path (ICE restart for real sessions; a short simulated
    /// outage for the demo) — exercises the reconnecting UI.
    func restartTransport() {
        source?.restartConnection()
    }

    func sendClipboard(text: String?, imagePNG: Data?) {
        guard text != nil || imagePNG != nil else { return }
        input.send(.setClipboard(ClipboardContent(text: text, imagePNG: imagePNG)))
        showToast(symbol: "arrow.up.doc.on.clipboard", "Sent to Mac’s clipboard")
        Haptics.shared.play(.click)
    }

    func showToast(symbol: String, _ message: String) {
        toast = Toast(symbol: symbol, message: message)
        toastTask?.cancel()
        toastTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2.2))
            guard !Task.isCancelled else { return }
            self?.toast = nil
        }
    }

    /// Touching the remote screen closes floating panels (they'd otherwise cover what you're working on).
    func dismissTransientUI() {
        if statsExpanded { statsExpanded = false }
    }

    // MARK: Status pill & stats

    func flashPill(seconds: Double = 4) {
        pillVisible = true
        pillTask?.cancel()
        pillTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled, let self else { return }
            if !self.isDegraded && !self.statsExpanded { self.pillVisible = false }
        }
    }

    var roundTripMs: Double? { stats?.roundTripMs ?? source?.controlRoundTripMs }

    private func startStatsLoop() {
        statsTask?.cancel()
        statsTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let fast = self.statsExpanded || self.pillVisible || UserDefaults.standard.bool(forKey: SettingsKey.showStats)
                try? await Task.sleep(for: .seconds(fast ? 1 : 2))
                guard !Task.isCancelled else { return }
                self.sampleStats()
            }
        }
    }

    private func sampleStats() {
        guard let source, phase == .live || phase == .reconnecting else { return }
        source.stats { [weak self] s in
            MainActor.assumeIsolated {
                guard let self, let s else { return }
                self.stats = s
                self.evaluateHealth(s)
            }
        }
    }

    /// Show the pill while the connection is noticeably worse than usual; hide it once healthy again.
    private func evaluateHealth(_ s: ConnectionStats) {
        let rtt = s.roundTripMs ?? source?.controlRoundTripMs ?? 0
        let degraded = rtt > 150 || (s.jitterBufferMs ?? 0) > 120
        let now = Date()
        if degraded {
            healthySince = nil
            if degradedSince == nil { degradedSince = now }
            if let since = degradedSince, now.timeIntervalSince(since) > 2, !isDegraded {
                isDegraded = true
                pillVisible = true
            }
        } else {
            degradedSince = nil
            if isDegraded {
                if healthySince == nil { healthySince = now }
                if let since = healthySince, now.timeIntervalSince(since) > 3 {
                    isDegraded = false
                    flashPill(seconds: 1)
                }
            }
        }
    }
}
