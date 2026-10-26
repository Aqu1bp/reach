import Foundation
import WebRTC

/// How the two devices are actually connected.
public enum ConnectionRoute: String, Sendable, Codable {
    /// Both ends on the same local network.
    case local
    /// Peer-to-peer across the internet (NAT hole-punched or IPv6).
    case direct
    /// Through a TURN relay (only when no direct path exists).
    case relayed
    case unknown

    public var label: String {
        switch self {
        case .local: return "Local network"
        case .direct: return "Direct"
        case .relayed: return "Relayed"
        case .unknown: return "Connecting"
        }
    }
}

public struct ConnectionStats: Sendable {
    public enum Role: Sendable { case host, client }

    public var timestamp: Date = Date()
    public var route: ConnectionRoute = .unknown
    public var localCandidateType: String?
    public var remoteCandidateType: String?
    public var transportProtocol: String?
    /// "wifi", "cellular", "ethernet", "vpn" — the local interface in use.
    public var networkType: String?
    public var localAddress: String?
    public var remoteAddress: String?
    public var roundTripMs: Double?
    public var availableBitrateKbps: Double?

    // Video (inbound on the client, outbound on the host)
    public var framesPerSecond: Double?
    public var frameWidth: Int?
    public var frameHeight: Int?
    public var bytesTransferred: Int64 = 0
    public var framesTransferred: Int64 = 0
    public var framesDropped: Int64 = 0
    public var packetsLost: Int64 = 0
    public var jitterMs: Double?
    /// Average time a frame waited in the jitter buffer.
    public var jitterBufferMs: Double?
    public var averageDecodeMs: Double?
    public var averageEncodeMs: Double?
    public var codecImplementation: String?
    public var qualityLimitation: String?
    public var targetBitrateKbps: Double?
    public var freezeCount: Int?

    /// Codec of the video stream ("H264", "H265"), from the codec stats.
    public var codecName: String?

    // Raw cumulative WebRTC counters (times in seconds, as WebRTC reports them), so callers can take
    // deltas between two samples. Same key names as the stats report (see PerfSampler).
    // Host (outbound-rtp):
    public var framesEncoded: Int64 = 0
    public var framesSent: Int64 = 0
    public var totalEncodeTime: Double = 0
    public var packetsSent: Int64 = 0
    public var totalPacketSendDelay: Double = 0
    public var hugeFramesSent: Int64 = 0
    public var keyFramesEncoded: Int64 = 0
    public var retransmittedBytesSent: Int64 = 0
    /// Average time a packet waited in the pacer since the stream started (cumulative).
    public var pacerDelayMs: Double?
    // Client (inbound-rtp):
    public var framesReceived: Int64 = 0
    public var framesDecoded: Int64 = 0
    public var keyFramesDecoded: Int64 = 0
    public var totalDecodeTime: Double = 0
    public var totalProcessingDelay: Double = 0
    public var totalAssemblyTime: Double = 0
    public var framesAssembledFromMultiplePackets: Int64 = 0
    public var jitterBufferDelay: Double = 0
    public var jitterBufferEmittedCount: Int64 = 0
    public var totalFreezesDuration: Double = 0
    public var packetsReceived: Int64 = 0
    // Both (NACK/PLI sent by the receiver, received by the sender):
    public var nackCount: Int64 = 0
    public var pliCount: Int64 = 0

    /// Filled in by comparing with the previous sample.
    public var bitrateKbps: Double?

    public init() {}

    init(report: RTCStatisticsReport, role: Role) {
        let stats = report.statistics
        func num(_ v: NSObject?) -> Double? { (v as? NSNumber)?.doubleValue }
        func str(_ v: NSObject?) -> String? { v as? String }

        // Selected candidate pair
        var pair: RTCStatistics?
        if let transport = stats.values.first(where: { $0.type == "transport" }),
           let pid = str(transport.values["selectedCandidatePairId"]) {
            pair = stats[pid]
        }
        if pair == nil {
            pair = stats.values.first { $0.type == "candidate-pair" && str($0.values["state"]) == "succeeded" && (($0.values["nominated"] as? NSNumber)?.boolValue ?? false) }
        }
        if let pair {
            if let rtt = num(pair.values["currentRoundTripTime"]) { roundTripMs = rtt * 1000 }
            let avail = role == .host ? num(pair.values["availableOutgoingBitrate"]) : num(pair.values["availableIncomingBitrate"])
            availableBitrateKbps = avail.map { $0 / 1000 } ?? num(pair.values["availableOutgoingBitrate"]).map { $0 / 1000 }
            if let lid = str(pair.values["localCandidateId"]), let l = stats[lid] {
                localCandidateType = str(l.values["candidateType"])
                transportProtocol = str(l.values["protocol"])
                networkType = str(l.values["networkType"])
                localAddress = str(l.values["address"]) ?? str(l.values["ip"])
            }
            if let rid = str(pair.values["remoteCandidateId"]), let r = stats[rid] {
                remoteCandidateType = str(r.values["candidateType"])
                remoteAddress = str(r.values["address"]) ?? str(r.values["ip"])
            }
            if localCandidateType == "relay" || remoteCandidateType == "relay" {
                route = .relayed
            } else if localCandidateType == "host", remoteCandidateType == "host", networkType != "cellular",
                      Self.sameLocalNetwork(localAddress, remoteAddress) {
                route = .local
            } else if localCandidateType != nil {
                // Includes host↔host over public IPv6, which crosses the internet like any other path.
                route = .direct
            }
        }

        let rtpType = role == .host ? "outbound-rtp" : "inbound-rtp"
        if let v = stats.values.first(where: { $0.type == rtpType && str($0.values["kind"]) == "video" }) {
            let s = v.values
            func count(_ k: String) -> Int64 { Int64(num(s[k]) ?? 0) }
            func secs(_ k: String) -> Double { num(s[k]) ?? 0 }
            if let codecID = str(s["codecId"]), let mime = str(stats[codecID]?.values["mimeType"]) {
                codecName = mime.replacingOccurrences(of: "video/", with: "")
            }
            nackCount = count("nackCount")
            pliCount = count("pliCount")
            if role == .host {
                framesEncoded = count("framesEncoded")
                framesSent = count("framesSent")
                totalEncodeTime = secs("totalEncodeTime")
                packetsSent = count("packetsSent")
                totalPacketSendDelay = secs("totalPacketSendDelay")
                hugeFramesSent = count("hugeFramesSent")
                keyFramesEncoded = count("keyFramesEncoded")
                retransmittedBytesSent = count("retransmittedBytesSent")
                if packetsSent > 0 { pacerDelayMs = totalPacketSendDelay / Double(packetsSent) * 1000 }
            } else {
                framesReceived = count("framesReceived")
                framesDecoded = count("framesDecoded")
                keyFramesDecoded = count("keyFramesDecoded")
                totalDecodeTime = secs("totalDecodeTime")
                totalProcessingDelay = secs("totalProcessingDelay")
                totalAssemblyTime = secs("totalAssemblyTime")
                framesAssembledFromMultiplePackets = count("framesAssembledFromMultiplePackets")
                jitterBufferDelay = secs("jitterBufferDelay")
                jitterBufferEmittedCount = count("jitterBufferEmittedCount")
                totalFreezesDuration = secs("totalFreezesDuration")
                packetsReceived = count("packetsReceived")
            }
            framesPerSecond = num(s["framesPerSecond"])
            frameWidth = num(s["frameWidth"]).map(Int.init)
            frameHeight = num(s["frameHeight"]).map(Int.init)
            if role == .host {
                bytesTransferred = Int64(num(s["bytesSent"]) ?? 0)
                framesTransferred = Int64(num(s["framesEncoded"]) ?? 0)
                if let t = num(s["totalEncodeTime"]), framesTransferred > 0 { averageEncodeMs = t / Double(framesTransferred) * 1000 }
                codecImplementation = str(s["encoderImplementation"])
                qualityLimitation = str(s["qualityLimitationReason"])
                targetBitrateKbps = num(s["targetBitrate"]).map { $0 / 1000 }
            } else {
                bytesTransferred = Int64(num(s["bytesReceived"]) ?? 0)
                framesTransferred = Int64(num(s["framesDecoded"]) ?? 0)
                framesDropped = Int64(num(s["framesDropped"]) ?? 0)
                packetsLost = Int64(num(s["packetsLost"]) ?? 0)
                jitterMs = num(s["jitter"]).map { $0 * 1000 }
                if let t = num(s["totalDecodeTime"]), framesTransferred > 0 { averageDecodeMs = t / Double(framesTransferred) * 1000 }
                if let d = num(s["jitterBufferDelay"]), let c = num(s["jitterBufferEmittedCount"]), c > 0 { jitterBufferMs = d / c * 1000 }
                codecImplementation = str(s["decoderImplementation"])
                freezeCount = num(s["freezeCount"]).map(Int.init)
            }
        }
    }

    /// Both addresses on one LAN: private / link-local IPv4, link-local or unique-local IPv6, or two
    /// global IPv6 addresses in the same /64.
    static func sameLocalNetwork(_ a: String?, _ b: String?) -> Bool {
        guard let a, let b else { return false }
        func isPrivateV4(_ s: String) -> Bool {
            let p = s.split(separator: ".").compactMap { Int($0) }
            guard p.count == 4 else { return false }
            return p[0] == 10 || (p[0] == 172 && (16...31).contains(p[1])) || (p[0] == 192 && p[1] == 168) || (p[0] == 169 && p[1] == 254)
        }
        if a.contains("."), b.contains(".") { return isPrivateV4(a) && isPrivateV4(b) }
        guard a.contains(":"), b.contains(":") else { return false }
        func groups(_ s: String) -> [UInt16]? {
            var addr = in6_addr()
            guard inet_pton(AF_INET6, s.split(separator: "%").first.map(String.init) ?? s, &addr) == 1 else { return nil }
            return withUnsafeBytes(of: &addr) { raw in (0..<8).map { UInt16(raw[$0 * 2]) << 8 | UInt16(raw[$0 * 2 + 1]) } }
        }
        guard let ga = groups(a), let gb = groups(b) else { return false }
        func isLocalScope(_ g: [UInt16]) -> Bool { g[0] & 0xFFC0 == 0xFE80 || g[0] & 0xFE00 == 0xFC00 }
        if isLocalScope(ga) && isLocalScope(gb) { return true }
        return ga[0..<4] == gb[0..<4]
    }

    /// Compute rates relative to an earlier sample.
    public mutating func computeRates(since previous: ConnectionStats?) {
        guard let previous else { return }
        let dt = timestamp.timeIntervalSince(previous.timestamp)
        guard dt > 0.2, bytesTransferred >= previous.bytesTransferred else { return }
        bitrateKbps = Double(bytesTransferred - previous.bytesTransferred) * 8 / dt / 1000
    }
}
