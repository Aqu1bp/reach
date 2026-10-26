import Foundation
import WebRTC

/// Logs one compact line of per-interval video pipeline numbers every couple of seconds while a
/// session is up. Averages are over the interval (deltas of WebRTC's cumulative counters), so a
/// slow moment shows up instead of being diluted by everything since the session started.
///
/// Host lines describe the send side (encode time, time packets wait in the pacer, frame sizes);
/// client lines the receive side (time to assemble a frame from its packets, jitter buffer, decode).
final class PerfSampler {
    private let role: ConnectionStats.Role
    private let pc: RTCPeerConnection
    private let label: String
    private var timer: DispatchSourceTimer?
    private var previous: [String: Double] = [:]
    private var previousAt: Date?
    private var loggedPairID: String?
    /// Called on the sampling queue with each sample's summary (route, bandwidth estimate…).
    var onSample: ((ConnectionStats) -> Void)?

    init(role: ConnectionStats.Role, pc: RTCPeerConnection, label: String) {
        self.role = role
        self.pc = pc
        self.label = label
    }

    func start(on queue: DispatchQueue, interval: TimeInterval = 2) {
        guard timer == nil else { return }
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + interval, repeating: interval, leeway: .milliseconds(100))
        t.setEventHandler { [weak self] in self?.sample() }
        t.resume()
        timer = t
    }

    func stop() {
        timer?.cancel()
        timer = nil
    }

    deinit { timer?.cancel() }

    private func sample() {
        pc.statistics { [weak self] report in
            guard let self else { return }
            let line = self.describe(report)
            ReachLog.info("perf", "\(self.label) \(line)")
            self.logCandidatePairsIfChanged(report)
            self.onSample?(ConnectionStats(report: report, role: self.role))
        }
    }

    /// Every candidate pair ICE tried, whenever the selected one changes: shows which paths existed
    /// (Wi-Fi, cellular, IPv6, USB…) and which worked.
    private func logCandidatePairsIfChanged(_ report: RTCStatisticsReport) {
        let stats = report.statistics
        func str(_ v: NSObject?) -> String? { v as? String }
        func num(_ v: NSObject?) -> Double? { (v as? NSNumber)?.doubleValue }
        guard let transport = stats.values.first(where: { $0.type == "transport" }),
              let selected = str(transport.values["selectedCandidatePairId"]), selected != loggedPairID else { return }
        loggedPairID = selected
        func describe(_ id: String?) -> String {
            guard let id, let c = stats[id]?.values else { return "?" }
            let net = str(c["networkType"]).map { "/\($0)" } ?? ""
            #if DEBUG
            let endpoint = "\(str(c["address"]) ?? "?"):\(num(c["port"]).map { Int($0) } ?? 0)"
            #else
            let endpoint = "-" // network addresses stay out of release-build logs
            #endif
            return "\(str(c["candidateType"]) ?? "?")\(net) \(endpoint) \(str(c["protocol"]) ?? "")"
        }
        let pairs = stats.values.filter { $0.type == "candidate-pair" }
        ReachLog.info("perf", "\(label) ICE pairs (\(pairs.count)):")
        for p in pairs.prefix(24) {
            let v = p.values
            let mark = p.id == selected ? "▶" : " "
            let rtt = num(v["currentRoundTripTime"]).map { String(format: " rtt=%.0fms", $0 * 1000) } ?? ""
            ReachLog.info("perf", "\(label)  \(mark) \(describe(str(v["localCandidateId"]))) → \(describe(str(v["remoteCandidateId"]))) " +
                          "\(str(v["state"]) ?? "?")\(rtt)")
        }
    }

    private func describe(_ report: RTCStatisticsReport) -> String {
        let stats = report.statistics
        func num(_ v: NSObject?) -> Double? { (v as? NSNumber)?.doubleValue }
        func str(_ v: NSObject?) -> String? { v as? String }

        var now: [String: Double] = [:]
        var parts: [String] = []
        let base = ConnectionStats(report: report, role: role)
        let route = "\(base.route.rawValue)(\(base.networkType ?? "?")/\(base.transportProtocol ?? "?") \(base.localCandidateType ?? "?")→\(base.remoteCandidateType ?? "?"))"
        parts.append("route=\(route)")
        if let rtt = base.roundTripMs { parts.append(String(format: "rtt=%.0fms", rtt)) }
        if let avail = base.availableBitrateKbps { parts.append(String(format: "avail=%.1fMbps", avail / 1000)) }

        let rtpType = role == .host ? "outbound-rtp" : "inbound-rtp"
        guard let rtp = stats.values.first(where: { $0.type == rtpType && str($0.values["kind"]) == "video" })?.values else {
            return parts.joined(separator: " ")
        }
        let keys = role == .host
            ? ["framesEncoded", "totalEncodeTime", "framesSent", "bytesSent", "packetsSent", "totalPacketSendDelay",
               "keyFramesEncoded", "retransmittedBytesSent", "nackCount", "pliCount", "hugeFramesSent"]
            : ["framesReceived", "framesDecoded", "framesDropped", "totalDecodeTime", "jitterBufferDelay",
               "jitterBufferEmittedCount", "totalProcessingDelay", "totalAssemblyTime", "framesAssembledFromMultiplePackets",
               "packetsReceived", "packetsLost", "bytesReceived", "nackCount", "pliCount", "freezeCount", "totalFreezesDuration",
               "keyFramesDecoded"]
        for k in keys { if let v = num(rtp[k]) { now[k] = v } }
        // Our encoder's own numbers: frames VideoToolbox's rate control skipped never show up in
        // WebRTC's stats, nor does the frame rate the encoder budgets for.
        let encoder: ScreenVideoEncoder.Counters? = role == .host ? ScreenVideoEncoder.counters : nil
        if let encoder { now["vtDropped"] = Double(encoder.droppedFrames) }
        let dt = previousAt.map { Date().timeIntervalSince($0) } ?? 0
        defer { previous = now; previousAt = Date() }
        func d(_ k: String) -> Double { max(0, (now[k] ?? 0) - (previous[k] ?? 0)) }
        func perMs(_ total: String, _ count: String) -> String {
            let c = d(count)
            return c > 0 ? String(format: "%.1f", d(total) / c * 1000) : "-"
        }
        guard dt > 0 else { return parts.joined(separator: " ") + " (warming up)" }

        if let codecID = str(rtp["codecId"]), let mime = str(stats[codecID]?.values["mimeType"]) {
            parts.append(mime.replacingOccurrences(of: "video/", with: ""))
        }
        if let w = num(rtp["frameWidth"]), let h = num(rtp["frameHeight"]) { parts.append("\(Int(w))x\(Int(h))") }
        if role == .host {
            let frames = d("framesEncoded")
            parts.append(String(format: "fps=%.1f", frames / dt))
            parts.append("enc=\(perMs("totalEncodeTime", "framesEncoded"))ms")
            parts.append("pacer=\(perMs("totalPacketSendDelay", "packetsSent"))ms")
            let sent = d("framesSent")
            parts.append(String(format: "frame=%.1fKB", sent > 0 ? d("bytesSent") / sent / 1024 : 0))
            parts.append(String(format: "rate=%.1fMbps", d("bytesSent") * 8 / dt / 1e6))
            if let t = num(rtp["targetBitrate"]) { parts.append(String(format: "target=%.1fMbps", t / 1e6)) }
            if let encoder, encoder.expectedFps > 0 {
                parts.append("vtdrop=\(Int(d("vtDropped"))) encfps=\(encoder.expectedFps) rtcfps=\(encoder.webrtcFps) enctarget=\(encoder.targetKbps)")
            }
            parts.append("kf=\(Int(d("keyFramesEncoded"))) huge=\(Int(d("hugeFramesSent"))) nack=\(Int(d("nackCount"))) pli=\(Int(d("pliCount")))")
            parts.append(String(format: "rtx=%.0fKB", d("retransmittedBytesSent") / 1024))
            if let q = str(rtp["qualityLimitationReason"]) { parts.append("limit=\(q)") }
            if let remote = stats.values.first(where: { $0.type == "remote-inbound-rtp" && str($0.values["kind"]) == "video" })?.values,
               let lost = num(remote["fractionLost"]) {
                parts.append(String(format: "loss=%.1f%%", lost * 100))
            }
        } else {
            parts.append(String(format: "fps=%.1f", d("framesDecoded") / dt))
            parts.append("asm=\(perMs("totalAssemblyTime", "framesAssembledFromMultiplePackets"))ms")
            parts.append("jb=\(perMs("jitterBufferDelay", "jitterBufferEmittedCount"))ms")
            parts.append("dec=\(perMs("totalDecodeTime", "framesDecoded"))ms")
            parts.append("proc=\(perMs("totalProcessingDelay", "framesDecoded"))ms")
            parts.append(String(format: "rate=%.1fMbps", d("bytesReceived") * 8 / dt / 1e6))
            parts.append("drop=\(Int(d("framesDropped"))) lost=\(Int(d("packetsLost"))) nack=\(Int(d("nackCount"))) pli=\(Int(d("pliCount"))) kf=\(Int(d("keyFramesDecoded")))")
            let freezes = d("freezeCount")
            if freezes > 0 { parts.append(String(format: "freezes=%d (%.0fms)", Int(freezes), d("totalFreezesDuration") * 1000)) }
        }
        return parts.joined(separator: " ")
    }
}
