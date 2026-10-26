import Foundation
import CoreVideo
import Network
import WebRTC
import ReachProtocol

/// A live connection from the iPhone to one Mac. Recovers on its own from network changes and
/// short outages (ICE restart), falling back to a full reconnect if that fails.
public final class ClientSession: @unchecked Sendable {
    public enum State: Equatable, Sendable {
        /// Exchanging offer/answer through the relays.
        case signaling
        /// Answer received; establishing the peer-to-peer path.
        case connecting
        case connected
        /// Was connected; recovering (network change, brief outage).
        case reconnecting
        case failed(String)
        case closed(String)

        public var isTerminal: Bool {
            switch self { case .failed, .closed: return true; default: return false }
        }
    }

    public let host: PairedHost

    /// Main queue.
    public var onState: ((State) -> Void)?
    /// Main queue, in order.
    public var onMessage: ((HostMessage) -> Void)?
    /// Called on a WebRTC network thread for minimum latency — hop to your render thread yourself.
    public var onCursor: ((CursorPacket) -> Void)?
    /// Called on WebRTC's decode thread with each decoded frame (NV12, IOSurface-backed).
    public var onVideoFrame: ((CVPixelBuffer, Int64) -> Void)? {
        get { forwarder.onFrame }
        set { forwarder.onFrame = newValue }
    }

    /// Current state (main-thread reads are always consistent with the last `onState` callback).
    public private(set) var state: State = .signaling

    private weak var engine: ClientEngine?
    private let queue: DispatchQueue
    private var hello: ClientHello
    private let policyOverride: String?
    private var peer: PeerSession?
    private var sid = ""
    private var offerData: Data?
    private var awaitingAnswer = false
    private var everConnected = false
    private var pendingLocalCandidates: [IceCandidateInfo] = []
    private var candidatesReady = false
    private var flushScheduled = false
    private var restartAttempts = 0
    private var recoveryDeadline: DispatchWorkItem?
    private var disconnectGrace: DispatchWorkItem?
    private var pathMonitor: NWPathMonitor?
    private var lastPathSignature: String?
    private var isClosed = false
    private var pingTimer: DispatchSourceTimer?
    private var pingID: UInt32 = 0
    /// Uptime (ns) of the last pong — the liveness signal for the Mac. Guarded by `seqLock`.
    private var lastPongAt: UInt64 = 0
    private let forwarder = FrameForwarder()
    /// Must be retained: WebRTC's `RTCVideoTrack` wrapper detaches its renderers when deallocated.
    private var remoteTrack: RTCVideoTrack?
    private var lastStats: ConnectionStats?
    private var perf: PerfSampler?

    private let seqLock = NSLock()
    private var seq: UInt32 = 0

    /// Latest application-level round trip (control-channel ping), milliseconds.
    public private(set) var controlRoundTripMs: Double?

    init(engine: ClientEngine, host: PairedHost, hello: ClientHello, policyOverride: String?) {
        self.engine = engine
        self.queue = engine.queue
        self.host = host
        self.hello = hello
        self.policyOverride = policyOverride
    }

    deinit {
        pathMonitor?.cancel()
        pingTimer?.cancel()
        peer?.close()
    }

    // MARK: Public API (any thread)

    public func send(_ message: ClientMessage) {
        guard let data = try? WireCodec.encode(message) else { return }
        queue.async { self.peer?.sendControl(data) }
    }

    /// Send the pointer position (normalized within the active display) on the unreliable channel.
    /// Returns the sequence number used.
    @discardableResult
    public func sendPointer(x: Float, y: Float) -> UInt32 {
        let s = nextSequence()
        let data = PointerPacket(seq: s, x: x, y: y).encoded()
        queue.async { self.peer?.sendFast(data) }
        return s
    }

    /// Sequence number for `MouseButtonEvent`s, shared with pointer packets so the Mac can discard
    /// pointer moves that arrive after a later button event.
    public func nextSequence() -> UInt32 {
        seqLock.withLock { seq &+= 1; return seq }
    }

    /// Tell the Mac how much of the phone its display covers; also included in the hello of every
    /// later (re)connect so the first frames already come at the right size.
    public func setViewport(_ v: ViewportHint) {
        queue.async { self.hello.viewport = v }
        send(.viewport(v))
    }

    /// Update preferences sent on (re)connect, and apply them now.
    public func setQuality(_ q: QualityPreference) {
        queue.async { self.hello.quality = q }
        send(.setQuality(q))
    }

    /// Stats sample with bitrate computed against the previous sample. Completion on main.
    public func stats(completion: @escaping (ConnectionStats?) -> Void) {
        queue.async {
            guard let p = self.peer else { DispatchQueue.main.async { completion(nil) }; return }
            p.pc.statistics { report in
                self.queue.async {
                    var s = ConnectionStats(report: report, role: .client)
                    s.computeRates(since: self.lastStats)
                    self.lastStats = s
                    DispatchQueue.main.async { completion(s) }
                }
            }
        }
    }

    /// Force an ICE restart (e.g. the app returned to the foreground on a different network).
    public func restartConnection() {
        queue.async { self.iceRestart(reason: "requested") }
    }

    public func close() {
        queue.async { self.shutdown(.closed("Disconnected"), sendBye: true) }
    }

    // MARK: Lifecycle (engine queue)

    func begin() {
        startPathMonitor()
        // Refresh what's stored about the Mac (name, TURN server) alongside the first offer. This
        // attempt doesn't wait for it; a retry uses the answer.
        engine?.send(.probe, to: host)
        startPeer()
    }

    private func startPeer() {
        guard !isClosed, let engine else { return }
        if !sid.isEmpty {
            engine.send(.bye(sid: sid, reason: "reconnecting"), to: host)
            engine.unregister(sid: sid)
        }
        perf?.stop(); perf = nil
        peer?.close()
        sid = randomHex(bytes: 8)
        candidatesReady = false
        pendingLocalCandidates = []
        restartAttempts = 0
        engine.register(self, sid: sid)
        setState(everConnected ? .reconnecting : .signaling)

        var servers = IceServerConfig.defaultSTUN
        for s in host.iceServers where !servers.contains(s) { servers.append(s) }
        let policy: RTCIceTransportPolicy = policyOverride == "relay" ? .relay : (policyOverride == "nohost" ? .noHost : .all)
        let p: PeerSession
        do {
            p = try PeerSession(role: .client, sid: sid, iceServers: servers, policy: policy, queue: queue)
        } catch {
            shutdown(.failed(error.localizedDescription), sendBye: false)
            return
        }
        peer = p
        remoteTrack?.remove(forwarder)
        remoteTrack = p.videoTransceiver?.receiver.track as? RTCVideoTrack
        remoteTrack?.add(forwarder)
        let sid = self.sid
        p.onLocalCandidate = { [weak self, weak p] c in
            guard let self, let p, self.peer === p, self.candidatesReady else { return }
            self.pendingLocalCandidates.append(c)
            self.scheduleCandidateFlush(sid: sid)
        }
        p.onIceState = { [weak self, weak p] st in
            guard let self, let p, self.peer === p else { return }
            self.iceStateChanged(st)
        }
        p.onChannelsOpen = { [weak self, weak p] in
            guard let self, let p, self.peer === p else { return }
            self.channelsOpened()
        }
        p.onControlData = { [weak self] data in
            guard let self, let msg = try? WireCodec.decode(HostMessage.self, from: data) else { return }
            if case .pong(_, let sentAt) = msg {
                self.controlRoundTripMs = (Date().timeIntervalSince1970 - sentAt) * 1000
                self.seqLock.withLock { self.lastPongAt = DispatchTime.now().uptimeNanoseconds }
                self.queue.async { self.pongArrived() }
                return
            }
            DispatchQueue.main.async { self.onMessage?(msg) }
        }
        p.onFastData = { [weak self] data in
            guard let self, let c = CursorPacket(data) else { return }
            self.onCursor?(c)
        }
        sendOffer(restart: false)
        armRecoveryDeadline(seconds: 20)
    }

    private func sendOffer(restart: Bool) {
        guard let p = peer, let engine else { return }
        let sid = self.sid
        awaitingAnswer = true
        p.makeOffer(iceRestart: restart) { [weak self, weak p] result in
            guard let self, let p, self.peer === p else { return }
            switch result {
            case .success(let sdp):
                ReachLog.info("client", "offer ready (\(sdp.count) bytes, restart=\(restart))")
                guard let data = engine.send(.offer(sid: sid, sdp: sdp, restart: restart), to: self.host, completion: { ok in
                    ReachLog.info("client", "offer published (ok=\(ok))")
                }) else { return }
                self.offerData = data
                self.candidatesReady = true
                // Re-publish the same offer if the answer is slow (relay hiccup).
                engine.queue.asyncAfter(deadline: .now() + 4) { [weak self] in
                    guard let self, self.sid == sid, self.awaitingAnswer, let d = self.offerData else { return }
                    ReachLog.info("client", "no answer yet; re-sending offer")
                    engine.republish(d, to: self.host.id)
                }
            case .failure(let e):
                self.shutdown(.failed(e.localizedDescription), sendBye: false)
            }
        }
    }

    func handleAnswer(_ sdp: String) {
        guard let p = peer, awaitingAnswer else { return }
        ReachLog.info("client", "answer received")
        awaitingAnswer = false
        p.applyAnswer(sdp) { [weak self] err in
            guard let self else { return }
            if let err {
                ReachLog.error("client", "applyAnswer failed: \(err)")
                self.fullReconnect(reason: "negotiation failed")
                return
            }
            if self.state == .signaling { self.setState(.connecting) }
        }
    }

    func handleCandidates(_ list: [IceCandidateInfo]) {
        peer?.addRemoteCandidates(list)
    }

    func handleBye(_ reason: String) {
        shutdown(.closed(reason), sendBye: false)
    }

    private func channelsOpened() {
        everConnected = true
        restartAttempts = 0
        recoveryDeadline?.cancel(); recoveryDeadline = nil
        setState(.connected)
        if let data = try? WireCodec.encode(ClientMessage.hello(hello)) { peer?.sendControl(data) }
        startPinger()
        if let p = peer {
            perf?.stop()
            perf = PerfSampler(role: .client, pc: p.pc, label: "client")
            perf?.start(on: queue)
        }
        // From the store, not `host`: a probe answer may have updated it since this session began.
        engine?.store.update(id: host.id) { $0.lastConnectedAt = Date() }
    }

    private func iceStateChanged(_ st: RTCIceConnectionState) {
        ReachLog.info("client", "ICE \(st.label)")
        switch st {
        case .connected, .completed:
            disconnectGrace?.cancel(); disconnectGrace = nil
            recoveryDeadline?.cancel(); recoveryDeadline = nil
            restartAttempts = 0
            if everConnected, peer?.channelsOpen == true { setState(.connected) }
        case .disconnected:
            guard everConnected else { return }
            setState(.reconnecting)
            // Often recovers by itself within a second (e.g. brief Wi-Fi blip); restart if not.
            let work = DispatchWorkItem { [weak self] in self?.iceRestart(reason: "disconnected") }
            disconnectGrace = work
            queue.asyncAfter(deadline: .now() + 1.5, execute: work)
        case .failed:
            if everConnected { iceRestart(reason: "failed") }
        default:
            break
        }
    }

    private func iceRestart(reason: String) {
        guard !isClosed, peer != nil else { return }
        disconnectGrace?.cancel(); disconnectGrace = nil
        guard everConnected else { return }
        restartAttempts += 1
        if restartAttempts > 3 { fullReconnect(reason: "ICE restart exhausted"); return }
        ReachLog.info("client", "ICE restart #\(restartAttempts) (\(reason))")
        setState(.reconnecting)
        candidatesReady = false
        sendOffer(restart: true)
        armRecoveryDeadline(seconds: 10)
    }

    private func fullReconnect(reason: String) {
        guard !isClosed else { return }
        ReachLog.info("client", "full reconnect (\(reason))")
        startPeer()
    }

    /// If we aren't connected by the deadline: before ever connecting, fail; afterwards, keep trying.
    private func armRecoveryDeadline(seconds: TimeInterval) {
        recoveryDeadline?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.isClosed else { return }
            let st = self.peer?.pc.iceConnectionState
            if st == .connected || st == .completed, self.peer?.channelsOpen == true, self.macRecentlyAnswered {
                // Recovered without ICE reporting a fresh "connected" (see `pongArrived`).
                if self.everConnected { self.markRecovered() }
                return
            }
            if self.everConnected {
                self.restartAttempts >= 3 ? self.fullReconnect(reason: "recovery timeout") : self.iceRestart(reason: "timeout")
            } else {
                self.shutdown(.failed(self.firstConnectionFailure(iceState: st)), sendBye: true)
            }
        }
        recoveryDeadline = work
        queue.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    /// Why the first attempt didn't connect, in words for the user.
    private func firstConnectionFailure(iceState: RTCIceConnectionState?) -> String {
        let iceConnected = iceState == .connected || iceState == .completed
        // No answer means the Mac never got the offer; an ICE connection means a path did exist.
        if awaitingAnswer || iceConnected { return "Couldn't reach your Mac. It may be asleep or offline." }
        // The Mac answered but no path between the two worked: typically strict NATs or firewalls on
        // both networks, which only a TURN relay gets through.
        ReachLog.info("client", "ICE never connected (\(iceState?.label ?? "no peer"))")
        if host.iceServers.contains(where: \.isRelay) {
            return "The connection didn't get through, even with the relay server. Check its details in Reach Host's settings."
        }
        if engine?.store.host(id: host.id)?.iceServers.contains(where: \.isRelay) == true {
            // Added on the Mac since this attempt started (the probe sent with it brought it in).
            return "The networks may be blocking a direct connection to your Mac. Try again to use its new relay server."
        }
        return "The networks may be blocking a direct connection to your Mac. Adding a relay server in Reach Host's settings can help."
    }

    private func scheduleCandidateFlush(sid: String) {
        guard !flushScheduled else { return }
        flushScheduled = true
        queue.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            guard let self else { return }
            self.flushScheduled = false
            guard self.sid == sid, !self.pendingLocalCandidates.isEmpty else { return }
            let list = self.pendingLocalCandidates
            self.pendingLocalCandidates = []
            self.engine?.send(.candidates(sid: sid, list: list), to: self.host)
        }
    }

    /// Pings every second. A still screen sends no video, so pongs are the only proof the Mac is
    /// alive: if they stop for 3.5 s while we think we're connected, start recovering right away
    /// instead of waiting for ICE consent checks to time out.
    private func startPinger() {
        pingTimer?.cancel()
        seqLock.withLock { lastPongAt = DispatchTime.now().uptimeNanoseconds }
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 0.25, repeating: 1)
        t.setEventHandler { [weak self] in
            guard let self, let p = self.peer else { return }
            self.pingID &+= 1
            if let d = try? WireCodec.encode(ClientMessage.ping(id: self.pingID, sentAt: Date().timeIntervalSince1970)) {
                p.sendControl(d)
            }
            let silentFor = Double(DispatchTime.now().uptimeNanoseconds &- self.seqLock.withLock { self.lastPongAt }) / 1e9
            if silentFor > 3.5, self.stateIsConnectedPending {
                ReachLog.info("client", "no pong for \(String(format: "%.1f", silentFor))s — recovering")
                self.seqLock.withLock { self.lastPongAt = DispatchTime.now().uptimeNanoseconds }
                self.setState(.reconnecting)
                self.iceRestart(reason: "host silent")
            }
        }
        t.resume()
        pingTimer = t
    }

    /// `state` is published on main; track the engine-queue view of "connected" separately.
    private var stateIsConnectedPending = false

    private var macRecentlyAnswered: Bool {
        Double(DispatchTime.now().uptimeNanoseconds &- seqLock.withLock { lastPongAt }) / 1e9 < 2.5
    }

    /// Pongs prove the Mac is reachable. If we were recovering, we're back: ICE doesn't always say so
    /// itself (after a restart that lands on a path it already considered connected, there's no new
    /// "connected" event), which used to leave the session showing "Reconnecting" while it worked.
    private func pongArrived() {
        guard everConnected, !isClosed, !stateIsConnectedPending, !awaitingAnswer,
              let p = peer, p.channelsOpen else { return }
        let st = p.pc.iceConnectionState
        guard st == .connected || st == .completed else { return }
        markRecovered()
    }

    private func markRecovered() {
        guard !stateIsConnectedPending else { return }
        ReachLog.info("client", "Mac answering again — connected")
        restartAttempts = 0
        recoveryDeadline?.cancel(); recoveryDeadline = nil
        disconnectGrace?.cancel(); disconnectGrace = nil
        setState(.connected)
    }

    /// Restart ICE as soon as the phone's network changes (Wi-Fi ⇄ cellular) instead of waiting for
    /// the old path to time out.
    private func startPathMonitor() {
        let m = NWPathMonitor()
        m.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            let sig = path.availableInterfaces.map { "\($0.type)-\($0.name)" }.joined(separator: ",") + "|\(path.status)"
            self.queue.async {
                defer { self.lastPathSignature = sig }
                guard let last = self.lastPathSignature, last != sig, path.status == .satisfied,
                      self.everConnected, !self.isClosed else { return }
                ReachLog.info("client", "network changed: \(sig)")
                self.restartAttempts = 0
                self.iceRestart(reason: "network change")
            }
        }
        m.start(queue: DispatchQueue(label: "reach.client.path"))
        pathMonitor = m
    }

    private func shutdown(_ final: State, sendBye: Bool) {
        guard !isClosed else { return }
        isClosed = true
        if sendBye, !sid.isEmpty { engine?.send(.bye(sid: sid, reason: "iPhone disconnected"), to: host) }
        engine?.unregister(sid: sid)
        if everConnected {
            engine?.store.update(id: host.id) { $0.lastConnectedAt = Date() } // "last used" = when the session ended
        }
        recoveryDeadline?.cancel(); disconnectGrace?.cancel()
        pingTimer?.cancel(); pingTimer = nil
        perf?.stop(); perf = nil
        pathMonitor?.cancel(); pathMonitor = nil
        remoteTrack?.remove(forwarder)
        remoteTrack = nil
        peer?.close()
        peer = nil
        setState(final)
    }

    private func setState(_ s: State) {
        stateIsConnectedPending = s == .connected
        DispatchQueue.main.async {
            guard self.state != s, !self.state.isTerminal else { return }
            self.state = s
            self.onState?(s)
        }
    }
}

/// Bridges WebRTC's renderer protocol to a plain pixel-buffer callback.
final class FrameForwarder: NSObject, RTCVideoRenderer, @unchecked Sendable {
    private let lock = NSLock()
    private var _onFrame: ((CVPixelBuffer, Int64) -> Void)?
    var onFrame: ((CVPixelBuffer, Int64) -> Void)? {
        get { lock.withLock { _onFrame } }
        set { lock.withLock { _onFrame = newValue } }
    }

    func setSize(_ size: CGSize) {}

    func renderFrame(_ frame: RTCVideoFrame?) {
        guard let frame, let buffer = frame.buffer as? RTCCVPixelBuffer else { return }
        onFrame?(buffer.pixelBuffer, frame.timeStampNs)
    }
}
