import AppKit
import Observation
import ReachCore
import ReachProtocol

/// The app's state and the owner of everything that runs: the engine, the session controller and
/// the system integrations. The UI reads it and calls its actions; nothing else holds the engine.
@MainActor
@Observable
final class AppModel {
    enum Connectivity: Equatable {
        /// Starting up, or briefly reconnecting to the signaling relays.
        case connecting
        /// Reachable by paired iPhones.
        case online
        /// No relay reachable (usually no internet).
        case offline
        /// Couldn't start at all.
        case unavailable(String)
    }

    struct ActiveSession: Equatable {
        var clientID: String
        var deviceName: String
        var deviceModel: String
        var startedAt: Date
        var route: ConnectionRoute?
        var roundTripMs: Double?
    }

    private(set) var connectivity: Connectivity = .connecting
    private(set) var session: ActiveSession?
    private(set) var pairedDevices: [TrustedClient] = []
    let hostInfo: HostInfo
    let modelSymbol: String
    let fingerprint: String
    /// A non-fatal problem worth surfacing (e.g. the keychain was unavailable).
    private(set) var problem: String?
    /// The optional relay server, shared with paired iPhones.
    private(set) var turnServer: TurnServer?

    let permissions: PermissionMonitor
    let loginItem: LoginItemController
    let pairing: PairingSession

    var keepAwake: Bool {
        didSet {
            settings.keepAwake = keepAwake
            power?.setKeepAwake(keepAwake)
        }
    }

    @ObservationIgnored let windows = WindowCoordinator()
    @ObservationIgnored private let settings = AppSettings()
    @ObservationIgnored private let engine: HostEngine?
    @ObservationIgnored private let power: PowerManager?
    @ObservationIgnored private let keyboardLayouts: KeyboardLayoutProvider?
    @ObservationIgnored private let displays: DisplayCatalog?
    @ObservationIgnored private var controller: SessionController?
    @ObservationIgnored private var statsTimer: Timer?
    @ObservationIgnored private var offlineGrace: DispatchWorkItem?
    @ObservationIgnored private var started = false

    /// Relay connections flap; only report "offline" after it has lasted this long.
    private static let offlineGracePeriod: TimeInterval = 8
    private static let statsInterval: TimeInterval = 2

    // MARK: - Setup

    init() {
        let hostInfo = HostDescription.current()
        self.hostInfo = hostInfo
        modelSymbol = MacModel.current.symbolName
        keepAwake = AppSettings().keepAwake
        let turnServer = AppSettings().turnServer
        self.turnServer = turnServer
        permissions = PermissionMonitor()
        loginItem = LoginItemController()

        var problem: String?
        let identity: LocalIdentity
        do {
            identity = try LocalIdentity.loadOrCreate(in: KeychainStore(service: AppSettings.keychainService), key: "host-identity")
        } catch {
            // Without the keychain the Mac gets a new identity every launch, so pairings won't survive
            // a restart, but remote access still works for this run.
            ReachLog.error("host", "identity unavailable: \(error)")
            identity = .generate()
            problem = "Couldn't access the keychain. Paired iPhones will need to pair again after Reach Host restarts."
        }
        self.problem = problem
        fingerprint = identity.fingerprint

        let trustStore = TrustStore(fileURL: AppSettings.trustStoreURL)
        let engine = HostEngine(identity: identity, trustStore: trustStore, iceServers: TurnServer.iceServers(with: turnServer),
                                hostInfo: { HostDescription.current() })
        self.engine = engine
        pairing = PairingSession(backend: .init(
            makeCode: { [engine] in engine.makePairingCode(hostName: HostDescription.computerName()) },
            cancel: { [engine] in engine.cancelPairing() }))

        let power = PowerManager()
        let displays = DisplayCatalog()
        let layouts = KeyboardLayoutProvider()
        self.power = power
        self.displays = displays
        keyboardLayouts = layouts
        controller = SessionController(engine: engine, displays: displays, geometry: DisplayGeometry(),
                                       permissions: permissions, power: power, keyboardLayouts: layouts)
    }

    /// Fixed state for UI snapshots; runs nothing.
    init(preview: PreviewState) {
        hostInfo = preview.hostInfo
        modelSymbol = MacModel.symbolName(forFamily: preview.hostInfo.model)
        fingerprint = preview.fingerprint
        keepAwake = preview.keepAwake
        turnServer = preview.turnServer
        permissions = PermissionMonitor(previewScreenRecording: preview.screenRecording, accessibility: preview.accessibility,
                                        needsRelaunch: preview.needsRelaunch)
        loginItem = LoginItemController(previewEnabled: preview.launchAtLogin)
        pairing = PairingSession(previewState: preview.pairing)
        connectivity = preview.connectivity
        session = preview.session
        pairedDevices = preview.pairedDevices
        problem = nil
        engine = nil
        power = nil
        keyboardLayouts = nil
        displays = nil
    }

    func start() {
        guard !started, let engine, let controller, let displays else { return }
        started = true
        engine.delegate = controller
        controller.observer = self
        permissions.onChange = { [weak self] permissions in self?.controller?.permissionsChanged(permissions) }
        permissions.startMonitoring()
        keyboardLayouts?.start()
        displays.startObserving()
        power?.setKeepAwake(keepAwake)
        pairedDevices = sortedDevices(engine.trustedClients)
        engine.start()
        #if DEBUG
        // Test hook: pair a simulator or reach-probe without the pairing window.
        if let path = ProcessInfo.processInfo.environment["REACH_DEBUG_PAIRING_URL_FILE"] {
            let code = engine.makePairingCode(hostName: HostDescription.computerName())
            try? code.url.absoluteString.write(toFile: path, atomically: true, encoding: .utf8)
        }
        #endif
        scheduleOfflineCheck()
        // Missing permissions after that are flagged in the menu rather than by reopening the guide.
        if !settings.hasCompletedOnboarding { showOnboarding() }
    }

    /// Ends the session and stops the engine. Returns `true` when there was something to wind down
    /// (so quitting can give the goodbye message a moment to go out).
    @discardableResult
    func shutdown() -> Bool {
        let hadSession = session != nil
        statsTimer?.invalidate()
        engine?.stop()
        power?.releaseAll()
        return hadSession
    }

    // MARK: - Actions

    func disconnect() {
        controller?.disconnect()
    }

    func remove(_ device: TrustedClient) {
        do {
            try engine?.revoke(clientID: device.id)
        } catch {
            problem = "Couldn't save the list of paired devices. \(device.name) can't connect now, but will be able to again after Reach Host restarts. Remove it again then."
        }
        pairedDevices.removeAll { $0.id == device.id }
    }

    /// Saves the relay server (`nil` removes it) and applies it right away: the next session uses it,
    /// and iPhones pick it up the next time they check on this Mac. Throws if it couldn't be saved.
    func setTurnServer(_ server: TurnServer?) throws {
        try settings.setTurnServer(server)
        turnServer = server
        engine?.setIceServers(TurnServer.iceServers(with: server))
    }

    func showPairing() {
        windows.showPairing(model: self)
    }

    func showOnboarding() {
        windows.showOnboarding(model: self)
    }

    func completeOnboarding() {
        settings.hasCompletedOnboarding = true
        windows.closeOnboarding()
    }

    /// Screen Recording applies only to processes launched after it's granted.
    func relaunch() {
        let path = Bundle.main.bundlePath
        let pid = ProcessInfo.processInfo.processIdentifier
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        // Wait for this process to exit (so the new one isn't refused as a duplicate), then reopen.
        process.arguments = ["-c", "while /bin/kill -0 \(pid) 2>/dev/null; do /bin/sleep 0.1; done; /usr/bin/open \"$0\"", path]
        do {
            try process.run()
            NSApp.terminate(nil)
        } catch {
            ReachLog.error("host", "relaunch failed: \(error.localizedDescription)")
        }
    }

    func quit() {
        NSApp.terminate(nil)
    }

    // MARK: - Private

    private func sortedDevices(_ devices: [TrustedClient]) -> [TrustedClient] {
        devices.sorted { ($0.lastConnectedAt ?? $0.pairedAt) > ($1.lastConnectedAt ?? $1.pairedAt) }
    }

    private func scheduleOfflineCheck() {
        offlineGrace?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.connectivity == .connecting else { return }
                self.connectivity = .offline
            }
        }
        offlineGrace = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.offlineGracePeriod, execute: work)
    }

    private func startStatsPolling() {
        statsTimer?.invalidate()
        let timer = Timer(timeInterval: Self.statsInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.pollStats() }
        }
        timer.tolerance = 0.5
        RunLoop.main.add(timer, forMode: .common)
        statsTimer = timer
        pollStats()
    }

    private func pollStats() {
        engine?.stats { [weak self] stats in
            MainActor.assumeIsolated {
                guard let self, var session = self.session, let stats else { return }
                session.route = stats.route == .unknown ? nil : stats.route
                session.roundTripMs = stats.roundTripMs
                if session != self.session { self.session = session }
            }
        }
    }
}

// MARK: - SessionControllerObserver

extension AppModel: SessionControllerObserver {
    func relayStatusChanged(online: Bool) {
        if online {
            offlineGrace?.cancel()
            connectivity = .online
        } else if connectivity == .online {
            connectivity = .connecting
            scheduleOfflineCheck()
        }
    }

    func sessionStarted(_ session: HostSessionInfo) {
        self.session = ActiveSession(clientID: session.client.id, deviceName: session.client.name, deviceModel: session.client.deviceModel,
                                     startedAt: session.startedAt)
        if let engine { pairedDevices = sortedDevices(engine.trustedClients) }
        startStatsPolling()
    }

    func sessionEnded(_ session: HostSessionInfo, reason: String) {
        self.session = nil
        statsTimer?.invalidate()
        statsTimer = nil
    }

    func didPair(_ client: TrustedClient) {
        if let engine { pairedDevices = sortedDevices(engine.trustedClients) }
        pairing.didPair(deviceName: client.name)
        windows.pairingSucceeded()
    }
}

// MARK: - Preview state

struct PreviewState {
    var hostInfo = HostInfo(name: "Alex's MacBook Pro", model: "MacBook Pro", modelIdentifier: "Mac14,6",
                            osVersion: "macOS 27.0", appVersion: "1.0")
    var fingerprint = "7F3A-91C2"
    var connectivity: AppModel.Connectivity = .online
    var session: AppModel.ActiveSession?
    var pairedDevices: [TrustedClient] = []
    var screenRecording = true
    var accessibility = true
    var needsRelaunch = false
    var keepAwake = true
    var launchAtLogin = true
    var turnServer: TurnServer?
    var pairing: PairingSession.State = .idle
}
