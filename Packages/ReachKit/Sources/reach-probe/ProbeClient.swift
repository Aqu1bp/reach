import Foundation
import CoreImage
import CoreVideo
import ReachCore
import ReachProtocol

/// Headless iPhone stand-in: pairs, connects, measures, and optionally drives input.
final class ProbeClient {
    let engine: ClientEngine
    private var session: ClientSession?
    private let lock = NSLock()

    // Measurements (guarded by lock)
    private var t0 = Date()
    private var milestones: [(String, TimeInterval)] = []
    private var frames = 0
    private var firstFrameAt: TimeInterval?
    private var videoLatencies: [Double] = []
    private var inputLatencies: [Double] = []
    private var pointerSentAt: [UInt32: UInt64] = [:]
    private var lastSeenSeq: UInt32 = 0
    private var cursorPackets = 0
    private var lastFrame: CVPixelBuffer?
    private var frameSize = (0, 0)
    private var hostMessages: [String] = []

    init(state: URL) throws {
        let store = FileSecretStore(directory: state)
        let identity = try LocalIdentity.loadOrCreate(in: store, key: "client-identity")
        engine = ClientEngine(identity: identity, store: PairedHostStore(secrets: store), deviceName: "reach-probe",
                              deviceModel: "Probe")
    }

    func pair(_ url: String) -> Bool {
        guard let code = try? PairingCode(string: url) else { print("invalid pairing code"); return false }
        let sem = DispatchSemaphore(value: 0)
        var ok = false
        let start = Date()
        engine.pair(using: code) { result in
            switch result {
            case .success(let host):
                print("PAIRED with \(host.name) in \(String(format: "%.2f", Date().timeIntervalSince(start)))s; fingerprint \(host.fingerprint)")
                ok = true
            case .failure(let e):
                print("PAIR FAILED: \(e.localizedDescription)")
            }
            sem.signal()
        }
        waitPumpingMain(sem, timeout: 40)
        return ok
    }

    func probe() {
        guard let host = engine.store.hosts.first else { print("no paired host"); return }
        let sem = DispatchSemaphore(value: 0)
        let start = Date()
        engine.probe(host) { a in
            print("PROBE \(a) in \(String(format: "%.2f", Date().timeIntervalSince(start)))s")
            sem.signal()
        }
        waitPumpingMain(sem, timeout: 15)
    }

    struct Options {
        var seconds: Double = 10
        var policy: String?
        var snapshot: String?
        var inputTest = false
        var quality = QualityPreference()
    }

    func connect(_ opt: Options) -> Bool {
        guard let host = engine.store.hosts.first else { print("no paired host — run `pair` first"); return false }
        // Like the app, which keeps its relay connections warm, measure from a warm start.
        engine.start()
        let warm = Date().addingTimeInterval(8)
        while !engine.isRelayOnline && Date() < warm { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
        RunLoop.main.run(until: Date().addingTimeInterval(1.0))
        t0 = Date()
        let hello = ClientHello(name: "reach-probe", deviceModel: "Probe", appVersion: "probe", screenPixelWidth: 2796,
                                screenPixelHeight: 1290, quality: opt.quality)
        let s = engine.connect(to: host, hello: hello, iceTransportPolicy: opt.policy)
        session = s
        var connected = false
        var failure: String?
        s.onState = { [weak self] st in
            guard let self else { return }
            self.mark("\(st)")
            if st == .connected { connected = true }
            if case .failed(let r) = st { failure = r }
            if case .closed(let r) = st { failure = r }
        }
        s.onMessage = { [weak self] m in
            guard let self else { return }
            var d = "\(m)"
            if case .clipboard(let c) = m { d = "clipboard(\(c.text?.count ?? 0) chars)" }
            self.lock.withLock { self.hostMessages.append(String(d.prefix(140))) }
        }
        s.onCursor = { [weak self] _ in
            guard let self else { return }
            self.lock.withLock { self.cursorPackets += 1 }
        }
        s.onVideoFrame = { [weak self] buffer, _ in self?.handleFrame(buffer) }

        // Wait for connection.
        let deadline = Date().addingTimeInterval(30)
        while !connected && failure == nil && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
        guard connected else {
            print("CONNECT FAILED: \(failure ?? "timeout")")
            printMilestones()
            return false
        }
        let end = Date().addingTimeInterval(opt.seconds)
        var nextStats = Date().addingTimeInterval(1)
        var inputStarted = false
        while Date() < end && failure == nil {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
            if opt.inputTest && !inputStarted && firstFrameAt != nil {
                inputStarted = true
                runInputScript(s)
            }
            if Date() >= nextStats {
                nextStats = Date().addingTimeInterval(1)
                s.stats { [weak self] st in self?.printStats(st) }
            }
        }
        if let path = opt.snapshot { saveSnapshot(path) }
        printSummary()
        s.close()
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        return failure == nil
    }

    // MARK: Video

    private func handleFrame(_ buffer: CVPixelBuffer) {
        let now = uptimeMs()
        let ts = Barcode.read(row: 0, from: buffer)
        let seq = Barcode.read(row: 1, from: buffer).map { UInt32(truncatingIfNeeded: $0) }
        lock.withLock {
            frames += 1
            lastFrame = buffer
            frameSize = (CVPixelBufferGetWidth(buffer), CVPixelBufferGetHeight(buffer))
            if firstFrameAt == nil {
                firstFrameAt = Date().timeIntervalSince(t0)
                milestones.append(("first frame \(frameSize.0)x\(frameSize.1)", firstFrameAt!))
            }
            if let ts {
                let lat = Double(Int64(now & 0xFF_FFFF_FFFF) - Int64(ts))
                if lat >= 0 && lat < 5000 { videoLatencies.append(lat) }
            }
            if let seq, seq != lastSeenSeq, let sent = pointerSentAt[seq] {
                lastSeenSeq = seq
                inputLatencies.append(Double(now - sent))
            }
        }
    }

    // MARK: Input

    /// Drives a pointer circle, clicks, a scroll gesture and some typing.
    private func runInputScript(_ s: ClientSession) {
        let q = DispatchQueue(label: "probe.input")
        q.async {
            // 2 s of pointer motion at 60 Hz.
            for i in 0..<120 {
                let a = Double(i) / 120 * 2 * .pi
                let x = Float(0.5 + 0.2 * cos(a)), y = Float(0.5 + 0.2 * sin(a))
                let seq = s.sendPointer(x: x, y: y)
                self.lock.withLock { self.pointerSentAt[seq] = uptimeMs() }
                Thread.sleep(forTimeInterval: 1.0 / 60)
            }
            // Click at three known spots.
            for (x, y) in [(0.25, 0.3), (0.5, 0.5), (0.75, 0.7)] {
                let d = s.nextSequence()
                s.send(.mouseButton(MouseButtonEvent(seq: d, button: .left, isDown: true, x: x, y: y)))
                s.send(.mouseButton(MouseButtonEvent(seq: s.nextSequence(), button: .left, isDown: false, x: x, y: y)))
                Thread.sleep(forTimeInterval: 0.2)
            }
            s.send(.mouseButton(MouseButtonEvent(seq: s.nextSequence(), button: .right, isDown: true, x: 0.6, y: 0.4)))
            s.send(.mouseButton(MouseButtonEvent(seq: s.nextSequence(), button: .right, isDown: false, x: 0.6, y: 0.4)))
            // Scroll gesture with release velocity.
            s.send(.scroll(ScrollEvent(dx: 0, dy: -10, phase: .began)))
            for _ in 0..<10 { s.send(.scroll(ScrollEvent(dx: 0, dy: -20, phase: .changed))); Thread.sleep(forTimeInterval: 1.0 / 60) }
            s.send(.scroll(ScrollEvent(dx: 0, dy: 0, phase: .ended, velocityX: 0, velocityY: -900)))
            // Typing.
            s.send(.text(TextInput(text: "Hello from reach-probe ✓")))
            s.send(.keyPress(code: MacKey.returnKey, modifiers: []))
            s.send(.keyPress(code: MacKey.c, modifiers: .command))
            s.send(.requestApps)
            s.send(.requestWindows)
            // 1 MB clipboard — exercises fragmentation over the bulk channel — then a click that
            // must not be stuck behind it.
            s.send(.setClipboard(ClipboardContent(text: String(repeating: "0123456789abcdef", count: 65_536))))
            s.send(.mouseButton(MouseButtonEvent(seq: s.nextSequence(), button: .left, isDown: true, x: 0.9, y: 0.9)))
            s.send(.mouseButton(MouseButtonEvent(seq: s.nextSequence(), button: .left, isDown: false, x: 0.9, y: 0.9)))
        }
    }

    // MARK: Output

    private func mark(_ what: String) {
        lock.withLock { milestones.append((what, Date().timeIntervalSince(t0))) }
        print(String(format: "  +%.3fs  %@", Date().timeIntervalSince(t0), what))
    }

    private func printMilestones() {
        lock.withLock { for (m, t) in milestones { print(String(format: "  +%.3fs  %@", t, m)) } }
    }

    private func printStats(_ s: ConnectionStats?) {
        guard let s else { return }
        let f = lock.withLock { frames }
        print(String(format: "  [stats] route=%@ local=%@/%@ remote=%@ net=%@ rtt=%@ fps=%@ %@x%@ bitrate=%@kbps decode=%@ms jbuf=%@ms lost=%lld frames=%d codec=%@",
                     s.route.rawValue, s.localCandidateType ?? "-", s.transportProtocol ?? "-", s.remoteCandidateType ?? "-",
                     s.networkType ?? "-", fmt(s.roundTripMs), fmt(s.framesPerSecond), "\(s.frameWidth ?? 0)", "\(s.frameHeight ?? 0)",
                     fmt(s.bitrateKbps), fmt(s.averageDecodeMs), fmt(s.jitterBufferMs), s.packetsLost, f, s.codecImplementation ?? "-"))
    }

    private func printSummary() {
        lock.withLock {
            print("SUMMARY")
            print("  frames decoded: \(frames) (\(frameSize.0)x\(frameSize.1)); cursor packets: \(cursorPackets)")
            if let ff = firstFrameAt { print(String(format: "  time to first frame: %.3fs", ff)) }
            print("  capture→decode latency ms: \(describe(videoLatencies))")
            print("  input→video round trip ms: \(describe(inputLatencies))")
            print("  host messages received: \(hostMessages.count)")
            for m in hostMessages.prefix(12) { print("    · \(m)") }
        }
    }

    private func saveSnapshot(_ path: String) {
        guard let buf = lock.withLock({ lastFrame }) else { print("no frame to snapshot"); return }
        let ci = CIImage(cvPixelBuffer: buf)
        let ctx = CIContext()
        guard let cg = ctx.createCGImage(ci, from: ci.extent),
              let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: path) as CFURL, "public.png" as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(dest, cg, nil)
        CGImageDestinationFinalize(dest)
        print("snapshot saved to \(path)")
    }
}

func describe(_ xs: [Double]) -> String {
    guard !xs.isEmpty else { return "n/a" }
    let s = xs.sorted()
    func p(_ q: Double) -> Double { s[min(s.count - 1, Int(Double(s.count - 1) * q))] }
    return String(format: "n=%d min=%.0f p50=%.0f p90=%.0f p99=%.0f max=%.0f", s.count, s.first!, p(0.5), p(0.9), p(0.99), s.last!)
}

func fmt(_ v: Double?) -> String { v.map { String(format: "%.1f", $0) } ?? "-" }

func waitPumpingMain(_ sem: DispatchSemaphore, timeout: TimeInterval) {
    let deadline = Date().addingTimeInterval(timeout)
    while sem.wait(timeout: .now()) == .timedOut && Date() < deadline {
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
    }
}
