import Foundation
import ReachProtocol

public enum HostAvailability: Sendable, Equatable {
    case online(HostInfo, connectedClientName: String?)
    case unreachable
}

/// Persists the Macs this iPhone has paired with. Kept in a secret store (the keychain on a
/// device): an entry includes the Mac's TURN server credentials.
public final class PairedHostStore: @unchecked Sendable {
    private let secrets: SecretStore
    private let key: String
    private let legacyDefaults: UserDefaults?
    private let legacyKey: String
    private let lock = NSLock()
    private var _hosts: [PairedHost]

    /// `legacyDefaults`: where earlier versions kept the list (TURN credentials included); it's moved
    /// into `secrets` and deleted from there as soon as `secrets` holds the list.
    public init(secrets: SecretStore, key: String = "paired-hosts",
                legacyDefaults: UserDefaults? = nil, legacyKey: String = "reach.pairedHosts") {
        self.secrets = secrets
        self.key = key
        self.legacyDefaults = legacyDefaults
        self.legacyKey = legacyKey
        if let data = secrets.load(key), let hosts = try? JSONDecoder().decode([PairedHost].self, from: data) {
            _hosts = hosts
            legacyDefaults?.removeObject(forKey: legacyKey)
        } else if let data = legacyDefaults?.data(forKey: legacyKey),
                  let hosts = try? JSONDecoder().decode([PairedHost].self, from: data) {
            _hosts = hosts
            do { try save() } catch { ReachLog.error("client", "couldn't move paired Macs to the keychain: \(error)") }
        } else {
            _hosts = []
        }
    }

    public var hosts: [PairedHost] { lock.withLock { _hosts } }

    public func host(id: String) -> PairedHost? { hosts.first { $0.id == id } }

    /// Adds or replaces a Mac. If that can't be saved, nothing changes and this throws.
    public func upsert(_ host: PairedHost) throws {
        try change { hosts in
            if let i = hosts.firstIndex(where: { $0.id == host.id }) { hosts[i] = host } else { hosts.append(host) }
        }
    }

    /// Changes a Mac's record if it's still paired (it may have been forgotten meanwhile); never adds
    /// one. Best effort: a failed save is logged.
    public func update(id: String, _ body: (inout PairedHost) -> Void) {
        do {
            try change { hosts in
                if let i = hosts.firstIndex(where: { $0.id == id }) { body(&hosts[i]) }
            }
        } catch {
            ReachLog.error("client", "couldn't save paired Macs: \(error)")
        }
    }

    /// Forgets a Mac. If that can't be saved, nothing changes and this throws.
    public func remove(id: String) throws {
        try change { $0.removeAll { $0.id == id } }
    }

    private func change(_ body: (inout [PairedHost]) -> Void) throws {
        try lock.withLock {
            let previous = _hosts
            body(&_hosts)
            guard _hosts != previous else { return }
            do { try save() } catch { _hosts = previous; throw error }
        }
    }

    /// Lock held (or not yet shared).
    private func save() throws {
        try secrets.save(key, JSONEncoder().encode(_hosts))
        legacyDefaults?.removeObject(forKey: legacyKey)
    }
}

/// iPhone-side entry point: pairing, presence checks, and starting sessions.
public final class ClientEngine: @unchecked Sendable {
    public let identity: LocalIdentity
    public let store: PairedHostStore
    public let deviceName: String
    public let deviceModel: String

    /// Main queue.
    public var onRelayStatus: ((Bool) -> Void)?

    let queue = DispatchQueue(label: "reach.client.engine", qos: .userInitiated)
    private let hub: SignalingHub
    private let replay = ReplayFilter()
    private var pendingPair: (code: PairingCode, completion: (Result<PairedHost, Error>) -> Void)?
    private var probeWaiters: [String: [(HostAvailability) -> Void]] = [:]
    private var sessions: [String: WeakSession] = [:]
    private var started = false

    private struct WeakSession { weak var session: ClientSession? }

    public init(identity: LocalIdentity, store: PairedHostStore, relays: [RelayEndpoint] = RelayEndpoint.defaults,
                deviceName: String, deviceModel: String) {
        self.identity = identity
        self.store = store
        self.deviceName = deviceName
        self.deviceModel = deviceModel
        self.hub = SignalingHub(ownID: identity.id, relays: relays, queue: queue)
        hub.onEnvelope = { [weak self] env in self?.handle(env) }
        hub.onStatus = { [weak self] online, _ in
            DispatchQueue.main.async { self?.onRelayStatus?(online) }
        }
    }

    public func start() {
        queue.async {
            guard !self.started else { return }
            self.started = true
            self.hub.start()
        }
    }

    public func stop() {
        queue.async {
            guard self.started else { return }
            self.started = false
            self.hub.stop()
        }
    }

    public var isRelayOnline: Bool { queue.sync { hub.isOnline } }

    // MARK: Pairing

    /// Pair with the Mac described by `code`. Completion on the main queue.
    public func pair(using code: PairingCode, timeout: TimeInterval = 25,
                     completion: @escaping (Result<PairedHost, Error>) -> Void) {
        start()
        queue.async {
            let proof = code.proof(clientID: self.identity.id, clientPublicKey: self.identity.publicKey)
            let msg = EnvelopeCrypto.makeMessage(.pairRequest(PairRequest(name: self.deviceName, model: self.deviceModel, proof: proof)))
            guard let data = try? EnvelopeCrypto.seal(msg, from: self.identity, to: code.hostID,
                                                      remotePublicKey: code.hostPublicKey, includeSenderKey: true) else {
                DispatchQueue.main.async { completion(.failure(ReachError.crypto("could not seal pairing request"))) }
                return
            }
            self.pendingPair = (code, { result in DispatchQueue.main.async { completion(result) } })
            self.publishWithRetry(data, to: code.hostID, attempts: 3, interval: 6) {
                self.pendingPair?.code.hostID == code.hostID
            }
            self.queue.asyncAfter(deadline: .now() + timeout) {
                guard let p = self.pendingPair, p.code.hostID == code.hostID else { return }
                self.pendingPair = nil
                p.completion(.failure(ReachError.timeout("Your Mac didn't answer. Make sure Reach is running on it and the code is still on screen.")))
            }
        }
    }

    // MARK: Presence

    /// Ask a paired Mac whether it's reachable right now. Completion on the main queue.
    public func probe(_ host: PairedHost, timeout: TimeInterval = 8, completion: @escaping (HostAvailability) -> Void) {
        start()
        queue.async {
            let first = self.probeWaiters[host.id] == nil
            self.probeWaiters[host.id, default: []].append { a in DispatchQueue.main.async { completion(a) } }
            guard first else { return }
            self.send(.probe, to: host)
            self.queue.asyncAfter(deadline: .now() + timeout) {
                guard let waiters = self.probeWaiters.removeValue(forKey: host.id) else { return }
                waiters.forEach { $0(.unreachable) }
            }
        }
    }

    // MARK: Sessions

    /// Start connecting. Hold on to the returned session; closing or releasing it ends the connection.
    public func connect(to host: PairedHost, hello: ClientHello, iceTransportPolicy: String? = nil) -> ClientSession {
        start()
        let session = ClientSession(engine: self, host: host, hello: hello, policyOverride: iceTransportPolicy)
        queue.async { session.begin() }
        return session
    }

    func register(_ session: ClientSession, sid: String) {
        sessions = sessions.filter { $0.value.session != nil }
        sessions[sid] = WeakSession(session: session)
    }

    func unregister(sid: String) {
        sessions.removeValue(forKey: sid)
    }

    // MARK: Signaling

    /// Seal and publish; returns the sealed bytes so callers can re-publish the identical message.
    @discardableResult
    func send(_ body: SignalBody, to host: PairedHost, completion: ((Bool) -> Void)? = nil) -> Data? {
        let msg = EnvelopeCrypto.makeMessage(body)
        guard let data = try? EnvelopeCrypto.seal(msg, from: identity, to: host.id, remotePublicKey: host.publicKey,
                                                  includeSenderKey: false) else { return nil }
        hub.send(data, toPeer: host.id, completion: completion)
        return data
    }

    func republish(_ data: Data, to hostID: String) {
        hub.send(data, toPeer: hostID)
    }

    /// Relays are best-effort (QoS 0). Re-publish the identical sealed message a few times while the
    /// caller is still waiting; the receiver de-duplicates by message id.
    func publishWithRetry(_ data: Data, to peerID: String, attempts: Int, interval: TimeInterval, stillWaiting: @escaping () -> Bool) {
        hub.send(data, toPeer: peerID)
        guard attempts > 1 else { return }
        queue.asyncAfter(deadline: .now() + interval) { [weak self] in
            guard let self, stillWaiting() else { return }
            self.publishWithRetry(data, to: peerID, attempts: attempts - 1, interval: interval, stillWaiting: stillWaiting)
        }
    }

    private func handle(_ env: Envelope) {
        let key: Data
        if let pending = pendingPair, pending.code.hostID == env.f {
            key = pending.code.hostPublicKey
        } else if let host = store.host(id: env.f) {
            key = host.publicKey
        } else {
            return
        }
        guard let msg = try? EnvelopeCrypto.open(env, local: identity, remotePublicKey: key), replay.admit(msg.id) else {
            ReachLog.error("client", "dropped unauthenticated or replayed message from \(env.f.prefix(8))")
            return
        }
        switch msg.body {
        case .pairResult(let r):
            guard let p = pendingPair, p.code.hostID == env.f else { return }
            pendingPair = nil
            if r.accepted {
                let host = PairedHost(id: env.f, publicKey: p.code.hostPublicKey, name: r.hostName, info: r.info,
                                      iceServers: r.iceServers, pairedAt: Date())
                do {
                    try store.upsert(host)
                    p.completion(.success(host))
                } catch {
                    ReachLog.error("client", "couldn't save the paired Mac: \(error)")
                    p.completion(.failure(ReachError.storage("This iPhone couldn't save the pairing. Show a new code on the Mac and try again.")))
                }
            } else {
                p.completion(.failure(ReachError.pairingRejected(r.reason ?? "unknown reason")))
            }

        case .probeAck(let status):
            store.update(id: env.f) { host in
                host.info = status.info
                host.name = status.info.name
                // Always the Mac's full current list, so a TURN server removed there is dropped here too.
                host.iceServers = status.iceServers
            }
            let waiters = probeWaiters.removeValue(forKey: env.f) ?? []
            waiters.forEach { $0(.online(status.info, connectedClientName: status.connectedClientName)) }

        case .answer(let sid, let sdp):
            session(sid, from: env.f)?.handleAnswer(sdp)
        case .candidates(let sid, let list):
            session(sid, from: env.f)?.handleCandidates(list)
        case .bye(let sid, let reason):
            session(sid, from: env.f)?.handleBye(reason)

        case .pairRequest, .probe, .offer:
            break
        }
    }

    /// The session `sid`, if it's with the Mac `hostID` (a Mac only gets to signal its own sessions).
    private func session(_ sid: String, from hostID: String) -> ClientSession? {
        guard let s = sessions[sid]?.session, s.host.id == hostID else { return nil }
        return s
    }
}
