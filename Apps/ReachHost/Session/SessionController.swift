import AppKit
import ReachCore
import ReachProtocol

/// What the UI needs to hear about. Called on the main actor.
@MainActor
protocol SessionControllerObserver: AnyObject {
    func relayStatusChanged(online: Bool)
    func sessionStarted(_ session: HostSessionInfo)
    func sessionEnded(_ session: HostSessionInfo, reason: String)
    func didPair(_ client: TrustedClient)
}

/// Runs a remote-control session: implements `HostEngineDelegate`, routes every `ClientMessage`, and
/// starts/stops capture, cursor, clipboard and app tracking around the session.
///
/// Threading: lifecycle callbacks and non-input messages are handled on the main actor. Input
/// messages arrive on the engine's input queue and go straight to `InputInjector` without a hop.
@MainActor
final class SessionController: HostEngineDelegate {
    weak var observer: SessionControllerObserver?

    nonisolated let injector: InputInjector
    private let engine: HostEngine
    private let displays: DisplayCatalog
    private let geometry: DisplayGeometry
    private let permissions: PermissionMonitor
    private let power: PowerManager
    private let capturer = ScreenCapturer()
    private let cursor: CursorMonitor
    private let apps = AppsService()
    private lazy var clipboard = ClipboardSync { [weak self] content in self?.send(.clipboard(content)) }
    private let settings = AppSettings()

    /// Per-session state; `nil` between sessions.
    private var context: Context?
    /// The client's hello can be delivered before `sessionDidStart`: its control channel may open
    /// before the engine considers the session connected. Its quality is held until then.
    private var pendingQuality: QualityPreference?
    private var pendingHello: ClientHello?
    private var pendingViewport: ViewportHint?
    /// A switch to a smaller stream, delayed so zooming back and forth doesn't restart the encoder
    /// (and send a keyframe) each time.
    private var downshift: DispatchWorkItem?

    private struct Context {
        var info: HostSessionInfo
        var quality = QualityPreference()
        var viewport: ViewportHint?
        var clientScreen: (width: Int, height: Int)?
        /// Fraction of the display's native pixels being streamed (`CaptureGeometry.scaleTiers`).
        var streamScale: Double = 1
        var bandwidth = BandwidthTier()
        var displayID: DisplayID
        var stream: StreamInfo?
        var captureFailure: ScreenCapturer.Failure?
        var captureRetries = 0
        var appsRequested = false
        var sentIconPIDs: Set<Int32> = []
        var lastAccessibilityNotice: TimeInterval = -.infinity
    }

    init(engine: HostEngine, displays: DisplayCatalog, geometry: DisplayGeometry, permissions: PermissionMonitor,
         power: PowerManager, keyboardLayouts: KeyboardLayoutProvider) {
        self.engine = engine
        self.displays = displays
        self.geometry = geometry
        self.permissions = permissions
        self.power = power
        injector = InputInjector(geometry: geometry, layouts: keyboardLayouts, trust: permissions.trust, power: power)
        cursor = CursorMonitor(geometry: geometry, output: .init(
            position: { [engine] packet in engine.sendCursor(packet) },
            message: { [engine] message in engine.send(message) }))
        capturer.onFrame = { [engine] buffer in engine.pushVideoFrame(buffer) }
        capturer.onInterrupted = { [weak self] failure in
            MainActor.assumeIsolated { self?.captureInterrupted(failure) }
        }
        injector.delegate = self
        displays.onChange = { [weak self] in self?.displaysChanged() }
        apps.onFrontmostChange = { [weak self] pid, name in self?.send(.frontmostApp(pid: pid, name: name)) }
        apps.onAppsChange = { [weak self] in self?.appsChanged() }
    }

    var isActive: Bool { context != nil }

    /// Ends the session from the Mac side.
    func disconnect() {
        engine.disconnect(reason: "Disconnected from the Mac")
    }

    /// Permissions changed while the app is running.
    func permissionsChanged(_ permissions: HostPermissions) {
        guard let context else { return }
        send(.permissions(permissions))
        if permissions.screenRecording, context.captureFailure == .permissionDenied {
            startCapture()
        }
    }

    // MARK: - HostEngineDelegate (lifecycle: main queue)

    nonisolated func hostEngine(_ engine: HostEngine, relayStatusChanged online: Bool) {
        onMainNowOrAsync { self.observer?.relayStatusChanged(online: online) }
    }

    nonisolated func hostEngine(_ engine: HostEngine, didPair client: TrustedClient) {
        onMainNowOrAsync { self.observer?.didPair(client) }
    }

    nonisolated func hostEngine(_ engine: HostEngine, sessionDidStart session: HostSessionInfo) {
        onMainNowOrAsync { self.begin(session) }
    }

    nonisolated func hostEngine(_ engine: HostEngine, sessionDidEnd session: HostSessionInfo, reason: String) {
        onMainNowOrAsync { self.end(session, reason: reason) }
    }

    nonisolated func hostEngine(_ engine: HostEngine, didMeasure stats: ConnectionStats) {
        onMainNowOrAsync { self.measured(stats) }
    }

    nonisolated func hostEngine(_ engine: HostEngine, inputDidStopFor session: HostSessionInfo) {
        // Right away, on the engine's queue, rather than in `end` on main: anything still waiting to
        // act on the Mac for that session sees the new generation and is dropped.
        injector.releaseAll()
    }

    // MARK: - HostEngineDelegate (input queue)

    nonisolated func hostEngine(_ engine: HostEngine, didReceivePointer packet: PointerPacket) {
        injector.pointer(packet)
    }

    nonisolated func hostEngine(_ engine: HostEngine, didReceive message: ClientMessage) {
        switch message {
        // Input: injected right here on the engine's serial input queue.
        case .mouseButton(let event): injector.mouseButton(event)
        case .scroll(let event): injector.scroll(event)
        case .key(let event): injector.key(event)
        case .keyPress(let code, let modifiers): injector.keyPress(code: code, modifiers: modifiers)
        case .text(let input): injector.type(input)
        case .action(let action): injector.perform(action)
        case .media(let key): injector.media(key)

        // Session and Mac state: main actor, and only if the session that sent it is still current
        // by then. A check at the start is enough for these: unpairing a device also runs on main,
        // so none of them can be midway when it returns.
        case .hello(let hello): onMainIfCurrent { self.clientHello(hello) }
        case .selectDisplay(let id): onMainIfCurrent { self.selectDisplay(id) }
        case .setQuality(let quality): onMainIfCurrent { self.applyQuality(quality) }
        case .viewport(let hint): onMainIfCurrent { self.applyViewport(hint) }
        case .requestApps: onMainIfCurrent { self.sendApps(requested: true) }
        case .requestWindows: onMainIfCurrent { self.send(.windows(self.apps.windows())) }
        // Changes to the Mac: through the injector's gate, so a session can't end midway through one.
        case .activateApp(let pid):
            let gate = injector.gate(injector.generation)
            onMain { self.activateApp(pid, gate: gate) }
        case .focusWindow(let id):
            let gate = injector.gate(injector.generation)
            onMain { self.focusWindow(id, gate: gate) }
        case .setClipboard(let content):
            let gate = injector.gate(injector.generation)
            onMain { _ = gate { self.clipboard.apply(content) } }

        // HostEngine answers pings itself and doesn't forward them; listed to keep the switch exhaustive.
        case .ping: break
        }
    }

    private nonisolated func onMainIfCurrent(_ body: @escaping @MainActor () -> Void) {
        let generation = injector.generation
        onMain { if self.injector.isCurrent(generation) { body() } }
    }

    // MARK: - Lifecycle

    private func begin(_ info: HostSessionInfo) {
        if let previous = context { end(previous.info, reason: "Replaced by a new session") }
        displays.refresh()
        let displayID = settings.preferredDisplayID.flatMap { displays.display(id: $0)?.id }
            ?? displays.mainDisplay?.id ?? CGMainDisplayID()
        var fresh = Context(info: info, quality: pendingQuality ?? QualityPreference(), displayID: displayID)
        if let hello = pendingHello { fresh.clientScreen = (hello.screenPixelWidth, hello.screenPixelHeight) }
        fresh.viewport = pendingViewport ?? pendingHello?.viewport
        fresh.streamScale = desiredStreamScale(for: fresh) ?? 1
        context = fresh
        pendingQuality = nil
        pendingHello = nil
        pendingViewport = nil
        ReachLog.info("host", "session with \(info.client.name) started")

        power.beginSession()
        updateGeometry()
        startCapture(announce: false)
        permissions.refresh()
        send(.hello(HostHello(info: HostDescription.current(), displays: displays.displays,
                              activeDisplayID: displayID, permissions: permissions.current)))
        if let stream = context?.stream { send(.stream(stream)) }
        cursor.start()
        if let front = apps.frontmost { send(.frontmostApp(pid: front.pid, name: front.name)) }
        clipboard.start(sendCurrent: true)
        apps.startObserving()
        if !permissions.accessibility {
            send(.notice(Notice(level: .warning, message: "To control this Mac, allow Accessibility for Reach Host in System Settings on the Mac.")))
        }
        observer?.sessionStarted(info)
    }

    private func end(_ info: HostSessionInfo, reason: String) {
        pendingQuality = nil
        pendingHello = nil
        pendingViewport = nil
        downshift?.cancel(); downshift = nil
        guard let context, context.info.sid == info.sid else { return }
        self.context = nil
        ReachLog.info("host", "session with \(info.client.name) ended: \(reason)")
        capturer.stop()
        cursor.stop()
        clipboard.stop()
        apps.stopObserving()
        power.endSession()
        engine.clearLastFrame()
        observer?.sessionEnded(info, reason: reason)
    }

    // MARK: - Capture

    private func captureSettings(for display: DisplayInfo, quality: QualityPreference, scale: Double) -> ScreenCapturer.Settings {
        let size = CaptureGeometry.outputSize(nativeWidth: display.pixelWidth, nativeHeight: display.pixelHeight, scale: scale)
        return .init(displayID: display.id, width: size.width, height: size.height,
                     framesPerSecond: CaptureGeometry.framesPerSecond(for: quality, displayRefreshRate: display.refreshRate))
    }

    /// (Re)starts capture for the session's display and quality. `announce` sends `.stream` when the
    /// stream description changed (the initial one goes out right after `.hello`).
    private func startCapture(announce: Bool = true) {
        guard var context else { return }
        guard let display = displays.display(id: context.displayID) ?? displays.mainDisplay else {
            send(.notice(Notice(level: .error, message: "No display is available to show.")))
            return
        }
        let settings = captureSettings(for: display, quality: context.quality, scale: context.streamScale)
        let stream = StreamInfo(displayID: display.id, width: settings.width, height: settings.height,
                                maxFramesPerSecond: settings.framesPerSecond)
        let changedDisplay = context.stream?.displayID != stream.displayID
        let changed = context.stream != stream
        context.stream = stream
        context.captureFailure = nil
        self.context = context
        if changedDisplay { engine.clearLastFrame() }
        if announce && changed { send(.stream(stream)) }

        let sid = context.info.sid
        capturer.start(settings) { [weak self] result in
            MainActor.assumeIsolated {
                guard let self, self.context?.info.sid == sid else { return }
                switch result {
                case .success:
                    self.context?.captureRetries = 0
                case .failure(let failure):
                    self.context?.captureFailure = failure
                    ReachLog.error("host", "capture failed: \(failure.message)")
                    if failure == .permissionDenied { self.permissions.refresh() }
                    self.send(.permissions(self.permissions.current))
                    self.send(.notice(Notice(level: failure == .permissionDenied ? .warning : .error, message: failure.message)))
                }
            }
        }
    }

    private func captureInterrupted(_ failure: ScreenCapturer.Failure) {
        guard var context else { return }
        context.captureFailure = failure
        context.captureRetries += 1
        self.context = context
        guard failure != .permissionDenied, context.captureRetries <= 3 else {
            send(.notice(Notice(level: .error, message: failure.message)))
            return
        }
        // Typically a display going away or the system restarting capture; try again shortly.
        let sid = context.info.sid
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.context?.info.sid == sid else { return }
                self.displays.refresh()
                self.startCapture()
            }
        }
    }

    private func updateGeometry() {
        guard let context, let display = displays.display(id: context.displayID) else { return }
        geometry.update(.init(displayID: display.id, frame: display.cgFrame))
    }

    // MARK: - Client messages

    private func clientHello(_ hello: ClientHello) {
        ReachLog.info("host", "client: \(hello.name) (\(hello.deviceModel)), app \(hello.appVersion), " +
                      "screen \(hello.screenPixelWidth)×\(hello.screenPixelHeight), protocol \(hello.protocolVersion)")
        if hello.protocolVersion != ReachProtocolVersion.current {
            ReachLog.error("host", "protocol mismatch: client \(hello.protocolVersion), host \(ReachProtocolVersion.current)")
        }
        guard var context else {
            pendingHello = hello
            pendingQuality = hello.quality
            return
        }
        context.clientScreen = (hello.screenPixelWidth, hello.screenPixelHeight)
        if let v = hello.viewport { context.viewport = v }
        self.context = context
        applyQuality(hello.quality)
        updateStreamScale()
    }

    private func applyQuality(_ quality: QualityPreference) {
        guard var context else {
            pendingQuality = quality
            return
        }
        guard context.quality != quality else { return }
        context.quality = quality
        context.streamScale = desiredStreamScale(for: context) ?? context.streamScale
        self.context = context
        downshift?.cancel(); downshift = nil
        startCapture()
    }

    private func applyViewport(_ hint: ViewportHint) {
        guard var context else {
            pendingViewport = hint
            return
        }
        context.viewport = hint
        self.context = context
        updateStreamScale()
    }

    private func desiredStreamScale(for context: Context? = nil) -> Double? {
        guard let context = context ?? self.context,
              let display = displays.display(id: context.displayID) ?? displays.mainDisplay else { return nil }
        let wanted = CaptureGeometry.streamScale(nativeWidth: display.pixelWidth, nativeHeight: display.pixelHeight,
                                                 viewport: context.viewport, clientScreen: context.clientScreen,
                                                 mode: context.quality.mode)
        return min(wanted, context.bandwidth.cap)
    }

    private func measured(_ stats: ConnectionStats) {
        guard var context, let bps = stats.availableBitrateKbps.map({ $0 * 1000 }),
              let display = displays.display(id: context.displayID) ?? displays.mainDisplay else { return }
        // The tiers are sized for H.264; HEVC gets the same picture from about 30% fewer bits.
        let hevc = stats.codecImplementation?.contains("HEVC") == true
        let effectiveBps = hevc ? bps / 0.7 : bps
        guard context.bandwidth.update(estimateBps: effectiveBps, nativePixels: Double(display.pixelWidth * display.pixelHeight)) else { return }
        ReachLog.info("host", String(format: "bandwidth %.1f Mbps (%@) → stream size cap %.2f", bps / 1e6, hevc ? "HEVC" : "H.264",
                                     context.bandwidth.cap))
        self.context = context
        updateStreamScale()
    }

    /// Bigger streams take effect at once (text sharpens as soon as you zoom in); smaller ones only
    /// once the zoom has settled for a moment.
    private func updateStreamScale() {
        guard let context, let desired = desiredStreamScale() else { return }
        if desired == context.streamScale {
            downshift?.cancel(); downshift = nil
            return
        }
        if desired > context.streamScale {
            downshift?.cancel(); downshift = nil
            setStreamScale(desired)
            return
        }
        guard downshift == nil else { return }
        let sid = context.info.sid
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.context?.info.sid == sid else { return }
                self.downshift = nil
                if let d = self.desiredStreamScale(), d < (self.context?.streamScale ?? 1) { self.setStreamScale(d) }
            }
        }
        downshift = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: work)
    }

    private func setStreamScale(_ scale: Double) {
        guard var context else { return }
        let v = context.viewport.map { "\($0.displayedPixelWidth)×\($0.displayedPixelHeight)" } ?? "unknown"
        ReachLog.info("host", "stream scale \(context.streamScale) → \(scale) (iPhone shows the display at \(v) px)")
        context.streamScale = scale
        self.context = context
        startCapture()
    }

    private func selectDisplay(_ id: DisplayID) {
        guard var context else { return }
        displays.refresh()
        guard displays.display(id: id) != nil else {
            send(.notice(Notice(level: .warning, message: "That display isn't connected anymore.")))
            send(.displays(displays.displays, activeDisplayID: context.displayID))
            return
        }
        guard id != context.displayID else { return }
        context.displayID = id
        context.streamScale = desiredStreamScale(for: context) ?? 1
        self.context = context
        settings.preferredDisplayID = id
        updateGeometry()
        send(.displays(displays.displays, activeDisplayID: id))
        startCapture()
        cursor.refresh()
    }

    private func displaysChanged() {
        guard var context else { return }
        if displays.display(id: context.displayID) == nil, let main = displays.mainDisplay {
            context.displayID = main.id
        }
        context.streamScale = desiredStreamScale(for: context) ?? context.streamScale
        self.context = context
        updateGeometry()
        send(.displays(displays.displays, activeDisplayID: context.displayID))
        startCapture()
        cursor.refresh()
    }

    // Both act here on main and again later on an Accessibility queue, each time through `gate`, so
    // nothing happens once the session that asked has ended.

    private func activateApp(_ pid: Int32, gate: @escaping @Sendable (() -> Void) -> Bool) {
        var found = true
        guard gate({ found = apps.activate(pid: pid, whileCurrent: gate) }) else { return }
        if !found {
            send(.notice(Notice(level: .info, message: "That app isn't running anymore.")))
            sendApps(requested: false)
        }
    }

    private func focusWindow(_ id: UInt32, gate: @escaping @Sendable (() -> Void) -> Bool) {
        var found = true
        guard gate({ found = apps.focusWindow(id: id, whileCurrent: gate) }) else { return }
        if !found {
            send(.notice(Notice(level: .info, message: "That window was closed.")))
            send(.windows(apps.windows()))
        }
    }

    private func sendApps(requested: Bool) {
        guard var context else { return }
        if requested { context.appsRequested = true }
        let sent = context.sentIconPIDs
        let list = apps.runningApps { !sent.contains($0) }
        context.sentIconPIDs.formUnion(list.filter { $0.icon != nil }.map(\.pid))
        self.context = context
        AppListBatcher.batches(list).forEach { send(.apps($0)) }
    }

    private func appsChanged() {
        // Only keep the list fresh once the iPhone has shown interest in it.
        guard context?.appsRequested == true else { return }
        sendApps(requested: false)
    }

    private func send(_ message: HostMessage) {
        guard context != nil else { return }
        engine.send(message)
    }
}

// MARK: - InputInjectorDelegate

extension SessionController: InputInjectorDelegate {
    nonisolated func injectorNeedsAccessibility() {
        onMain {
            guard var context = self.context else { return }
            // Input arrives many times a second; remind at most every 15 s.
            let now = uptimeSeconds()
            guard now - context.lastAccessibilityNotice > 15 else { return }
            context.lastAccessibilityNotice = now
            self.context = context
            self.permissions.refresh()
            self.send(.permissions(self.permissions.current))
            self.send(.notice(Notice(level: .warning, message: "Allow Accessibility for Reach Host on your Mac so it can control the pointer and keyboard.")))
        }
    }

    nonisolated func injector(didFail notice: Notice) {
        onMain { self.send(.notice(notice)) }
    }
}
