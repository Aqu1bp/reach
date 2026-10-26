import Foundation
import WebRTC

/// One WebRTC peer connection between the iPhone (offerer, receives video) and the Mac (answerer,
/// sends video). Owns three pre-negotiated data channels:
///
/// * `control` — reliable + ordered: clicks, keys, text, scroll, metadata.
/// * `fast`    — unreliable + unordered: pointer and cursor positions, where only the newest value
///               matters and a retransmitted stale position would only add lag.
/// * `bulk`    — reliable + ordered: large control messages (clipboard, app icons), fragmented, so a
///               big transfer never queues up in front of a click or keystroke.
///
/// Negotiated channels (fixed ids on both sides) are usable as soon as DTLS completes, saving the
/// in-band open handshake round trip.
final class PeerSession: NSObject, RTCPeerConnectionDelegate, RTCDataChannelDelegate, @unchecked Sendable {
    enum Role { case host, client }

    let role: Role
    let sid: String
    let pc: RTCPeerConnection
    let control: RTCDataChannel
    let fast: RTCDataChannel
    let bulk: RTCDataChannel

    /// Messages above this size go over `bulk` in fragments.
    static let inlineLimit = 16 * 1024
    /// Largest message we'll send or reassemble.
    static let maxMessageSize = 8 * 1024 * 1024
    private var nextBulkID: UInt32 = 0
    private let reassembler = Reassembler()

    /// Engine queue: every callback except the data-plane ones is delivered here.
    private let queue: DispatchQueue

    var onLocalCandidate: ((IceCandidateInfo) -> Void)?
    var onIceState: ((RTCIceConnectionState) -> Void)?
    var onPeerState: ((RTCPeerConnectionState) -> Void)?
    var onChannelsOpen: (() -> Void)?
    /// Data-plane callbacks run directly on WebRTC's network thread for minimum latency.
    var onControlData: ((Data) -> Void)?
    var onFastData: ((Data) -> Void)?

    private(set) var videoTransceiver: RTCRtpTransceiver?
    private var pendingRemoteCandidates: [IceCandidateInfo] = []
    private var hasRemoteDescription = false
    private var closed = false
    private var openChannels = 0

    init(role: Role, sid: String, iceServers: [IceServerConfig], policy: RTCIceTransportPolicy = .all, queue: DispatchQueue) throws {
        self.role = role
        self.sid = sid
        self.queue = queue
        let env = RTCEnvironment.shared
        guard let pc = env.factory.peerConnection(with: env.configuration(iceServers: iceServers, policy: policy),
                                                  constraints: RTCEnvironment.emptyConstraints, delegate: nil) else {
            throw ReachError.webrtc("could not create peer connection")
        }
        self.pc = pc

        let controlConfig = RTCDataChannelConfiguration()
        controlConfig.isNegotiated = true
        controlConfig.channelId = 1
        controlConfig.isOrdered = true
        let fastConfig = RTCDataChannelConfiguration()
        fastConfig.isNegotiated = true
        fastConfig.channelId = 2
        fastConfig.isOrdered = false
        fastConfig.maxRetransmits = 0
        let bulkConfig = RTCDataChannelConfiguration()
        bulkConfig.isNegotiated = true
        bulkConfig.channelId = 3
        bulkConfig.isOrdered = true
        guard let control = pc.dataChannel(forLabel: "control", configuration: controlConfig),
              let fast = pc.dataChannel(forLabel: "fast", configuration: fastConfig),
              let bulk = pc.dataChannel(forLabel: "bulk", configuration: bulkConfig) else {
            pc.close()
            throw ReachError.webrtc("could not create data channels")
        }
        self.control = control
        self.fast = fast
        self.bulk = bulk
        super.init()
        pc.delegate = self
        control.delegate = self
        fast.delegate = self
        bulk.delegate = self

        if role == .client {
            let initp = RTCRtpTransceiverInit()
            initp.direction = .recvOnly
            videoTransceiver = pc.addTransceiver(of: .video, init: initp)
            preferScreenCodecs(on: videoTransceiver, kind: "video", receiving: true)
        }
    }

    // MARK: Negotiation

    /// Client: create an offer. Waits briefly for candidate gathering so the first message already
    /// carries host and server-reflexive candidates (fewer relay round trips).
    func makeOffer(iceRestart: Bool, completion: @escaping (Result<String, Error>) -> Void) {
        let constraints = RTCMediaConstraints(mandatoryConstraints: iceRestart ? ["IceRestart": "true"] : nil,
                                              optionalConstraints: nil)
        pc.offer(for: constraints) { [weak self] sdp, err in
            guard let self else { return }
            guard let sdp else { self.queue.async { completion(.failure(ReachError.webrtc(err?.localizedDescription ?? "offer failed"))) }; return }
            self.pc.setLocalDescription(sdp) { err in
                if let err { self.queue.async { completion(.failure(ReachError.webrtc(err.localizedDescription))) }; return }
                self.afterGathering(maxWait: 0.2) { completion(.success(self.pc.localDescription?.sdp ?? sdp.sdp)) }
            }
        }
    }

    func applyAnswer(_ sdp: String, completion: @escaping (Error?) -> Void) {
        pc.setRemoteDescription(RTCSessionDescription(type: .answer, sdp: sdp)) { [weak self] err in
            guard let self else { return }
            self.queue.async {
                if err == nil { self.remoteDescriptionApplied() }
                completion(err.map { ReachError.webrtc($0.localizedDescription) })
            }
        }
    }

    /// Host: accept an offer, attaching `track` to the client's video transceiver.
    func acceptOffer(_ sdp: String, track: RTCVideoTrack?, completion: @escaping (Result<String, Error>) -> Void) {
        pc.setRemoteDescription(RTCSessionDescription(type: .offer, sdp: sdp)) { [weak self] err in
            guard let self else { return }
            if let err { self.queue.async { completion(.failure(ReachError.webrtc(err.localizedDescription))) }; return }
            self.queue.async {
                self.remoteDescriptionApplied()
                if let track, self.videoTransceiver == nil,
                   let tx = self.pc.transceivers.first(where: { $0.mediaType == .video }) {
                    var error: NSError?
                    tx.setDirection(.sendOnly, error: &error)
                    tx.sender.track = track
                    tx.sender.streamIds = ["screen"]
                    self.preferScreenCodecs(on: tx, kind: "video", receiving: false)
                    self.videoTransceiver = tx
                }
                self.pc.answer(for: RTCEnvironment.emptyConstraints) { answer, err in
                    guard let answer else { self.queue.async { completion(.failure(ReachError.webrtc(err?.localizedDescription ?? "answer failed"))) }; return }
                    self.pc.setLocalDescription(answer) { err in
                        if let err { self.queue.async { completion(.failure(ReachError.webrtc(err.localizedDescription))) }; return }
                        self.afterGathering(maxWait: 0.2) { completion(.success(self.pc.localDescription?.sdp ?? answer.sdp)) }
                    }
                }
            }
        }
    }

    func addRemoteCandidates(_ list: [IceCandidateInfo]) {
        guard hasRemoteDescription else { pendingRemoteCandidates.append(contentsOf: list); return }
        for c in list {
            pc.add(RTCIceCandidate(sdp: c.sdp, sdpMLineIndex: c.index, sdpMid: c.mid)) { err in
                if let err { ReachLog.debug("rtc", "add candidate failed: \(err.localizedDescription)") }
            }
        }
    }

    private func remoteDescriptionApplied() {
        hasRemoteDescription = true
        let pending = pendingRemoteCandidates
        pendingRemoteCandidates.removeAll()
        if !pending.isEmpty { addRemoteCandidates(pending) }
    }

    private func afterGathering(maxWait: TimeInterval, _ done: @escaping () -> Void) {
        let deadline = Date().addingTimeInterval(maxWait)
        func check() {
            if pc.iceGatheringState == .complete || Date() >= deadline { done(); return }
            queue.asyncAfter(deadline: .now() + 0.05, execute: check)
        }
        queue.async(execute: check)
    }

    /// Offer only hardware codecs, HEVC first (see `ScreenCodecs`), then H.264 High, then Baseline.
    private func preferScreenCodecs(on tx: RTCRtpTransceiver?, kind: String, receiving: Bool) {
        guard let tx else { return }
        let f = RTCEnvironment.shared.factory
        let caps = receiving ? f.rtpReceiverCapabilities(forKind: kind) : f.rtpSenderCapabilities(forKind: kind)
        let hevc = caps.codecs.filter { $0.name == ScreenCodecs.h265Name }
        let h264 = caps.codecs.filter { $0.name == kRTCVideoCodecH264Name }
        let high = h264.filter { ($0.parameters["profile-level-id"] ?? "").hasPrefix("640c") }
        let others = caps.codecs.filter { ["rtx", "red", "ulpfec", "flexfec-03"].contains($0.name) }
        do {
            try tx.setCodecPreferences(hevc + high + h264.filter { !high.contains($0) } + others, error: ())
        } catch {
            ReachLog.error("rtc", "setCodecPreferences failed: \(error)")
        }
    }

    // MARK: Data

    /// Reliable, ordered delivery. Large messages are transparently fragmented over the bulk channel.
    /// Called from the engine queue only.
    @discardableResult
    func sendControl(_ data: Data) -> Bool {
        if data.count <= Self.inlineLimit {
            guard control.readyState == .open else { return false }
            return control.sendData(RTCDataBuffer(data: data, isBinary: true))
        }
        guard bulk.readyState == .open, data.count <= Self.maxMessageSize else { return false }
        // WebRTC closes a channel whose send buffer exceeds 16 MB; stay well clear of that.
        if bulk.bufferedAmount + UInt64(data.count) > UInt64(Self.maxMessageSize * 2) {
            ReachLog.error("rtc", "bulk channel congested; dropping \(data.count)-byte message")
            return false
        }
        nextBulkID &+= 1
        let chunk = Self.inlineLimit
        let count = (data.count + chunk - 1) / chunk
        for i in 0..<count {
            let slice = data[(data.startIndex + i * chunk)..<min(data.endIndex, data.startIndex + (i + 1) * chunk)]
            var frame = Data(capacity: slice.count + Reassembler.headerSize)
            frame.append(Reassembler.tag)
            for v in [nextBulkID, UInt32(i), UInt32(count)] { withUnsafeBytes(of: v.littleEndian) { frame.append(contentsOf: $0) } }
            frame.append(slice)
            guard bulk.sendData(RTCDataBuffer(data: frame, isBinary: true)) else { return false }
        }
        return true
    }

    @discardableResult
    func sendFast(_ data: Data) -> Bool {
        guard fast.readyState == .open else { return false }
        // Under congestion, drop rather than queue stale positions.
        if fast.bufferedAmount > 16 * 1024 { return false }
        return fast.sendData(RTCDataBuffer(data: data, isBinary: true))
    }

    var channelsOpen: Bool { control.readyState == .open && fast.readyState == .open && bulk.readyState == .open }

    func close() {
        guard !closed else { return }
        closed = true
        onLocalCandidate = nil; onIceState = nil; onPeerState = nil
        onControlData = nil; onFastData = nil; onChannelsOpen = nil
        control.close(); fast.close(); bulk.close()
        pc.close()
    }

    // MARK: RTCPeerConnectionDelegate

    func peerConnection(_ peerConnection: RTCPeerConnection, didChange stateChanged: RTCSignalingState) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didAdd stream: RTCMediaStream) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove stream: RTCMediaStream) {}
    func peerConnectionShouldNegotiate(_ peerConnection: RTCPeerConnection) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceGatheringState) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove candidates: [RTCIceCandidate]) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didOpen dataChannel: RTCDataChannel) {}

    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceConnectionState) {
        queue.async { self.onIceState?(newState) }
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCPeerConnectionState) {
        queue.async { self.onPeerState?(newState) }
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didGenerate candidate: RTCIceCandidate) {
        let info = IceCandidateInfo(sdp: candidate.sdp, mid: candidate.sdpMid, index: candidate.sdpMLineIndex)
        queue.async { self.onLocalCandidate?(info) }
    }

    // MARK: RTCDataChannelDelegate

    func dataChannelDidChangeState(_ dataChannel: RTCDataChannel) {
        queue.async {
            if self.channelsOpen, self.openChannels == 0 {
                self.openChannels = 3
                self.onChannelsOpen?()
            }
        }
    }

    func dataChannel(_ dataChannel: RTCDataChannel, didReceiveMessageWith buffer: RTCDataBuffer) {
        if dataChannel === fast {
            onFastData?(buffer.data)
        } else if dataChannel === bulk {
            if let whole = reassembler.add(buffer.data) { onControlData?(whole) }
        } else {
            onControlData?(buffer.data)
        }
    }
}

/// Reassembles fragmented bulk messages. Frame: tag(1) | id(4) | index(4) | count(4) | payload, all
/// little-endian. The bulk channel is ordered, so fragments of one message arrive contiguously.
final class Reassembler: @unchecked Sendable {
    static let tag: UInt8 = 0x46 // "F"
    static let headerSize = 13

    private let lock = NSLock()
    private var currentID: UInt32?
    private var expected = 0
    private var nextIndex = 0
    private var buffer = Data()

    func add(_ frame: Data) -> Data? {
        let b = [UInt8](frame.prefix(Self.headerSize))
        guard b.count == Self.headerSize, b[0] == Self.tag else { return nil }
        func u32(_ o: Int) -> UInt32 { UInt32(b[o]) | UInt32(b[o + 1]) << 8 | UInt32(b[o + 2]) << 16 | UInt32(b[o + 3]) << 24 }
        let id = u32(1), index = Int(u32(5)), count = Int(u32(9))
        let payload = frame.dropFirst(Self.headerSize)
        return lock.withLock {
            if index == 0 {
                currentID = id; expected = count; nextIndex = 0; buffer = Data()
            }
            guard currentID == id, index == nextIndex, count == expected,
                  buffer.count + payload.count <= PeerSession.maxMessageSize else {
                currentID = nil; buffer = Data()
                return nil
            }
            buffer.append(payload)
            nextIndex += 1
            guard nextIndex == expected else { return nil }
            defer { currentID = nil; buffer = Data() }
            return buffer
        }
    }
}
