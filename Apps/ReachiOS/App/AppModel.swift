import SwiftUI
import Observation
import os
import ReachCore
import ReachProtocol

/// App-wide state: the client engine, paired Macs and their live availability, and which flow
/// (pairing, session) is on screen.
@MainActor
@Observable
final class AppModel {
    enum Availability: Equatable {
        case unknown
        case checking
        case online(HostInfo, inUseBy: String?)
        case offline

        var isOnline: Bool {
            if case .online = self { return true }
            return false
        }
    }

    struct HostEntry: Identifiable, Equatable {
        var host: PairedHost
        var isDemo = false
        var demoAvailability: Availability = .unknown
        var id: String { host.id }
        var model: String? { host.info?.model }
    }

    struct PairingRequest: Identifiable {
        enum Mode { case scan, paste, code(PairingCode) }
        let id = UUID()
        var mode: Mode
    }

    struct AlertMessage: Identifiable {
        let id = UUID()
        var title: String
        var message: String
    }

    private(set) var hosts: [HostEntry] = []
    private(set) var availability: [String: Availability] = [:]
    private(set) var relaysReachable = true
    /// False until the engine has reported relay status at least once (it only runs once a Mac is paired).
    private(set) var relayStatusKnown = false
    var session: SessionController?
    var pairing: PairingRequest?
    var showSettings = false
    var alert: AlertMessage?

    @ObservationIgnored let engine: ClientEngine?
    @ObservationIgnored private var demoHosts: [HostEntry] = []
    @ObservationIgnored private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "reach", category: "app")
    @ObservationIgnored private var relayOfflineTask: Task<Void, Never>?

    init() {
        #if DEBUG
        // Pull with: xcrun devicectl device copy from --domain-type appDataContainer
        //   --domain-identifier <bundle id> --source Library/Caches/reach.log
        if let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first {
            ReachLog.mirror(to: caches.appendingPathComponent("reach.log"))
        }
        #endif
        AppSettings.registerDefaults()
        ShaderLibrary.prewarm()
        engine = Self.makeEngine()
        if LaunchOptions.demo, !LaunchOptions.emptyHome { demoHosts = Self.makeDemoHosts() }
        engine?.onRelayStatus = { [weak self] online in
            MainActor.assumeIsolated { self?.relayStatusChanged(online) }
        }
        reloadHosts()
        if !hosts.filter({ !$0.isDemo }).isEmpty { engine?.start() }
        if let p = LaunchOptions.pairing {
            pairing = PairingRequest(mode: p == "paste" ? .paste : .scan)
        }
    }

    var thisDeviceFingerprint: String { engine?.identity.fingerprint ?? "—" }

    private static func makeEngine() -> ClientEngine? {
        var secrets: SecretStore = KeychainStore(service: (Bundle.main.bundleIdentifier ?? "reach") + ".client")
        let identity: LocalIdentity
        do {
            identity = try LocalIdentity.loadOrCreate(in: secrets, key: "client-identity")
        } catch {
            #if targetEnvironment(simulator)
            // The keychain can be unavailable in unsigned simulator builds; keep a stable identity on disk
            // rather than a new one every launch (which would orphan every pairing).
            let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("Identity", isDirectory: true)
            secrets = FileSecretStore(directory: dir)
            guard let fallback = try? LocalIdentity.loadOrCreate(in: secrets, key: "client-identity") else {
                return nil
            }
            identity = fallback
            #else
            // On a device the private key stays in the keychain or nowhere.
            ReachLog.error("app", "couldn't load this iPhone's identity from the keychain: \(error)")
            return nil
            #endif
        }
        return ClientEngine(identity: identity, store: PairedHostStore(secrets: secrets, legacyDefaults: .standard),
                            deviceName: UIDevice.current.name, deviceModel: DeviceInfo.modelIdentifier)
    }

    // MARK: Hosts

    func reloadHosts() {
        let real = (engine?.store.hosts ?? []).map { HostEntry(host: $0) }
        let sorted = real.sorted { ($0.host.lastConnectedAt ?? $0.host.pairedAt) > ($1.host.lastConnectedAt ?? $1.host.pairedAt) }
        hosts = demoHosts + sorted
        for entry in hosts where availability[entry.id] == nil {
            availability[entry.id] = .unknown
        }
    }

    func availability(of entry: HostEntry) -> Availability { availability[entry.id] ?? .unknown }

    /// Ask every paired Mac whether it's reachable. Returns when all have answered or timed out.
    func refreshAvailability() async {
        await withTaskGroup(of: Void.self) { group in
            for entry in hosts {
                if !availability(of: entry).isOnline { availability[entry.id] = .checking }
                group.addTask { await self.probe(entry) }
            }
        }
    }

    private func probe(_ entry: HostEntry) async {
        if entry.isDemo {
            try? await Task.sleep(for: .milliseconds(Int.random(in: 500...1100)))
            availability[entry.id] = entry.demoAvailability
            return
        }
        guard let engine else { return }
        let result: HostAvailability = await withCheckedContinuation { cont in
            engine.probe(entry.host) { cont.resume(returning: $0) }
        }
        switch result {
        case .online(let info, let client): availability[entry.id] = .online(info, inUseBy: client)
        case .unreachable: availability[entry.id] = .offline
        }
        reloadHosts()
    }

    func forget(_ entry: HostEntry) {
        if entry.isDemo {
            demoHosts.removeAll { $0.id == entry.id }
        } else {
            do {
                try engine?.store.remove(id: entry.id)
            } catch {
                logger.error("couldn't forget a Mac: \(error.localizedDescription, privacy: .public)")
                alert = AlertMessage(title: "Couldn’t Forget Mac", message: "This iPhone couldn’t save the change. Try again.")
                return
            }
        }
        availability.removeValue(forKey: entry.id)
        reloadHosts()
    }

    private func relayStatusChanged(_ online: Bool) {
        relayStatusKnown = true
        relayOfflineTask?.cancel()
        if online {
            relaysReachable = true
        } else {
            // Relay sockets flap briefly on network changes; only surface a sustained outage.
            relayOfflineTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(6))
                guard !Task.isCancelled else { return }
                self?.relaysReachable = false
            }
        }
    }

    // MARK: Sessions

    func connect(_ entry: HostEntry) {
        guard session == nil else { return }
        let info: HostInfo? = {
            if case .online(let i, _) = availability(of: entry) { return i }
            return entry.host.info
        }()
        let host = SessionHost(id: entry.id, name: entry.host.name, model: info?.model, isDemo: entry.isDemo)
        let controller: SessionController
        if entry.isDemo {
            let scenario: DemoSessionSource.Scenario = entry.demoAvailability == .offline ? .offline : .normal
            controller = SessionController(host: host) { quality in DemoSessionSource(scenario: scenario, quality: quality) }
        } else {
            guard let engine else {
                alert = AlertMessage(title: "Can’t Connect", message: "This iPhone’s identity couldn’t be loaded.")
                return
            }
            let paired = entry.host
            controller = SessionController(host: host) { quality in
                let current = engine.store.host(id: paired.id) ?? paired
                return engine.connect(to: current, hello: Self.makeHello(quality: quality))
            }
        }
        controller.onFinish = { [weak self, weak controller] in
            guard let self, self.session === controller else { return }
            self.session = nil
            self.reloadHosts()
            Task { await self.refreshAvailability() }
        }
        // Home is hidden for the whole session, which may end because the Mac went away. Don't come back claiming
        // "Online" until a fresh probe answers (set now, so the card doesn't visibly cross-fade from a stale state).
        availability[entry.id] = .checking
        session = controller
        controller.start()
    }

    static func makeHello(quality: QualityPreference) -> ClientHello {
        let px = DeviceInfo.nativeScreenPixels
        return ClientHello(name: UIDevice.current.name, deviceModel: DeviceInfo.modelIdentifier, appVersion: DeviceInfo.appVersion,
                           screenPixelWidth: px.width, screenPixelHeight: px.height, quality: quality)
    }

    // MARK: Pairing

    func beginPairing(_ mode: PairingRequest.Mode) {
        pairing = PairingRequest(mode: mode)
    }

    /// Completion on main.
    func pair(_ code: PairingCode, completion: @escaping (Result<PairedHost, Error>) -> Void) {
        guard let engine else {
            completion(.failure(ReachError.storage("This iPhone’s identity couldn’t be loaded.")))
            return
        }
        engine.pair(using: code) { [weak self] result in
            MainActor.assumeIsolated {
                if case .success(let host) = result {
                    self?.reloadHosts()
                    self?.availability[host.id] = host.info.map { .online($0, inUseBy: nil) } ?? .unknown
                }
                completion(result)
            }
        }
    }

    func entry(for host: PairedHost) -> HostEntry? { hosts.first { $0.id == host.id } }

    func handleOpenURL(_ url: URL) {
        guard url.scheme?.lowercased() == PairingCode.scheme else { return }
        guard url.host?.lowercased() == "pair" else { return }
        do {
            let code = try PairingCode(string: url.absoluteString)
            pairing = PairingRequest(mode: .code(code))
        } catch {
            alert = AlertMessage(title: "Invalid Pairing Code", message: (error as? LocalizedError)?.errorDescription ?? "That code couldn’t be read.")
        }
    }

    // MARK: App lifecycle

    func scenePhaseChanged(_ phase: ScenePhase) {
        switch phase {
        case .active:
            session?.appDidBecomeActive()
            if session == nil { Task { await refreshAvailability() } }
        case .background:
            session?.appDidEnterBackground()
        default:
            break
        }
    }

    func autoConnectDemoIfRequested() {
        guard LaunchOptions.demoAutoConnect, session == nil, let demo = hosts.first(where: { $0.isDemo }) else { return }
        connect(demo)
    }

    // MARK: Demo

    private static func makeDemoHosts() -> [HostEntry] {
        let key = Data(repeating: 7, count: 32)
        let now = Date()
        func host(_ id: String, _ name: String, _ model: String, _ ident: String, lastUsed: TimeInterval?) -> PairedHost {
            PairedHost(id: id, publicKey: key, name: name,
                       info: HostInfo(name: name, model: model, modelIdentifier: ident, osVersion: "macOS 26.1", appVersion: "1.0"),
                       iceServers: [], pairedAt: now.addingTimeInterval(-86400 * 20),
                       lastConnectedAt: lastUsed.map { now.addingTimeInterval(-$0) })
        }
        let mbp = host("demo-macbook", DemoSessionSource.hostInfo.name, "MacBook Pro", "Mac14,6", lastUsed: 7200)
        let studio = host("demo-studio", "Studio", "Mac Studio", "Mac14,13", lastUsed: 86400 * 3)
        let imac = host("demo-imac", "Family iMac", "iMac", "Mac15,4", lastUsed: nil)
        return [
            HostEntry(host: mbp, isDemo: true, demoAvailability: .online(mbp.info!, inUseBy: nil)),
            HostEntry(host: imac, isDemo: true, demoAvailability: .online(imac.info!, inUseBy: "Sara’s iPad")),
            HostEntry(host: studio, isDemo: true, demoAvailability: .offline),
        ]
    }
}
