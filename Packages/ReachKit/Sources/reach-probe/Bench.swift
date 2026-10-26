import Foundation
import CoreVideo
import VideoToolbox
import ReachCore
import ReachProtocol

// reach-probe bench — host + client in ONE process, signaling over the in-process loopback relay,
// media over real WebRTC (host candidates). Drives a scripted scenario on the synthetic screen and
// measures push → decode latency per frame by reading the row-0 barcode (capture timestamp) back out
// of every decoded frame. See Tools/README-bench.md.

struct BenchOptions {
    var width = 1512
    var height = 982
    var fps = 60
    var scenario = "bursts"
    /// "text": a pre-rendered page of dense text scrolled by copying rows (cheap, every pixel changes);
    /// "video": the same page, a random window every frame (jump cuts: no inter prediction);
    /// "desktop": the interactive SyntheticScreen, re-rendered with CoreGraphics every frame.
    var content = "text"
    var idle = 3.0
    var motion = 2.0
    var cycles = 4
    var settle = 2.0
    var step = 4.0
    var quality: QualityMode = .balanced
    var policy: String?
    var reportPath: String?
    var label: String?
}

/// One frame handed to `HostEngine.pushVideoFrame`.
struct BenchPush {
    var cycle: Int          // -1 = initial frame
    var ts: UInt64          // row-0 barcode value (uptime ms at frame creation)
    var at: Double          // uptime ms right before the push
    var renderMs: Double
    var barcodeMs: Double = 0   // Barcode.read of the pushed frame
    var pushMs: Double = 0      // HostEngine.pushVideoFrame call
    var recordMs: Double = 0    // BenchRecorder.addPush
    var wakeLateMs: Double = 0  // how late the scenario thread woke for this tick
}

/// One frame delivered by `ClientSession.onVideoFrame`.
struct BenchDecode {
    var at: Double
    var ts: UInt64?
    /// Row 1: the same timestamp again for the text/video content (nil for the desktop content).
    var ts2: UInt64?
}

struct BenchCycle {
    var index: Int
    var idleStart: Double
    var motionStart: Double = 0
    var motionEnd: Double = 0
    var firstPushAt: Double?
}

/// Thread-safe store for everything the scenario and the decode callback record.
final class BenchRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var _pushes: [BenchPush] = []
    private var _decodes: [BenchDecode] = []
    private var _frameSize = (0, 0)
    private var _stats: [String: ConnectionStats] = [:]

    func setStats(_ s: ConnectionStats, key: String) { lock.withLock { _stats[key] = s } }
    func stats(_ key: String) -> ConnectionStats? { lock.withLock { _stats[key] } }

    @discardableResult
    func addPush(_ p: BenchPush) -> Int { lock.withLock { _pushes.append(p); return _pushes.count - 1 } }
    func setRecordMs(_ ms: Double, at index: Int) { lock.withLock { if index < _pushes.count { _pushes[index].recordMs = ms } } }
    func addDecode(_ d: BenchDecode, width: Int, height: Int) {
        lock.withLock {
            _decodes.append(d)
            _frameSize = (width, height)
        }
    }
    var pushes: [BenchPush] { lock.withLock { _pushes } }
    var decodes: [BenchDecode] { lock.withLock { _decodes } }
    var decodeCount: Int { lock.withLock { _decodes.count } }
    var firstDecodeAt: Double? { lock.withLock { _decodes.first?.at } }
    var frameSize: (Int, Int) { lock.withLock { _frameSize } }
}

func nowNs() -> UInt64 { DispatchTime.now().uptimeNanoseconds }
func nowMsPrecise() -> Double { Double(nowNs()) / 1e6 }

final class BenchHostDelegate: HostEngineDelegate {
    var sessionStarted = false
    var sessionEndReason: String?

    func hostEngine(_ engine: HostEngine, relayStatusChanged online: Bool) {}
    func hostEngine(_ engine: HostEngine, didPair client: TrustedClient) {
        print("bench: host paired with \(client.name)")
    }
    func hostEngine(_ engine: HostEngine, sessionDidStart session: HostSessionInfo) {
        sessionStarted = true
    }
    func hostEngine(_ engine: HostEngine, sessionDidEnd session: HostSessionInfo, reason: String) {
        sessionEndReason = reason
    }
    func hostEngine(_ engine: HostEngine, didReceive message: ClientMessage) {}
    func hostEngine(_ engine: HostEngine, didReceivePointer packet: PointerPacket) {}
}

final class BenchRunner {
    let opt: BenchOptions
    private let rec = BenchRecorder()
    private let screen: SyntheticScreen
    private let document: ScrollingDocument?
    private var contentUsed: String
    private let tempDir: URL
    private var host: HostEngine!
    private let hostDelegate = BenchHostDelegate()
    private var client: ClientEngine!
    private var session: ClientSession?
    private var cycles: [BenchCycle] = []
    /// Set when the session fails mid-scenario: the scenario thread stops at its next frame, so the
    /// report never reads `cycles` while that thread can still append to it.
    private let stopLock = NSLock()
    private var _stopRequested = false
    private var stopRequested: Bool {
        get { stopLock.withLock { _stopRequested } }
        set { stopLock.withLock { _stopRequested = newValue } }
    }
    private var errors: [String] = []
    private var scrollOffset = 0.0
    private var scrollDir = 1.0

    init(_ opt: BenchOptions) {
        self.opt = opt
        screen = SyntheticScreen(width: opt.width, height: opt.height)
        var doc: ScrollingDocument?
        var used = "desktop"
        if opt.content == "text" || opt.content == "video" {
            let r0 = nowNs()
            doc = ScrollingDocument(width: opt.width, height: opt.height)
            if let d = doc {
                print(String(format: "bench: text page %ldx%ld rendered in %.0f ms", d.pixelWidth, d.documentHeight, Double(nowNs() &- r0) / 1e6))
                used = opt.content
            } else {
                print("bench: WARNING could not render the text page; using the desktop content")
            }
        }
        document = doc
        contentUsed = used
        let id = UUID().uuidString.prefix(8).lowercased()
        tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("reach-bench-\(id)", isDirectory: true)
    }

    // MARK: Main-thread helpers

    /// Pump the main run loop (delegate and stats callbacks arrive on main) until `done` or timeout.
    @discardableResult
    private func pump(timeout: TimeInterval, until done: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !done() {
            if Date() >= deadline { return false }
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        return true
    }

    private func pump(seconds: TimeInterval) {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
    }

    private func snapshot() -> (host: ConnectionStats?, client: ConnectionStats?) {
        var h: ConnectionStats?
        var c: ConnectionStats?
        var hDone = false, cDone = false
        host.stats { s in h = s; hDone = true }
        if let session {
            session.stats { s in c = s; cDone = true }
        } else {
            cDone = true
        }
        pump(timeout: 5) { hDone && cDone }
        return (h, c)
    }

    // MARK: Run

    func run() -> Bool {
        // Without an input source or timer, `RunLoop.run(until:)` returns at once and the pump loops
        // would spin a core that the encoder and decoder need. A dormant timer makes it sleep.
        let keepAlive = Timer(timeInterval: 3600, repeats: true) { _ in }
        RunLoop.main.add(keepAlive, forMode: .default)
        defer {
            keepAlive.invalidate()
            cleanUp()
        }
        do {
            try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        } catch {
            print("bench: cannot create \(tempDir.path): \(error)")
            return false
        }
        let relay = RelayEndpoint.local("bench-\(tempDir.lastPathComponent)")
        let hostDir = tempDir.appendingPathComponent("host", isDirectory: true)
        let clientDir = tempDir.appendingPathComponent("client", isDirectory: true)
        try? FileManager.default.createDirectory(at: hostDir, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: clientDir, withIntermediateDirectories: true)

        print("bench: \(opt.label ?? "run") scenario=\(opt.scenario) content=\(contentUsed) size=\(screen.pixelWidth)x\(screen.pixelHeight) fps=\(opt.fps) " +
              "cycles=\(opt.cycles) idle=\(opt.idle)s motion=\(opt.motion)s quality=\(opt.quality.rawValue)")
        let env = benchEnvironment()
        print("bench: env \(env.isEmpty ? "(none)" : env.map { "\($0.key)=\($0.value)" }.sorted().joined(separator: " "))")

        // Host
        let hostIdentity: LocalIdentity
        let clientIdentity: LocalIdentity
        do {
            hostIdentity = try LocalIdentity.loadOrCreate(in: FileSecretStore(directory: hostDir), key: "host-identity")
            clientIdentity = try LocalIdentity.loadOrCreate(in: FileSecretStore(directory: clientDir), key: "client-identity")
        } catch {
            print("bench: identity setup failed: \(error)")
            return false
        }
        let trust = TrustStore(fileURL: hostDir.appendingPathComponent("trusted-clients.json"))
        host = HostEngine(identity: hostIdentity, trustStore: trust, relays: [relay], iceServers: []) {
            HostInfo(name: "Bench Mac", model: "MacBook Pro", modelIdentifier: "Probe1,1",
                     osVersion: ProcessInfo.processInfo.operatingSystemVersionString, appVersion: "bench")
        }
        host.iceTransportPolicyOverride = opt.policy
        host.delegate = hostDelegate
        host.start()

        // Client
        client = ClientEngine(identity: clientIdentity, store: PairedHostStore(secrets: FileSecretStore(directory: clientDir)), relays: [relay],
                              deviceName: "reach-bench", deviceModel: "Probe")

        // Pair
        let code = host.makePairingCode(hostName: "Bench Mac", validFor: 600)
        var paired: PairedHost?
        var pairError: String?
        let pairStart = nowMsPrecise()
        client.pair(using: code) { result in
            switch result {
            case .success(let h): paired = h
            case .failure(let e): pairError = e.localizedDescription
            }
        }
        pump(timeout: 30) { paired != nil || pairError != nil }
        guard let pairedHost = paired else {
            print("bench: PAIR FAILED: \(pairError ?? "timeout")")
            writeFailure("pair failed: \(pairError ?? "timeout")")
            return false
        }
        let pairMs = nowMsPrecise() - pairStart
        print(String(format: "bench: paired in %.0f ms", pairMs))

        // Connect
        let hello = ClientHello(name: "reach-bench", deviceModel: "Probe", appVersion: "bench", screenPixelWidth: 2796,
                                screenPixelHeight: 1290, quality: QualityPreference(mode: opt.quality, maxFramesPerSecond: opt.fps))
        let t0 = nowMsPrecise()
        let s = client.connect(to: pairedHost, hello: hello, iceTransportPolicy: opt.policy)
        session = s
        var connectedAt: Double?
        var failure: String?
        s.onState = { [weak self] st in
            if st == .connected, connectedAt == nil { connectedAt = nowMsPrecise() }
            if case .failed(let r) = st { failure = r }
            if case .closed(let r) = st { failure = r }
            if st == .reconnecting { self?.errors.append(String(format: "reconnecting at +%.0f ms", nowMsPrecise() - t0)) }
        }
        let recorder = rec
        let redundant = document != nil
        s.onVideoFrame = { buffer, _ in
            let at = nowMsPrecise()
            let ts = Barcode.read(row: 0, from: buffer)
            let ts2 = redundant ? Barcode.read(row: 1, from: buffer) : nil
            recorder.addDecode(BenchDecode(at: at, ts: ts, ts2: ts2), width: CVPixelBufferGetWidth(buffer), height: CVPixelBufferGetHeight(buffer))
        }
        pump(timeout: 30) { connectedAt != nil || failure != nil }
        guard let connected = connectedAt else {
            print("bench: CONNECT FAILED: \(failure ?? "timeout")")
            writeFailure("connect failed: \(failure ?? "timeout")")
            return false
        }
        let connectMs = connected - t0
        print(String(format: "bench: connected in %.0f ms", connectMs))

        // First frame: the initial "screen", like capture delivering its first frame.
        pushFrame(cycle: -1, scroll: false)
        pump(timeout: 10) { self.rec.decodeCount > 0 }
        let firstFrameMs = rec.firstDecodeAt.map { $0 - t0 }
        if let f = firstFrameMs {
            print(String(format: "bench: first frame %.0f ms after connect() (%ldx%ld)", f, rec.frameSize.0, rec.frameSize.1))
        } else {
            print("bench: WARNING no first frame within 10 s; continuing")
            errors.append("no first frame within 10 s")
        }
        // Let the post-change refresh (1.5 s) finish so cycle 1 starts from a genuinely idle stream.
        pump(seconds: 2.0)

        let start = snapshot()
        let scenarioStart = nowMsPrecise()

        // Scenario on its own thread; main keeps pumping.
        let done = DispatchSemaphore(value: 0)
        let thread = Thread { [self] in
            self.runScenario()
            done.signal()
        }
        thread.qualityOfService = .userInteractive
        thread.name = "bench.scenario"
        thread.start()
        // `done` is signalled once: remember when it has been consumed so it's never waited for twice.
        var finished = false
        while !finished {
            if done.wait(timeout: .now()) == .success { finished = true; break }
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
            if failure != nil { break }
        }
        if let failure {
            errors.append("session ended during scenario: \(failure)")
            // Stop the scenario thread and wait for it (at most one frame, idle or settle sleep), so the
            // report is coherent. Keep pumping main: host stats completions arrive there.
            stopRequested = true
            while !finished {
                if done.wait(timeout: .now()) == .success { finished = true; break }
                RunLoop.main.run(until: Date().addingTimeInterval(0.02))
            }
        }

        let end = snapshot()
        let scenarioEnd = nowMsPrecise()

        let report = buildReport(connectMs: connectMs, pairMs: pairMs, firstFrameMs: firstFrameMs, start: start, end: end,
                                 scenarioStart: scenarioStart, scenarioEnd: scenarioEnd, env: env)
        s.close()
        host.stop()
        pump(seconds: 0.5)

        printSummary(report)
        writeReport(report)
        // Same verdict as the report's "ok", so a session that dies mid-scenario fails the run (and CI).
        let ok = report["ok"] as? Bool ?? false
        if rec.decodeCount == 0 { print("bench: FAILED — no frames decoded") } else if !ok { print("bench: FAILED — \(errors.joined(separator: "; "))") }
        return ok
    }

    private func cleanUp() {
        try? FileManager.default.removeItem(at: tempDir)
    }

    // MARK: Scenario (scenario thread)

    private func applyScroll() {
        // Bounce inside the list so every tick really moves it (the screen clamps the offset).
        if scrollOffset + opt.step * scrollDir > 1100 || scrollOffset + opt.step * scrollDir < 0 { scrollDir = -scrollDir }
        scrollOffset += opt.step * scrollDir
        screen.scroll(dy: -opt.step * scrollDir)
    }

    @discardableResult
    private func pushFrame(cycle: Int, scroll: Bool, wakeLateMs: Double = 0) -> Double? {
        let r0 = nowNs()
        let produced: CVPixelBuffer?
        if let document {
            if scroll {
                if contentUsed == "video" { document.jump() } else { document.scroll(points: opt.step) }
            }
            produced = document.nextFrame()
        } else {
            if scroll { applyScroll() }
            produced = screen.nextFrame()
        }
        guard let frame = produced else { return nil }
        let r1 = nowNs()
        let ts = Barcode.read(row: 0, from: frame) ?? 0
        let r2 = nowNs()
        let at = Double(r2) / 1e6
        host.pushVideoFrame(frame)
        let r3 = nowNs()
        let index = rec.addPush(BenchPush(cycle: cycle, ts: ts, at: at, renderMs: Double(r1 &- r0) / 1e6,
                                          barcodeMs: Double(r2 &- r1) / 1e6, pushMs: Double(r3 &- r2) / 1e6,
                                          wakeLateMs: wakeLateMs))
        rec.setRecordMs(Double(nowNs() &- r3) / 1e6, at: index)
        return at
    }

    private static let timebase: mach_timebase_info_data_t = {
        var t = mach_timebase_info_data_t()
        mach_timebase_info(&t)
        return t
    }()

    /// Sleep until `target` (uptime ns). A timed wait on a CI VM wakes 10–75 ms late (idle vCPUs
    /// are slow to reschedule), so only the part beyond `spinNs` is slept with `mach_wait_until`;
    /// the rest is a spin, which keeps the push cadence exact at the cost of one core during a burst.
    private static let spinNs: UInt64 = 25_000_000
    private func sleepUntil(ns target: UInt64) {
        let n = nowNs()
        if target > n + Self.spinNs {
            let tb = Self.timebase
            let ticks = (target - n - Self.spinNs) * UInt64(tb.denom) / UInt64(max(1, tb.numer))
            mach_wait_until(mach_absolute_time() + ticks)
        }
        while nowNs() < target {}
    }

    /// Push one frame per tick for `seconds`, scrolling a few points every tick.
    private func motion(cycle: Int, seconds: Double, into c: inout BenchCycle) {
        let period = UInt64(1_000_000_000 / max(1, opt.fps))
        let ticks = max(1, Int((seconds * Double(opt.fps)).rounded()))
        // Host stats right before the burst, after its first `onsetTicks` frames (~250 ms) and at its
        // end: bytes per frame sent and pacer delay of the burst's first frames vs the rest.
        let onsetTicks = max(2, opt.fps / 4)
        hostStats(key: "\(cycle)-a", wait: true)
        var next = nowNs()
        c.motionStart = nowMsPrecise()
        for tick in 0..<ticks {
            if stopRequested { break }
            sleepUntil(ns: next)
            let late = Double(nowNs() &- next) / 1e6
            let at = pushFrame(cycle: cycle, scroll: true, wakeLateMs: late)
            if c.firstPushAt == nil { c.firstPushAt = at }
            if tick == onsetTicks - 1 && ticks > onsetTicks { hostStats(key: "\(cycle)-b", wait: false) }
            next += period
            // Running late (slow rendering): don't burst to catch up.
            let n = nowNs()
            if next < n { next = n }
        }
        sleepUntil(ns: next)
        c.motionEnd = nowMsPrecise()
        hostStats(key: "\(cycle)-c", wait: false)
    }

    /// Snapshot host stats into the recorder (completion arrives on main, which keeps pumping).
    private func hostStats(key: String, wait: Bool) {
        let sem = DispatchSemaphore(value: 0)
        let recorder = rec
        host.stats { s in
            if let s { recorder.setStats(s, key: key) }
            sem.signal()
        }
        if wait { _ = sem.wait(timeout: .now() + 0.5) }
    }

    private func runScenario() {
        let continuous = opt.scenario == "continuous"
        for i in 0..<max(1, opt.cycles) {
            if stopRequested { return }
            var c = BenchCycle(index: i, idleStart: nowMsPrecise())
            if continuous {
                motion(cycle: i, seconds: opt.idle + opt.motion, into: &c)
            } else {
                // Idle: push NOTHING; HostEngine's refresh/keepalive and the encoder behave as in the app.
                sleepUntil(ns: nowNs() + UInt64(opt.idle * 1e9))
                if stopRequested { return }
                motion(cycle: i, seconds: opt.motion, into: &c)
            }
            cycles.append(c)
            let pushed = rec.pushes.filter { $0.cycle == i }.count
            print(String(format: "bench: cycle %ld done: pushed %ld frames in %.2f s", i + 1, pushed, (c.motionEnd - c.motionStart) / 1000))
        }
        // Trailing settle window for the last burst.
        sleepUntil(ns: nowNs() + UInt64(max(opt.settle, 0.5) * 1e9))
    }

    // MARK: Report

    private func benchEnvironment() -> [String: String] {
        ProcessInfo.processInfo.environment.filter { $0.key.hasPrefix("REACH_") }
    }

    private func buildReport(connectMs: Double, pairMs: Double, firstFrameMs: Double?, start: (host: ConnectionStats?, client: ConnectionStats?),
                             end: (host: ConnectionStats?, client: ConnectionStats?), scenarioStart: Double, scenarioEnd: Double,
                             env: [String: String]) -> [String: Any] {
        let pushes = rec.pushes
        let decodes = rec.decodes.sorted { $0.at < $1.at }

        // Match each push to the first decoded frame carrying its timestamp.
        var pushIndexByTs: [UInt64: Int] = [:]
        for (i, p) in pushes.enumerated() { pushIndexByTs[p.ts] = i }
        var firstDecodeAt = [Double?](repeating: nil, count: pushes.count)
        var isFirstDecode = [Bool](repeating: false, count: decodes.count)
        var repeats = 0, unmatched = 0, rowsDisagree = 0, recoveredByRow1 = 0
        for (k, d) in decodes.enumerated() {
            // A row only counts if it names a push made before this decode (a misread can name a later
            // one, which would give a negative latency). If both rows name different such pushes, the
            // frame is ambiguous and isn't used: a misread there would credit the wrong push.
            func match(_ ts: UInt64?) -> Int? {
                guard let ts, let i = pushIndexByTs[ts], pushes[i].at <= d.at else { return nil }
                return i
            }
            if let a = d.ts, let b = d.ts2, a != b { rowsDisagree += 1 }
            let m0 = match(d.ts), m1 = match(d.ts2)
            var index: Int?
            if let m0, let m1, m0 != m1 {
                index = nil
            } else if let m0 {
                index = m0
            } else if let m1 {
                index = m1
                recoveredByRow1 += 1
            }
            guard let i = index else { unmatched += 1; continue }
            if firstDecodeAt[i] == nil {
                firstDecodeAt[i] = d.at
                isFirstDecode[k] = true
            } else {
                repeats += 1
            }
        }

        var cycleDicts: [[String: Any]] = []
        var allLatencies: [Double] = [], allGaps: [Double] = []
        var totalPushed = 0, totalDecoded = 0, totalStalls = 0
        var scalars: [String: [Double]] = [:]
        func addScalar(_ k: String, _ v: Double?) { if let v, v.isFinite { scalars[k, default: []].append(v) } }

        for (ci, c) in cycles.enumerated() {
            let idx = pushes.indices.filter { pushes[$0].cycle == c.index }
            let pushed = idx.count
            var lat: [Double] = []
            var arrivals: [Double] = []
            var onset: (lat: Double, at: Double)?
            for i in idx {
                guard let at = firstDecodeAt[i] else { continue }
                let l = at - pushes[i].at
                lat.append(l)
                arrivals.append(at)
                if onset == nil || at < onset!.at { onset = (l, at) }
            }
            arrivals.sort()
            var gaps: [Double] = []
            if arrivals.count > 1 { for k in 1..<arrivals.count { gaps.append(arrivals[k] - arrivals[k - 1]) } }
            let stalls = gaps.filter { $0 > 50 }.count
            let decoded = lat.count
            let motionSeconds = max(0.001, (c.motionEnd - c.motionStart) / 1000)
            let dropPct = pushed > 0 ? Double(pushed - decoded) / Double(pushed) * 100 : nil
            let fps = Double(decoded) / motionSeconds
            let onsetWait = onset.flatMap { o in c.firstPushAt.map { o.at - $0 } }
            // Settle: frames decoded after motion stops (refresh/sharpening), up to `settle` s or the next burst.
            let nextMotion = ci + 1 < cycles.count ? cycles[ci + 1].motionStart : Double.infinity
            let settleEnd = min(c.motionEnd + opt.settle * 1000, nextMotion)
            var settleFrames = 0
            var settleLast: Double?
            var idleDecoded = 0
            let idleFrom = ci > 0 ? max(cycles[ci - 1].motionEnd + opt.settle * 1000, c.idleStart) : c.idleStart
            for (k, d) in decodes.enumerated() {
                if d.at >= c.motionEnd && d.at < settleEnd && !isFirstDecode[k] {
                    settleFrames += 1
                    settleLast = d.at - c.motionEnd
                }
                if d.at >= idleFrom && d.at < c.motionStart { idleDecoded += 1 }
            }
            let renders = idx.map { pushes[$0].renderMs }
            var ticks: [Double] = []
            if idx.count > 1 { for k in 1..<idx.count { ticks.append(pushes[idx[k]].at - pushes[idx[k - 1]].at) } }
            let burst = sendWindow(rec.stats("\(c.index)-a"), rec.stats("\(c.index)-c"))
            let onsetWindow = sendWindow(rec.stats("\(c.index)-a"), rec.stats("\(c.index)-b"))
            let restWindow = sendWindow(rec.stats("\(c.index)-b"), rec.stats("\(c.index)-c"))
            addScalar("frames_encoded", burst.encoded.map { Double($0) })
            addScalar("onset_frame_kb", onsetWindow.frameKB)
            addScalar("onset_pacer_ms", onsetWindow.pacerMs)
            addScalar("rest_frame_kb", restWindow.frameKB)
            addScalar("rest_pacer_ms", restWindow.pacerMs)

            allLatencies += lat
            allGaps += gaps
            totalPushed += pushed
            totalDecoded += decoded
            totalStalls += stalls
            addScalar("onset_ms", onset?.lat)
            addScalar("onset_wait_ms", onsetWait)
            addScalar("motion_fps", fps)
            addScalar("motion_drop_pct", dropPct)
            addScalar("settle_frames", Double(settleFrames))
            addScalar("stalls_over_50ms", Double(stalls))
            addScalar("lat_p50", pct(lat, 0.5)); addScalar("lat_p90", pct(lat, 0.9))
            addScalar("lat_p99", pct(lat, 0.99)); addScalar("lat_max", lat.max())
            addScalar("gap_p95", pct(gaps, 0.95)); addScalar("gap_p99", pct(gaps, 0.99)); addScalar("gap_max", gaps.max())

            cycleDicts.append([
                "cycle": c.index + 1,
                "motion_start_s": jn((c.motionStart - scenarioStart) / 1000),
                "motion_seconds": jn(motionSeconds),
                "motion_pushed": pushed,
                "motion_decoded": decoded,
                "motion_drop_pct": jn(dropPct),
                "push_fps": jn(Double(pushed) / motionSeconds),
                "motion_fps": jn(fps),
                "onset_ms": jn(onset?.lat),
                "onset_wait_ms": jn(onsetWait),
                "motion_latency_ms": dist(lat, [0.5, 0.9, 0.99]),
                "motion_gap_ms": dist(gaps, [0.5, 0.95, 0.99]),
                "stalls_over_50ms": stalls,
                "settle_frames": settleFrames,
                "settle_last_ms": jn(settleLast),
                "idle_decoded": idleDecoded,
                "render_ms": dist(renders, [0.5, 0.99]),
                "barcode_ms": dist(idx.map { pushes[$0].barcodeMs }, [0.5, 0.99]),
                "push_ms": dist(idx.map { pushes[$0].pushMs }, [0.5, 0.99]),
                "record_ms": dist(idx.map { pushes[$0].recordMs }, [0.5, 0.99]),
                "wake_late_ms": dist(idx.map { pushes[$0].wakeLateMs }, [0.5, 0.99]),
                "tick_ms": dist(ticks, [0.5, 0.95]),
                "frames_encoded": orNull(burst.encoded),
                "frames_sent": orNull(burst.frames),
                "onset_frame_kb": jn(onsetWindow.frameKB),
                "onset_pacer_ms": jn(onsetWindow.pacerMs),
                "onset_frames_sent": orNull(onsetWindow.frames),
                "rest_frame_kb": jn(restWindow.frameKB),
                "rest_pacer_ms": jn(restWindow.pacerMs),
                "rest_frames_sent": orNull(restWindow.frames),
            ])
        }

        func med(_ k: String) -> Any { jn(median(scalars[k] ?? [])) }
        let aggregate: [String: Any] = [
            "onset_ms": med("onset_ms"),
            "onset_wait_ms": med("onset_wait_ms"),
            "motion_fps": med("motion_fps"),
            "motion_drop_pct": med("motion_drop_pct"),
            "settle_frames": med("settle_frames"),
            "stalls_over_50ms": med("stalls_over_50ms"),
            "frames_encoded": med("frames_encoded"),
            "onset_frame_kb": med("onset_frame_kb"),
            "onset_pacer_ms": med("onset_pacer_ms"),
            "rest_frame_kb": med("rest_frame_kb"),
            "rest_pacer_ms": med("rest_pacer_ms"),
            "motion_latency_ms": ["p50": med("lat_p50"), "p90": med("lat_p90"), "p99": med("lat_p99"), "max": med("lat_max")],
            "motion_gap_ms": ["p95": med("gap_p95"), "p99": med("gap_p99"), "max": med("gap_max")],
        ]
        let pooled: [String: Any] = [
            "motion_pushed": totalPushed,
            "motion_decoded": totalDecoded,
            "motion_drop_pct": jn(totalPushed > 0 ? Double(totalPushed - totalDecoded) / Double(totalPushed) * 100 : nil),
            "motion_latency_ms": dist(allLatencies, [0.5, 0.9, 0.99]),
            "motion_gap_ms": dist(allGaps, [0.5, 0.95, 0.99]),
            "stalls_over_50ms": totalStalls,
        ]

        let h1 = end.host ?? start.host, c1 = end.client ?? start.client
        let size = rec.frameSize
        var report: [String: Any] = [
            "label": orNull(opt.label),
            "scenario": opt.scenario,
            "options": [
                "width": screen.pixelWidth, "height": screen.pixelHeight, "fps": opt.fps, "cycles": opt.cycles,
                "idle_s": opt.idle, "motion_s": opt.motion, "settle_s": opt.settle, "step_pt": opt.step,
                "quality": opt.quality.rawValue, "policy": orNull(opt.policy), "content": contentUsed,
                "onset_window_frames": max(2, opt.fps / 4),
            ] as [String: Any],
            "env": env,
            "machine": machineInfo(),
            "pair_ms": jn(pairMs),
            "connect_ms": jn(connectMs),
            "first_frame_ms": jn(firstFrameMs),
            "frame_width": size.0,
            "frame_height": size.1,
            "codec": orNull(h1?.codecName ?? c1?.codecName),
            "encoder": orNull(h1?.codecImplementation),
            "decoder": orNull(c1?.codecImplementation),
            "route": orNull(c1?.route.rawValue),
            "candidates": "\(c1?.localCandidateType ?? "?")/\(c1?.transportProtocol ?? "?")→\(c1?.remoteCandidateType ?? "?")",
            "cycles": cycleDicts,
            "aggregate": aggregate,
            "pooled": pooled,
            "first_cycle": orNull(cycleDicts.first),
            "totals": [
                "pushes": pushes.count, "decodes": decodes.count, "repeat_decodes": repeats, "unmatched_decodes": unmatched,
                "barcode_rows_disagree": rowsDisagree, "recovered_by_row1": recoveredByRow1,
                "scenario_s": jn((scenarioEnd - scenarioStart) / 1000),
            ] as [String: Any],
            "stats": statsDeltas(start: start, end: end),
            "errors": errors,
        ]
        report["ok"] = decodes.count > 0 && errors.filter { $0.hasPrefix("session ended") }.isEmpty
        return report
    }

    /// Host send-side numbers between two snapshots: frames sent, KB per frame, pacer ms per packet.
    private func sendWindow(_ a: ConnectionStats?, _ b: ConnectionStats?)
        -> (frames: Int64?, encoded: Int64?, frameKB: Double?, pacerMs: Double?) {
        guard let a, let b else { return (nil, nil, nil, nil) }
        let frames = b.framesSent - a.framesSent
        let packets = b.packetsSent - a.packetsSent
        let kb = frames > 0 ? Double(b.bytesTransferred - a.bytesTransferred) / Double(frames) / 1024 : nil
        let pacer = packets > 0 ? (b.totalPacketSendDelay - a.totalPacketSendDelay) / Double(packets) * 1000 : nil
        return (frames, b.framesEncoded - a.framesEncoded, kb, pacer)
    }

    private func statsDeltas(start: (host: ConnectionStats?, client: ConnectionStats?),
                             end: (host: ConnectionStats?, client: ConnectionStats?)) -> [String: Any] {
        var out: [String: Any] = [:]
        func per(_ total: Double, _ count: Int64) -> Any { jn(count > 0 ? total / Double(count) * 1000 : nil) }
        if let a = start.host, let b = end.host {
            let dt = b.timestamp.timeIntervalSince(a.timestamp)
            let frames = b.framesEncoded - a.framesEncoded
            let sent = b.framesSent - a.framesSent
            let bytes = b.bytesTransferred - a.bytesTransferred
            out["host"] = [
                "duration_s": jn(dt),
                "bitrate_kbps": jn(dt > 0 ? Double(bytes) * 8 / dt / 1000 : nil),
                "frames_encoded": frames,
                "frames_sent": sent,
                "encode_fps": jn(dt > 0 ? Double(frames) / dt : nil),
                "encode_ms_per_frame": per(b.totalEncodeTime - a.totalEncodeTime, frames),
                "pacer_ms_per_packet": per(b.totalPacketSendDelay - a.totalPacketSendDelay, b.packetsSent - a.packetsSent),
                "packets_sent": b.packetsSent - a.packetsSent,
                "avg_frame_kb": jn(sent > 0 ? Double(bytes) / Double(sent) / 1024 : nil),
                "huge_frames": b.hugeFramesSent - a.hugeFramesSent,
                "key_frames": b.keyFramesEncoded - a.keyFramesEncoded,
                "nack_received": b.nackCount - a.nackCount,
                "pli_received": b.pliCount - a.pliCount,
                "retransmitted_kb": jn(Double(b.retransmittedBytesSent - a.retransmittedBytesSent) / 1024),
                "target_bitrate_kbps_end": jn(b.targetBitrateKbps),
                "available_bitrate_kbps_end": jn(b.availableBitrateKbps),
                "quality_limitation_end": orNull(b.qualityLimitation),
                "rtt_ms_end": jn(b.roundTripMs),
                "pacer_ms_cumulative_end": jn(b.pacerDelayMs),
            ] as [String: Any]
        }
        if let a = start.client, let b = end.client {
            let dt = b.timestamp.timeIntervalSince(a.timestamp)
            let bytes = b.bytesTransferred - a.bytesTransferred
            let decoded = b.framesDecoded - a.framesDecoded
            out["client"] = [
                "duration_s": jn(dt),
                "bitrate_kbps": jn(dt > 0 ? Double(bytes) * 8 / dt / 1000 : nil),
                "frames_received": b.framesReceived - a.framesReceived,
                "frames_decoded": decoded,
                "frames_dropped": b.framesDropped - a.framesDropped,
                "packets_received": b.packetsReceived - a.packetsReceived,
                "packets_lost": b.packetsLost - a.packetsLost,
                "jitter_buffer_ms_per_frame": per(b.jitterBufferDelay - a.jitterBufferDelay, b.jitterBufferEmittedCount - a.jitterBufferEmittedCount),
                "assembly_ms_per_frame": per(b.totalAssemblyTime - a.totalAssemblyTime,
                                             b.framesAssembledFromMultiplePackets - a.framesAssembledFromMultiplePackets),
                "decode_ms_per_frame": per(b.totalDecodeTime - a.totalDecodeTime, decoded),
                "processing_ms_per_frame": per(b.totalProcessingDelay - a.totalProcessingDelay, decoded),
                "freezes": (b.freezeCount ?? 0) - (a.freezeCount ?? 0),
                "freeze_ms": jn((b.totalFreezesDuration - a.totalFreezesDuration) * 1000),
                "key_frames_decoded": b.keyFramesDecoded - a.keyFramesDecoded,
                "nack_sent": b.nackCount - a.nackCount,
                "pli_sent": b.pliCount - a.pliCount,
                "rtt_ms_end": jn(b.roundTripMs),
            ] as [String: Any]
        }
        return out
    }

    private func machineInfo() -> [String: Any] {
        [
            "os": ProcessInfo.processInfo.operatingSystemVersionString,
            "model": orNull(sysctlString("hw.model")),
            "cpu": orNull(sysctlString("machdep.cpu.brand_string")),
            "cores": ProcessInfo.processInfo.activeProcessorCount,
            "hw_hevc_decode": VTIsHardwareDecodeSupported(kCMVideoCodecType_HEVC),
            "hw_h264_decode": VTIsHardwareDecodeSupported(kCMVideoCodecType_H264),
        ]
    }

    // MARK: Output

    private func writeFailure(_ reason: String) {
        errors.append(reason)
        let report: [String: Any] = ["label": orNull(opt.label), "ok": false, "errors": errors, "env": benchEnvironment(),
                                     "machine": machineInfo()]
        writeReport(report)
    }

    private func writeReport(_ report: [String: Any]) {
        guard let path = opt.reportPath else { return }
        do {
            let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: URL(fileURLWithPath: path))
            print("bench: report written to \(path)")
        } catch {
            print("bench: could not write report: \(error)")
        }
    }

    private func printSummary(_ r: [String: Any]) {
        func s(_ v: Any?) -> String {
            if let n = v as? NSNumber {
                let d = n.doubleValue
                return d == d.rounded() ? String(format: "%.0f", d) : String(format: "%.1f", d)
            }
            if let x = v as? String { return x }
            return "-"
        }
        let agg = r["aggregate"] as? [String: Any] ?? [:]
        let pooled = r["pooled"] as? [String: Any] ?? [:]
        let pl = pooled["motion_latency_ms"] as? [String: Any] ?? [:]
        let pg = pooled["motion_gap_ms"] as? [String: Any] ?? [:]
        print("BENCH SUMMARY (\(opt.label ?? opt.scenario))")
        print("  codec=\(s(r["codec"])) encoder=\(s(r["encoder"])) decoder=\(s(r["decoder"])) " +
              "frame=\(s(r["frame_width"]))x\(s(r["frame_height"])) route=\(s(r["route"])) \(s(r["candidates"]))")
        print("  connect=\(s(r["connect_ms"]))ms first frame=\(s(r["first_frame_ms"]))ms")
        for c in r["cycles"] as? [[String: Any]] ?? [] {
            let l = c["motion_latency_ms"] as? [String: Any] ?? [:]
            let g = c["motion_gap_ms"] as? [String: Any] ?? [:]
            print("  cycle \(s(c["cycle"])): onset=\(s(c["onset_ms"]))ms wait=\(s(c["onset_wait_ms"]))ms " +
                  "lat p50/p90/p99/max=\(s(l["p50"]))/\(s(l["p90"]))/\(s(l["p99"]))/\(s(l["max"]))ms " +
                  "fps=\(s(c["motion_fps"])) " +
                  "gap p95/max=\(s(g["p95"]))/\(s(g["max"]))ms stalls=\(s(c["stalls_over_50ms"])) settle=\(s(c["settle_frames"])) " +
                  "pushed/encoded/sent/decoded=\(s(c["motion_pushed"]))/\(s(c["frames_encoded"]))/\(s(c["frames_sent"]))/\(s(c["motion_decoded"]))")
            func p(_ k: String, _ q: String) -> String { s((c[k] as? [String: Any])?[q]) }
            print("    generator: tick p50/p95=\(p("tick_ms", "p50"))/\(p("tick_ms", "p95"))ms wake late p50/max=\(p("wake_late_ms", "p50"))/\(p("wake_late_ms", "max"))ms " +
                  "render p50/max=\(p("render_ms", "p50"))/\(p("render_ms", "max"))ms barcode p50/max=\(p("barcode_ms", "p50"))/\(p("barcode_ms", "max"))ms " +
                  "push p50/max=\(p("push_ms", "p50"))/\(p("push_ms", "max"))ms record p50/max=\(p("record_ms", "p50"))/\(p("record_ms", "max"))ms")
        }
        let totals = r["totals"] as? [String: Any] ?? [:]
        print("  totals: pushes=\(s(totals["pushes"])) decodes=\(s(totals["decodes"])) repeat=\(s(totals["repeat_decodes"])) " +
              "unmatched=\(s(totals["unmatched_decodes"])) rows-disagree=\(s(totals["barcode_rows_disagree"])) " +
              "recovered-by-row1=\(s(totals["recovered_by_row1"]))")
        print("  median over cycles: onset=\(s(agg["onset_ms"]))ms wait=\(s(agg["onset_wait_ms"]))ms fps=\(s(agg["motion_fps"])) " +
              "drop=\(s(agg["motion_drop_pct"]))% settle=\(s(agg["settle_frames"]))")
        print("  burst onset (first \(max(2, opt.fps / 4)) frames, host stats): frame=\(s(agg["onset_frame_kb"]))KB " +
              "pacer=\(s(agg["onset_pacer_ms"]))ms; rest of burst: frame=\(s(agg["rest_frame_kb"]))KB pacer=\(s(agg["rest_pacer_ms"]))ms")
        print("  pooled motion latency p50/p90/p99/max=\(s(pl["p50"]))/\(s(pl["p90"]))/\(s(pl["p99"]))/\(s(pl["max"]))ms " +
              "gap p95/p99/max=\(s(pg["p95"]))/\(s(pg["p99"]))/\(s(pg["max"]))ms stalls=\(s(pooled["stalls_over_50ms"]))")
        let st = r["stats"] as? [String: Any] ?? [:]
        if let h = st["host"] as? [String: Any] {
            print("  host: rate=\(s(h["bitrate_kbps"]))kbps enc=\(s(h["encode_ms_per_frame"]))ms pacer=\(s(h["pacer_ms_per_packet"]))ms " +
                  "frame=\(s(h["avg_frame_kb"]))KB huge=\(s(h["huge_frames"])) kf=\(s(h["key_frames"])) nack=\(s(h["nack_received"])) " +
                  "pli=\(s(h["pli_received"])) limit=\(s(h["quality_limitation_end"]))")
        }
        if let c = st["client"] as? [String: Any] {
            print("  client: rate=\(s(c["bitrate_kbps"]))kbps asm=\(s(c["assembly_ms_per_frame"]))ms jb=\(s(c["jitter_buffer_ms_per_frame"]))ms " +
                  "dec=\(s(c["decode_ms_per_frame"]))ms drop=\(s(c["frames_dropped"])) lost=\(s(c["packets_lost"])) " +
                  "freezes=\(s(c["freezes"])) (\(s(c["freeze_ms"]))ms)")
        }
        if !errors.isEmpty { print("  errors: \(errors.joined(separator: "; "))") }
    }
}

// MARK: - Small helpers

/// JSON-safe number: nil / non-finite → null, otherwise rounded to 0.01.
func jn(_ v: Double?) -> Any {
    guard let v, v.isFinite else { return NSNull() }
    return (v * 100).rounded() / 100
}

func pct(_ xs: [Double], _ q: Double) -> Double? {
    guard !xs.isEmpty else { return nil }
    let s = xs.sorted()
    return s[min(s.count - 1, Int((Double(s.count - 1) * q).rounded()))]
}

func median(_ xs: [Double]) -> Double? {
    guard !xs.isEmpty else { return nil }
    let s = xs.sorted()
    return s.count % 2 == 1 ? s[s.count / 2] : (s[s.count / 2 - 1] + s[s.count / 2]) / 2
}

/// Distribution summary: n, mean, max and the requested percentiles (keys "p50", "p95"…).
func dist(_ xs: [Double], _ qs: [Double]) -> [String: Any] {
    var d: [String: Any] = ["n": xs.count, "max": jn(xs.max()), "mean": jn(xs.isEmpty ? nil : xs.reduce(0, +) / Double(xs.count))]
    for q in qs { d["p\(Int((q * 100).rounded()))"] = jn(pct(xs, q)) }
    return d
}

func sysctlString(_ name: String) -> String? {
    var size = 0
    guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
    var buf = [CChar](repeating: 0, count: size)
    guard sysctlbyname(name, &buf, &size, nil, 0) == 0 else { return nil }
    return buf.withUnsafeBufferPointer { p in p.baseAddress.map { String(cString: $0) } }
}

func orNull(_ v: Any?) -> Any { v ?? NSNull() }
