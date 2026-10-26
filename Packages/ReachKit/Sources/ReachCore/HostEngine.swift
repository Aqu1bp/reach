import Foundation
import CoreVideo
import WebRTC
import ReachProtocol

public struct HostSessionInfo: Hashable, Sendable {
    public var sid: String
    public var client: TrustedClient
    public var startedAt: Date
    public var isConnected: Bool
}

/// Callbacks from the host engine.
///
/// Lifecycle callbacks arrive on the main queue. `didReceive` and `didReceivePointer` arrive on a
/// dedicated serial user-interactive queue, in order, so input can be injected without waiting on
/// the main thread.
public protocol HostEngineDelegate: AnyObject {
    func hostEngine(_ engine: HostEngine, relayStatusChanged online: Bool)
    func hostEngine(_ engine: HostEngine, didPair client: TrustedClient)
    func hostEngine(_ engine: HostEngine, sessionDidStart session: HostSessionInfo)
    func hostEngine(_ engine: HostEngine, sessionDidEnd session: HostSessionInfo, reason: String)
    func hostEngine(_ engine: HostEngine, didReceive message: ClientMessage)
    func hostEngine(_ engine: HostEngine, didReceivePointer packet: PointerPacket)
    /// The session's input has stopped: no more `didReceive` or `didReceivePointer` calls for it.
    /// Called synchronously on the engine's internal queue as the session ends, before
    /// `sessionDidEnd`, so input still queued elsewhere can be dropped and held keys released at once.
    /// Must not call back into the engine synchronously.
    func hostEngine(_ engine: HostEngine, inputDidStopFor session: HostSessionInfo)
    /// Every couple of seconds while connected (main queue): route, round trip, bandwidth estimate.
    func hostEngine(_ engine: HostEngine, didMeasure stats: ConnectionStats)
}

public extension HostEngineDelegate {
    func hostEngine(_ engine: HostEngine, inputDidStopFor session: HostSessionInfo) {}
    func hostEngine(_ engine: HostEngine, didMeasure stats: ConnectionStats) {}
}

/// Persists the iPhones this Mac trusts (public keys only — nothing secret).
public final class TrustStore: @unchecked Sendable {
    private let url: URL
    private let lock = NSLock()
    private var _clients: [TrustedClient]

    public init(fileURL: URL) {
        url = fileURL
        _clients = (try? JSONDecoder().decode([TrustedClient].self, from: Data(contentsOf: fileURL))) ?? []
    }

    public var clients: [TrustedClient] { lock.withLock { _clients } }

    public func client(id: String) -> TrustedClient? { lock.withLock { _clients.first { $0.id == id } } }

    /// Adds or replaces a device. If that can't be saved, nothing changes and this throws.
    public func upsert(_ client: TrustedClient) throws {
        try lock.withLock {
            let previous = _clients
            _clients.removeAll { $0.id == client.id }
            _clients.append(client)
            do { try persist() } catch { _clients = previous; throw error }
        }
    }

    /// Notes that a trusted device connected. Never adds one: returns nil if the device isn't
    /// trusted (any more), otherwise the updated record.
    public func recordConnection(id: String, at date: Date) -> TrustedClient? {
        lock.withLock {
            guard let i = _clients.firstIndex(where: { $0.id == id }) else { return nil }
            _clients[i].lastConnectedAt = date
            // Only the date is at stake, so a failed save isn't worth refusing the connection over.
            do { try persist() } catch { ReachLog.error("host", "couldn't save the last-connected date: \(error)") }
            return _clients[i]
        }
    }

    /// Stops trusting the device right away. Throws if that couldn't be saved, in which case the
    /// device is trusted again the next time the list is loaded.
    public func remove(id: String) throws {
        try lock.withLock {
            _clients.removeAll { $0.id == id }
            try persist()
        }
    }

    private func persist() throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(_clients).write(to: url, options: .atomic)
    }
}

public final class HostEngine: @unchecked Sendable {
    public weak var delegate: HostEngineDelegate?

    public let identity: LocalIdentity
    public let trustStore: TrustStore
    /// Test hook: restrict ICE (e.g. `.relay` to force TURN).
    public var iceTransportPolicyOverride: String?

    private let hostInfoProvider: () -> HostInfo
    private let queue = DispatchQueue(label: "reach.host.engine", qos: .userInitiated)
    private let inputQueue = DispatchQueue(label: "reach.host.input", qos: .userInteractive)
    private let hub: SignalingHub
    private let replay = ReplayFilter()
    /// Pairing requests come from devices nobody has vouched for yet, so they get their own replay
    /// filter (they can't crowd out trusted ones) and a rate limit.
    private let pairingReplay = ReplayFilter()
    private var pairingAttempts: [Date] = []
    /// Bumped whenever a session starts or ends. Input is tagged with the value current when it
    /// arrived and dropped if it changed while the input waited, so nothing an ended (or unpaired)
    /// session sent reaches the Mac afterwards.
    private let inputGenerationLock = NSLock()
    private var _inputGeneration = 0

    /// STUN/TURN servers for new sessions, also shared with iPhones when they pair and in every
    /// probe answer. Engine queue only; change with `setIceServers(_:)`.
    private var iceServers: [IceServerConfig]
    private var pairing: (code: PairingCode, expires: Date)?
    private var session: PeerSession?
    private var sessionInfo: HostSessionInfo?
    private var sessionCandidatesReady = false
    private var pendingLocalCandidates: [IceCandidateInfo] = []
    private var candidateFlushScheduled = false
    private var disconnectTimer: DispatchWorkItem?
    private var quality = QualityPreference()

    // Video
    private let videoSource: RTCVideoSource
    private let capturer: RTCVideoCapturer
    private let videoLock = NSLock()
    private var lastBuffer: CVPixelBuffer?
    /// Stamped on each newly pushed buffer (`ScreenVideoEncoder.frameSerialKey`); re-sends keep it.
    private var frameSerial = 0
    private var lastPushAt: UInt64 = 0
    private var refreshCount = 0
    private var lastRefreshAt: UInt64 = 0
    private var refreshTimer: DispatchSourceTimer?
    private var videoTrack: RTCVideoTrack?
    private var inputSeq: UInt32 = 0
    private var hasInputSeq = false
    private var perf: PerfSampler?

    /// Test hook: `REACH_MAX_BITRATE_KBPS` caps the stream below what the quality mode allows, so
    /// `reach-probe bench` can stand in for a slow link (a loopback has ~50 Mbit/s to spare).
    private static let maxBitrateCapBps: Int? = {
        guard let kbps = ProcessInfo.processInfo.environment["REACH_MAX_BITRATE_KBPS"].flatMap({ Int($0) }), kbps > 0 else { return nil }
        return kbps * 1000
    }()

    public init(identity: LocalIdentity, trustStore: TrustStore, relays: [RelayEndpoint] = RelayEndpoint.defaults,
                iceServers: [IceServerConfig] = IceServerConfig.defaultSTUN, hostInfo: @escaping () -> HostInfo) {
        self.identity = identity
        self.trustStore = trustStore
        self.iceServers = iceServers
        self.hostInfoProvider = hostInfo
        self.hub = SignalingHub(ownID: identity.id, relays: relays, queue: queue)
        let factory = RTCEnvironment.shared.factory
        videoSource = factory.videoSource(forScreenCast: true)
        capturer = RTCVideoCapturer(delegate: videoSource)
        hub.onEnvelope = { [weak self] env in self?.handle(env) }
        hub.onStatus = { [weak self] online, _ in
            guard let self else { return }
            DispatchQueue.main.async { self.delegate?.hostEngine(self, relayStatusChanged: online) }
        }
    }

    // MARK: Lifecycle

    public func start() {
        hub.start()
        startRefreshTimer()
        ReachLog.info("host", "started; id=\(identity.id.prefix(8))… fingerprint=\(identity.fingerprint)")
    }

    public func stop() {
        queue.async {
            self.endSession(reason: "Host stopped", notifyClient: true)
            self.hub.stop()
            self.refreshTimer?.cancel()
            self.refreshTimer = nil
        }
    }

    public var isRelayOnline: Bool { queue.sync { hub.isOnline } }
    public var relayDetail: [String: RelayStatus] { queue.sync { hub.detail } }

    /// Replace the STUN/TURN servers (e.g. a TURN server was added or removed in settings). Used
    /// from the next session on; iPhones get the new list in their next probe answer (they probe
    /// from Home and alongside every connection attempt). A session in progress keeps its current
    /// path. Safe from any thread.
    public func setIceServers(_ servers: [IceServerConfig]) {
        queue.async {
            self.iceServers = servers
            ReachLog.info("host", "ICE servers: \(servers.count) (\(servers.contains { $0.isRelay } ? "with" : "no") TURN)")
        }
    }

    // MARK: Pairing

    /// A fresh single-use pairing code, valid for ten minutes. Any previous code stops working.
    public func makePairingCode(hostName: String, validFor: TimeInterval = 600) -> PairingCode {
        let code = PairingCode(hostID: identity.id, hostPublicKey: identity.publicKey, secret: randomData(16), hostName: hostName)
        queue.sync { pairing = (code, Date().addingTimeInterval(validFor)) }
        return code
    }

    public func cancelPairing() {
        queue.async { self.pairing = nil }
    }

    public var trustedClients: [TrustedClient] { trustStore.clients }

    /// Stops trusting the device and ends its session; by the time this returns, nothing more from
    /// the device reaches the Mac. Throws if the change couldn't be saved; the device is still
    /// refused until Reach Host restarts, but trusted again after that. Don't call from the engine's
    /// own queue.
    public func revoke(clientID: String) throws {
        dispatchPrecondition(condition: .notOnQueue(queue))
        // On the engine queue, so it can't interleave with a session starting for this device.
        try queue.sync {
            defer {
                if sessionInfo?.client.id == clientID { endSession(reason: "Device was unpaired", notifyClient: true) }
            }
            try trustStore.remove(id: clientID)
        }
    }

    // MARK: Session

    public var activeSession: HostSessionInfo? { queue.sync { sessionInfo } }

    public func disconnect(reason: String = "Disconnected from the Mac") {
        queue.async { self.endSession(reason: reason, notifyClient: true) }
    }

    /// Send a control message to the connected iPhone. Safe from any thread.
    public func send(_ message: HostMessage) {
        guard let data = try? WireCodec.encode(message) else { return }
        queue.async {
            guard let s = self.session else { return }
            if !s.sendControl(data) { ReachLog.error("host", "control message (\(data.count) bytes) not sent") }
        }
    }

    /// Send a cursor position update on the unreliable channel. Safe from any thread.
    public func sendCursor(_ packet: CursorPacket) {
        let data = packet.encoded()
        queue.async { self.session?.sendFast(data) }
    }

    public func stats(completion: @escaping (ConnectionStats?) -> Void) {
        queue.async {
            guard let s = self.session else { DispatchQueue.main.async { completion(nil) }; return }
            s.pc.statistics { report in
                let stats = ConnectionStats(report: report, role: .host)
                DispatchQueue.main.async { completion(stats) }
            }
        }
    }

    // MARK: Video

    /// Feed a captured frame (NV12 or BGRA, ideally IOSurface-backed). Safe from any thread.
    public func pushVideoFrame(_ buffer: CVPixelBuffer, timestampNs: Int64? = nil) {
        let now = DispatchTime.now().uptimeNanoseconds
        videoLock.withLock {
            // A new picture gets a new serial, so the encoder can tell it from a re-send even when
            // ScreenCaptureKit reuses a buffer it has seen before.
            frameSerial += 1
            CVBufferSetAttachment(buffer, ScreenVideoEncoder.frameSerialKey, frameSerial as CFNumber, .shouldNotPropagate)
            lastBuffer = buffer
            lastPushAt = now
            refreshCount = 0
        }
        deliver(buffer, timestampNs: timestampNs ?? Int64(now))
    }

    /// Forget the retained frame (e.g. when switching displays) so it isn't re-sent.
    public func clearLastFrame() {
        videoLock.withLock { lastBuffer = nil }
    }

    private func deliver(_ buffer: CVPixelBuffer, timestampNs: Int64) {
        let frame = RTCVideoFrame(buffer: RTCCVPixelBuffer(pixelBuffer: buffer), rotation: ._0, timeStampNs: timestampNs)
        videoSource.capturer(capturer, didCapture: frame)
    }

    /// Screen capture only produces frames when something changes. After motion stops, re-send the
    /// last frame at the full frame rate for a moment: the encoder sharpens a still picture a little
    /// with every frame, so the end of a scroll goes from motion quality to crisp text within about a
    /// second. (The encoder skips these repeats when the change was too small to need it, e.g. a
    /// blinking caret, so an idle screen costs nothing.)
    private static let refreshSchedule: [UInt64] = stride(from: 34.0, through: 1500, by: 1000.0 / 60).map { UInt64($0 * 1_000_000) }

    /// After that, the last frame goes out once a second. The encoder ignores it if it already sent
    /// that picture; but if the video path was down when the screen last changed (a network switch
    /// right as the session starts), it's what gets the picture through as soon as the path is back,
    /// instead of waiting for something on screen to change.
    private static let keepaliveInterval: UInt64 = 1_000_000_000

    private func startRefreshTimer() {
        let t = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "reach.host.refresh", qos: .userInitiated))
        t.schedule(deadline: .now() + 0.05, repeating: 1.0 / 60, leeway: .milliseconds(2))
        t.setEventHandler { [weak self] in
            guard let self else { return }
            let now = DispatchTime.now().uptimeNanoseconds
            let toSend: CVPixelBuffer? = self.videoLock.withLock {
                guard self._sessionActive, let b = self.lastBuffer else { return nil }
                if self.refreshCount < Self.refreshSchedule.count {
                    guard now &- self.lastPushAt >= Self.refreshSchedule[self.refreshCount] else { return nil }
                    self.refreshCount += 1
                } else {
                    guard now &- self.lastRefreshAt >= Self.keepaliveInterval else { return nil }
                }
                self.lastRefreshAt = now
                return b
            }
            if let toSend { self.deliver(toSend, timestampNs: Int64(now)) }
        }
        t.resume()
        refreshTimer = t
    }

    private var _sessionActive = false

    /// Re-send the most recent frame now (e.g. right after a session starts on a static screen).
    public func resendLastFrame() {
        let now = DispatchTime.now().uptimeNanoseconds
        let b: CVPixelBuffer? = videoLock.withLock { refreshCount = 0; lastPushAt = now; return lastBuffer }
        if let b { deliver(b, timestampNs: Int64(DispatchTime.now().uptimeNanoseconds)) }
    }

    // MARK: Quality

    public func applyQuality(_ pref: QualityPreference) {
        queue.async {
            self.quality = pref
            self.applyEncoderParameters()
        }
    }

    private func applyEncoderParameters() {
        guard let sender = session?.videoTransceiver?.sender else { return }
        let params = sender.parameters
        guard let enc = params.encodings.first else { return }
        let fps = max(10, min(120, quality.maxFramesPerSecond))
        enc.maxFramerate = NSNumber(value: fps)
        enc.networkPriority = .high
        enc.bitratePriority = 4
        switch quality.mode {
        // The host app picks the stream size itself (what the iPhone shows × what the network carries),
        // so WebRTC's own adaptation stays out of it: left on, it cuts the frame rate while the
        // bandwidth estimate is still ramping up and takes many seconds to restore it — visible as
        // choppy motion. Under pressure the encoder spends fewer bits per frame instead, and the
        // refresh frames sharpen the picture again as soon as motion stops.
        case .sharp:
            enc.maxBitrateBps = 40_000_000
            enc.scaleResolutionDownBy = 1
            params.degradationPreference = NSNumber(value: RTCDegradationPreference.maintainFramerateAndResolution.rawValue)
        case .balanced:
            enc.maxBitrateBps = 30_000_000
            enc.scaleResolutionDownBy = 1
            params.degradationPreference = NSNumber(value: RTCDegradationPreference.maintainFramerateAndResolution.rawValue)
        case .smooth:
            enc.maxBitrateBps = 30_000_000
            enc.scaleResolutionDownBy = 1
            params.degradationPreference = NSNumber(value: RTCDegradationPreference.maintainFramerate.rawValue)
        case .dataSaver:
            // The host app caps the stream at half resolution in this mode (cheaper than scaling here).
            enc.maxBitrateBps = 1_500_000
            enc.scaleResolutionDownBy = 1
            enc.maxFramerate = NSNumber(value: min(fps, 30))
            params.degradationPreference = NSNumber(value: RTCDegradationPreference.balanced.rawValue)
        }
        enc.minBitrateBps = 150_000
        if let cap = Self.maxBitrateCapBps {
            enc.maxBitrateBps = NSNumber(value: min(enc.maxBitrateBps?.intValue ?? cap, cap))
            // WebRTC rejects parameters whose minimum exceeds their maximum, which would drop the whole
            // update (cap included) for caps below the usual 150 kbit/s floor.
            enc.minBitrateBps = NSNumber(value: min(150_000, cap))
        }
        sender.parameters = params
        ReachLog.info("host", "encoder: mode=\(quality.mode.rawValue) fps=\(fps) max=\(enc.maxBitrateBps ?? 0)")
    }

    // MARK: Signaling

    private func handle(_ env: Envelope) {
        if let keyString = env.k {
            handlePairingEnvelope(env, senderKey: keyString)
            return
        }
        guard let client = trustStore.client(id: env.f) else {
            ReachLog.debug("host", "ignoring message from unknown peer \(env.f.prefix(8))")
            return
        }
        let msg: SignalMessage
        do {
            msg = try EnvelopeCrypto.open(env, local: identity, remotePublicKey: client.publicKey)
        } catch {
            ReachLog.error("host", "rejected envelope from \(client.name): \(error)")
            return
        }
        guard replay.admit(msg.id) else { return }
        handle(msg.body, from: client)
    }

    private func handlePairingEnvelope(_ env: Envelope, senderKey: String) {
        let now = Date()
        pairingAttempts.removeAll { now.timeIntervalSince($0) > 60 }
        guard pairingAttempts.count < 20 else { return }
        pairingAttempts.append(now)
        guard let pub = Data(base64URL: senderKey), pub.count == 32,
              let msg = try? EnvelopeCrypto.open(env, local: identity, remotePublicKey: pub),
              pairingReplay.admit(msg.id), case .pairRequest(let req) = msg.body else { return }
        let info = hostInfoProvider()
        func reply(_ result: PairResult) {
            let m = EnvelopeCrypto.makeMessage(.pairResult(result))
            if let data = try? EnvelopeCrypto.seal(m, from: identity, to: env.f, remotePublicKey: pub, includeSenderKey: false) {
                hub.send(data, toPeer: env.f)
            }
        }
        guard let p = pairing, p.expires > Date() else {
            ReachLog.info("host", "pair request from \(req.name) but no active pairing code")
            // Rejections go to devices that haven't proven anything, so they don't name this Mac.
            reply(PairResult(accepted: false, reason: "The pairing code expired. Open Reach on your Mac and show a new code.",
                             hostName: "", info: nil, iceServers: []))
            return
        }
        guard PairingCode.isValidProof(req.proof, secret: p.code.secret, clientID: env.f, clientPublicKey: pub) else {
            ReachLog.error("host", "pair request from \(req.name) with bad proof")
            reply(PairResult(accepted: false, reason: "The pairing code didn't match.", hostName: "", info: nil, iceServers: []))
            return
        }
        pairing = nil // single use
        let client = TrustedClient(id: env.f, publicKey: pub, name: req.name, deviceModel: req.model, pairedAt: Date())
        do {
            try trustStore.upsert(client)
        } catch {
            ReachLog.error("host", "couldn't save the paired device: \(error)")
            reply(PairResult(accepted: false, reason: "The Mac couldn't save the pairing. Show a new code on the Mac and try again.",
                             hostName: "", info: nil, iceServers: []))
            return
        }
        ReachLog.info("host", "paired with \(req.name) (\(client.fingerprint))")
        reply(PairResult(accepted: true, reason: nil, hostName: info.name, info: info, iceServers: iceServers))
        DispatchQueue.main.async { self.delegate?.hostEngine(self, didPair: client) }
    }

    private func sendSignal(_ body: SignalBody, to client: TrustedClient) {
        let m = EnvelopeCrypto.makeMessage(body)
        guard let data = try? EnvelopeCrypto.seal(m, from: identity, to: client.id, remotePublicKey: client.publicKey,
                                                  includeSenderKey: false) else { return }
        hub.send(data, toPeer: client.id)
    }

    private func handle(_ body: SignalBody, from client: TrustedClient) {
        switch body {
        case .probe:
            let busy = sessionInfo.flatMap { $0.client.id == client.id ? nil : $0.client.name }
            sendSignal(.probeAck(HostStatus(info: hostInfoProvider(), connectedClientName: busy, iceServers: iceServers)), to: client)

        case .offer(let sid, let sdp, let restart):
            if let s = session, s.sid == sid {
                guard sessionInfo?.client.id == client.id else { return } // someone else's session
                ReachLog.info("host", "renegotiation (restart=\(restart)) for \(sid.prefix(6))")
                s.acceptOffer(sdp, track: nil) { [weak self] result in
                    guard let self, self.session === s else { return }
                    switch result {
                    case .success(let answer): self.sendSignal(.answer(sid: sid, sdp: answer), to: client)
                    case .failure(let e): ReachLog.error("host", "renegotiation failed: \(e)")
                    }
                }
            } else {
                startSession(sid: sid, offer: sdp, client: client)
            }

        case .candidates(let sid, let list):
            guard let s = session, s.sid == sid, sessionInfo?.client.id == client.id else { return }
            s.addRemoteCandidates(list)

        case .bye(let sid, let reason):
            guard session?.sid == sid, sessionInfo?.client.id == client.id else { return }
            endSession(reason: reason.isEmpty ? "iPhone disconnected" : reason, notifyClient: false)

        case .pairRequest, .pairResult, .probeAck, .answer:
            break
        }
    }

    private func startSession(sid: String, offer: String, client: TrustedClient) {
        guard let updated = trustStore.recordConnection(id: client.id, at: Date()) else {
            ReachLog.info("host", "offer from a device that is no longer trusted")
            return
        }
        if sessionInfo != nil { endSession(reason: "Another session started", notifyClient: true) }
        let policy: RTCIceTransportPolicy = iceTransportPolicyOverride == "relay" ? .relay : (iceTransportPolicyOverride == "nohost" ? .noHost : .all)
        let s: PeerSession
        do {
            s = try PeerSession(role: .host, sid: sid, iceServers: iceServers, policy: policy, queue: queue)
        } catch {
            ReachLog.error("host", "could not create session: \(error)")
            return
        }
        ReachLog.info("host", "offer received; session \(sid.prefix(6)) from \(client.name)")
        session = s
        sessionInfo = HostSessionInfo(sid: sid, client: updated, startedAt: Date(), isConnected: false)
        sessionCandidatesReady = false
        pendingLocalCandidates = []
        inputQueue.async { self.hasInputSeq = false }
        let inputGeneration = bumpInputGeneration()

        let track = RTCEnvironment.shared.factory.videoTrack(with: videoSource, trackId: "screen-\(sid.prefix(6))")
        videoTrack = track

        s.onLocalCandidate = { [weak self, weak s] cand in
            guard let self, let s, self.session === s, self.sessionCandidatesReady else { return }
            self.pendingLocalCandidates.append(cand)
            self.scheduleCandidateFlush(client: client, sid: sid)
        }
        s.onIceState = { [weak self, weak s] state in
            guard let self, let s, self.session === s else { return }
            self.iceStateChanged(state)
        }
        s.onChannelsOpen = { [weak self, weak s] in
            guard let self, let s, self.session === s, var info = self.sessionInfo else { return }
            info.isConnected = true
            self.sessionInfo = info
            self.videoLock.withLock { self._sessionActive = true }
            _ = s.pc.setBweMinBitrateBps(300_000, currentBitrateBps: 4_000_000, maxBitrateBps: 50_000_000)
            self.applyEncoderParameters()
            ReachLog.info("host", "session \(sid.prefix(6)) connected")
            self.perf?.stop()
            self.perf = PerfSampler(role: .host, pc: s.pc, label: "host")
            self.perf?.onSample = { [weak self] stats in
                guard let self else { return }
                DispatchQueue.main.async { self.delegate?.hostEngine(self, didMeasure: stats) }
            }
            self.perf?.start(on: self.queue)
            DispatchQueue.main.async { self.delegate?.hostEngine(self, sessionDidStart: info) }
            self.resendLastFrame()
        }
        s.onControlData = { [weak self] data in
            guard let self else { return }
            guard let msg = try? WireCodec.decode(ClientMessage.self, from: data) else {
                ReachLog.error("host", "undecodable control message (\(data.count) bytes)")
                return
            }
            // Answer pings here, not behind queued input (e.g. a long paste being typed), so the
            // iPhone's liveness check never mistakes a busy Mac for a dead one.
            if case .ping(let id, let sentAt) = msg { self.send(.pong(id: id, sentAt: sentAt)); return }
            self.inputQueue.async { self.withCurrentInput(inputGeneration) { self.dispatch(msg) } }
        }
        s.onFastData = { [weak self] data in
            guard let self, let p = PointerPacket(data) else { return }
            self.inputQueue.async { self.withCurrentInput(inputGeneration) {
                if self.hasInputSeq && !seqIsNewer(p.seq, than: self.inputSeq) { return } // stale, superseded
                self.inputSeq = p.seq
                self.hasInputSeq = true
                self.delegate?.hostEngine(self, didReceivePointer: p)
            } }
        }

        s.acceptOffer(offer, track: track) { [weak self] result in
            guard let self, self.session === s else { return }
            switch result {
            case .success(let answer):
                ReachLog.info("host", "answer ready (\(answer.count) bytes)")
                self.sendSignal(.answer(sid: sid, sdp: answer), to: client)
                self.sessionCandidatesReady = true
            case .failure(let e):
                ReachLog.error("host", "answer failed: \(e)")
                self.endSession(reason: "Negotiation failed", notifyClient: true)
            }
        }
    }

    @discardableResult
    private func bumpInputGeneration() -> Int {
        inputGenerationLock.withLock { _inputGeneration += 1; return _inputGeneration }
    }

    /// Runs `body` only if the session that sent the input is still current, holding the gate so the
    /// session can't end midway: input either reaches the Mac before the session's cleanup, or not at
    /// all. (Nothing reached from here waits on the engine queue, which bumps the generation.)
    private func withCurrentInput(_ generation: Int, _ body: () -> Void) {
        inputGenerationLock.withLock { if _inputGeneration == generation { body() } }
    }

    /// Runs on the input queue.
    private func dispatch(_ msg: ClientMessage) {
        switch msg {
        case .mouseButton(let e):
            if !hasInputSeq || seqIsNewer(e.seq, than: inputSeq) { inputSeq = e.seq; hasInputSeq = true }
        case .setQuality(let q):
            applyQuality(q)
        case .hello(let h):
            applyQuality(h.quality)
        case .ping:
            return
        default:
            break
        }
        delegate?.hostEngine(self, didReceive: msg)
    }

    private func scheduleCandidateFlush(client: TrustedClient, sid: String) {
        guard !candidateFlushScheduled else { return }
        candidateFlushScheduled = true
        queue.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            guard let self else { return }
            self.candidateFlushScheduled = false
            guard self.session?.sid == sid, !self.pendingLocalCandidates.isEmpty else { return }
            let list = self.pendingLocalCandidates
            self.pendingLocalCandidates = []
            self.sendSignal(.candidates(sid: sid, list: list), to: client)
        }
    }

    private func iceStateChanged(_ state: RTCIceConnectionState) {
        ReachLog.info("host", "ICE \(state.label)")
        switch state {
        case .connected, .completed:
            disconnectTimer?.cancel(); disconnectTimer = nil
        case .disconnected, .failed:
            // The iPhone drives recovery (ICE restart). Give it time — e.g. a Wi-Fi → cellular
            // handover — before tearing the session down.
            guard disconnectTimer == nil else { return }
            let sid = session?.sid
            let work = DispatchWorkItem { [weak self] in
                guard let self, self.session?.sid == sid else { return }
                let st = self.session?.pc.iceConnectionState
                if st != .connected && st != .completed { self.endSession(reason: "Connection lost", notifyClient: false) }
            }
            disconnectTimer = work
            queue.asyncAfter(deadline: .now() + 45, execute: work)
        case .closed:
            endSession(reason: "Connection closed", notifyClient: false)
        default:
            break
        }
    }

    private func endSession(reason: String, notifyClient: Bool) {
        guard let s = session, let info = sessionInfo else { return }
        ReachLog.info("host", "session \(s.sid.prefix(6)) ended: \(reason)")
        if notifyClient { sendSignal(.bye(sid: s.sid, reason: reason), to: info.client) }
        session = nil
        sessionInfo = nil
        bumpInputGeneration() // waits for any input being delivered right now
        delegate?.hostEngine(self, inputDidStopFor: info)
        disconnectTimer?.cancel(); disconnectTimer = nil
        videoLock.withLock { _sessionActive = false }
        perf?.stop()
        perf = nil
        s.close()
        videoTrack = nil
        DispatchQueue.main.async { self.delegate?.hostEngine(self, sessionDidEnd: info, reason: reason) }
    }
}

extension RTCIceConnectionState {
    var label: String {
        switch self {
        case .new: return "new"
        case .checking: return "checking"
        case .connected: return "connected"
        case .completed: return "completed"
        case .failed: return "failed"
        case .disconnected: return "disconnected"
        case .closed: return "closed"
        case .count: return "count"
        @unknown default: return "unknown"
        }
    }
}
