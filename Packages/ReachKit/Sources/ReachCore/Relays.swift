import Foundation

/// A public message relay used only for signaling (pairing and connection setup — a few small
/// encrypted messages per connection). Video and input never touch a relay; they flow peer-to-peer.
public enum RelayStatus: Equatable, Sendable {
    case connecting
    case online
    case offline(String)

    public var isOnline: Bool { self == .online }
}

public struct RelayEndpoint: Codable, Hashable, Sendable {
    /// `local` is an in-process loopback (e.g. `local://bench`) for tests and benchmarks that run a
    /// host and a client in one process: no network, deterministic, works offline.
    public enum Kind: String, Codable, Sendable { case ntfy, mqtt, local }
    public var kind: Kind
    public var url: URL

    public init(kind: Kind, url: URL) {
        self.kind = kind; self.url = url
    }

    /// Two independent public services, used simultaneously for redundancy. Either one is enough.
    public static let defaults: [RelayEndpoint] = [
        RelayEndpoint(kind: .ntfy, url: URL(string: "https://ntfy.sh")!),
        RelayEndpoint(kind: .mqtt, url: URL(string: "wss://broker.hivemq.com:8884/mqtt")!),
    ]

    func makeTransport() -> RelayTransport {
        switch kind {
        case .ntfy: return NtfyRelay(baseURL: url)
        case .mqtt: return MQTTRelay(url: url)
        case .local: return LocalRelay(url: url)
        }
    }

    /// An in-process loopback relay. Endpoints with the same URL share one namespace.
    public static func local(_ name: String = "bench") -> RelayEndpoint {
        RelayEndpoint(kind: .local, url: URL(string: "local://\(name)")!)
    }
}

/// Largest relay frame (WebSocket message or MQTT packet) a transport accepts: an envelope plus
/// the relay's own framing. Bigger ones mean a misbehaving relay; the connection is dropped.
let maxRelayFrameBytes = EnvelopeCrypto.maxEnvelopeBytes + 16 * 1024

protocol RelayTransport: AnyObject {
    var name: String { get }
    var onMessage: ((Data) -> Void)? { get set }
    var onStatus: ((RelayStatus) -> Void)? { get set }
    func start(mailbox: String)
    func stop()
    func publish(_ payload: Data, to mailbox: String, completion: @escaping (Error?) -> Void)
}

/// Exponential backoff with jitter for reconnects.
struct Backoff {
    private(set) var attempt = 0
    mutating func next() -> TimeInterval {
        attempt += 1
        let base = min(30.0, 0.5 * pow(2.0, Double(min(attempt, 6))))
        return base * Double.random(in: 0.7...1.3)
    }
    mutating func reset() { attempt = 0 }
}

// MARK: - ntfy.sh

/// ntfy (https://ntfy.sh): HTTP publish, WebSocket subscribe. No account required.
final class NtfyRelay: NSObject, RelayTransport, URLSessionWebSocketDelegate, @unchecked Sendable {
    let name: String
    var onMessage: ((Data) -> Void)?
    var onStatus: ((RelayStatus) -> Void)?

    private let baseURL: URL
    private let queue = DispatchQueue(label: "reach.relay.ntfy")
    private var session: URLSession!
    private var task: URLSessionWebSocketTask?
    private var mailbox: String?
    private var running = false
    private var backoff = Backoff()
    private var generation = 0
    private var watchdog: DispatchSourceTimer?
    private var lastTraffic = Date()

    init(baseURL: URL) {
        self.baseURL = baseURL
        self.name = "ntfy(\(baseURL.host ?? "?"))"
        super.init()
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 15
        cfg.waitsForConnectivity = false
        session = URLSession(configuration: cfg, delegate: self, delegateQueue: nil)
    }

    func start(mailbox: String) {
        queue.async {
            self.mailbox = mailbox
            self.running = true
            self.connect()
            self.startWatchdog()
        }
    }

    func stop() {
        queue.async {
            self.running = false
            self.watchdog?.cancel(); self.watchdog = nil
            self.task?.cancel(with: .goingAway, reason: nil)
            self.task = nil
        }
    }

    private func connect() {
        guard running, let mailbox else { return }
        generation += 1
        let gen = generation
        var comps = URLComponents(url: baseURL.appendingPathComponent(mailbox).appendingPathComponent("ws"),
                                  resolvingAgainstBaseURL: false)!
        comps.scheme = baseURL.scheme == "http" ? "ws" : "wss"
        onStatus?(.connecting)
        let t = session.webSocketTask(with: comps.url!)
        t.maximumMessageSize = maxRelayFrameBytes
        task = t
        lastTraffic = Date()
        t.resume()
        receive(t, gen: gen)
    }

    private func receive(_ t: URLSessionWebSocketTask, gen: Int) {
        t.receive { [weak self] result in
            guard let self else { return }
            self.queue.async {
                guard gen == self.generation else { return }
                switch result {
                case .success(let msg):
                    self.lastTraffic = Date()
                    var text: String?
                    switch msg {
                    case .string(let s): text = s
                    case .data(let d): text = String(data: d, encoding: .utf8)
                    @unknown default: break
                    }
                    if let text { self.handle(text) }
                    self.receive(t, gen: gen)
                case .failure(let err):
                    self.scheduleReconnect(reason: err.localizedDescription)
                }
            }
        }
    }

    private func handle(_ text: String) {
        guard let data = text.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let event = obj["event"] as? String else { return }
        switch event {
        case "open":
            backoff.reset()
            onStatus?(.online)
        case "message":
            if let m = obj["message"] as? String, let payload = m.data(using: .utf8) {
                onMessage?(payload)
            }
        default:
            break // keepalive
        }
    }

    private func scheduleReconnect(reason: String) {
        guard running else { return }
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        generation += 1
        onStatus?(.offline(reason))
        let delay = backoff.next()
        ReachLog.debug("relay", "\(name) reconnecting in \(String(format: "%.1f", delay))s: \(reason)")
        queue.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, self.running, self.task == nil else { return }
            self.connect()
        }
    }

    /// ntfy sends keepalives every ~45 s; if we hear nothing for 100 s the socket is dead.
    private func startWatchdog() {
        watchdog?.cancel()
        let w = DispatchSource.makeTimerSource(queue: queue)
        w.schedule(deadline: .now() + 20, repeating: 20)
        w.setEventHandler { [weak self] in
            guard let self, self.running, self.task != nil else { return }
            if Date().timeIntervalSince(self.lastTraffic) > 100 {
                self.scheduleReconnect(reason: "keepalive timeout")
            }
        }
        w.resume()
        watchdog = w
    }

    func publish(_ payload: Data, to mailbox: String, completion: @escaping (Error?) -> Void) {
        var req = URLRequest(url: baseURL.appendingPathComponent(mailbox))
        req.httpMethod = "POST"
        req.httpBody = payload
        req.setValue("no", forHTTPHeaderField: "X-Cache")      // don't store on the server
        req.setValue("no", forHTTPHeaderField: "X-Firebase")   // don't forward to Firebase
        req.timeoutInterval = 10
        session.dataTask(with: req) { _, resp, err in
            if let err { completion(err); return }
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            completion(code == 200 ? nil : ReachError.timeout("ntfy publish failed (HTTP \(code))"))
        }.resume()
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        queue.async {
            guard webSocketTask === self.task else { return }
            self.scheduleReconnect(reason: "closed (\(closeCode.rawValue))")
        }
    }
}

// MARK: - MQTT over WebSocket

/// Minimal MQTT 3.1.1 client (QoS 0 only) over a WebSocket, enough to use a public broker as a
/// mailbox relay.
final class MQTTRelay: NSObject, RelayTransport, URLSessionWebSocketDelegate, @unchecked Sendable {
    let name: String
    var onMessage: ((Data) -> Void)?
    var onStatus: ((RelayStatus) -> Void)?

    private let url: URL
    private let queue = DispatchQueue(label: "reach.relay.mqtt")
    private var session: URLSession!
    private var task: URLSessionWebSocketTask?
    private var mailbox: String?
    private var running = false
    private var connected = false
    private var backoff = Backoff()
    private var generation = 0
    private var buffer = Data()
    private var pingTimer: DispatchSourceTimer?
    private var lastTraffic = Date()
    private var pending: [(id: Int, packet: Data, completion: (Error?) -> Void)] = []
    private var nextPendingID = 0
    private var packetID: UInt16 = 1
    private static let keepAlive: UInt16 = 30

    init(url: URL) {
        self.url = url
        self.name = "mqtt(\(url.host ?? "?"))"
        super.init()
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 15
        session = URLSession(configuration: cfg, delegate: self, delegateQueue: nil)
    }

    static func topic(for mailbox: String) -> String { "reach/v1/\(mailbox)" }

    func start(mailbox: String) {
        queue.async {
            self.mailbox = mailbox
            self.running = true
            self.connect()
        }
    }

    func stop() {
        queue.async {
            self.running = false
            self.pingTimer?.cancel(); self.pingTimer = nil
            if self.connected { self.send(Data([0xE0, 0x00])) }
            self.task?.cancel(with: .goingAway, reason: nil)
            self.task = nil
            self.connected = false
            self.failPending(ReachError.closed)
        }
    }

    /// Publishing without a subscription still needs a live connection, so `connect()` also runs
    /// for publish-only use (mailbox == nil).
    private func connect() {
        generation += 1
        let gen = generation
        connected = false
        buffer = Data()
        onStatus?(.connecting)
        var req = URLRequest(url: url)
        req.setValue("mqtt", forHTTPHeaderField: "Sec-WebSocket-Protocol")
        let t = session.webSocketTask(with: req)
        t.maximumMessageSize = maxRelayFrameBytes
        task = t
        lastTraffic = Date()
        t.resume()
        receive(t, gen: gen)
        send(connectPacket())
        startPinger()
    }

    private func receive(_ t: URLSessionWebSocketTask, gen: Int) {
        t.receive { [weak self] result in
            guard let self else { return }
            self.queue.async {
                guard gen == self.generation else { return }
                switch result {
                case .success(let msg):
                    self.lastTraffic = Date()
                    if case .data(let d) = msg { self.buffer.append(d); self.parse() }
                    self.receive(t, gen: gen)
                case .failure(let err):
                    self.scheduleReconnect(reason: err.localizedDescription)
                }
            }
        }
    }

    private func parse() {
        while true {
            guard buffer.count >= 2 else { return }
            let bytes = [UInt8](buffer)
            var multiplier = 1, length = 0, idx = 1
            while true {
                guard idx < bytes.count else { return }
                let b = Int(bytes[idx]); idx += 1
                length += (b & 0x7F) * multiplier
                multiplier *= 128
                if b & 0x80 == 0 { break }
                if multiplier > 128 * 128 * 128 { scheduleReconnect(reason: "bad length"); return }
            }
            guard length <= maxRelayFrameBytes else { scheduleReconnect(reason: "oversized packet"); return }
            guard bytes.count >= idx + length else { return }
            let type = bytes[0] >> 4
            let body = Data(bytes[idx..<(idx + length)])
            buffer = Data(bytes[(idx + length)...])
            handlePacket(type: type, flags: bytes[0] & 0x0F, body: body)
        }
    }

    private func handlePacket(type: UInt8, flags: UInt8, body: Data) {
        switch type {
        case 2: // CONNACK
            let rc = body.count >= 2 ? body[body.startIndex + 1] : 0xFF
            guard rc == 0 else { scheduleReconnect(reason: "CONNACK rc=\(rc)"); return }
            connected = true
            backoff.reset()
            if let mailbox { send(subscribePacket(topic: Self.topic(for: mailbox))) } else { onStatus?(.online) }
            flushPending()
        case 9: // SUBACK
            onStatus?(.online)
        case 3: // PUBLISH
            let b = [UInt8](body)
            guard b.count >= 2 else { return }
            let tlen = Int(b[0]) << 8 | Int(b[1])
            var start = 2 + tlen
            if (flags >> 1) & 0x3 > 0 { start += 2 } // packet id for QoS > 0
            guard start <= b.count else { return }
            onMessage?(Data(b[start...]))
        default:
            break // PINGRESP etc.
        }
    }

    private func scheduleReconnect(reason: String) {
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        connected = false
        generation += 1
        pingTimer?.cancel(); pingTimer = nil
        guard running else { failPending(ReachError.relayUnavailable); return }
        onStatus?(.offline(reason))
        let delay = backoff.next()
        ReachLog.debug("relay", "\(name) reconnecting in \(String(format: "%.1f", delay))s: \(reason)")
        queue.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, self.running, self.task == nil else { return }
            self.connect()
        }
    }

    private func startPinger() {
        pingTimer?.cancel()
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 20, repeating: 20)
        t.setEventHandler { [weak self] in
            guard let self, self.task != nil else { return }
            if Date().timeIntervalSince(self.lastTraffic) > Double(Self.keepAlive) * 2 {
                self.scheduleReconnect(reason: "keepalive timeout")
                return
            }
            if self.connected { self.send(Data([0xC0, 0x00])) }
        }
        t.resume()
        pingTimer = t
    }

    func publish(_ payload: Data, to mailbox: String, completion: @escaping (Error?) -> Void) {
        queue.async {
            let packet = self.publishPacket(topic: Self.topic(for: mailbox), payload: payload)
            if self.connected {
                self.send(packet, completion: completion)
            } else {
                self.nextPendingID += 1
                let id = self.nextPendingID
                self.pending.append((id, packet, completion))
                if !self.running {
                    // Publish-only usage: open a connection on demand.
                    self.running = true
                    self.connect()
                }
                self.queue.asyncAfter(deadline: .now() + 10) {
                    guard let i = self.pending.firstIndex(where: { $0.id == id }) else { return }
                    self.pending.remove(at: i).completion(ReachError.relayUnavailable)
                }
            }
        }
    }

    private func flushPending() {
        let items = pending
        pending.removeAll()
        for item in items { send(item.packet, completion: item.completion) }
    }

    private func failPending(_ error: Error) {
        let items = pending
        pending.removeAll()
        for item in items { item.completion(error) }
    }

    private func send(_ packet: Data, completion: ((Error?) -> Void)? = nil) {
        guard let task else { completion?(ReachError.relayUnavailable); return }
        task.send(.data(packet)) { err in completion?(err) }
    }

    // MARK: Packet encoding

    private func connectPacket() -> Data {
        var vh = Data()
        vh.append(mqttString("MQTT"))
        vh.append(4)          // protocol level 3.1.1
        vh.append(0x02)       // clean session
        vh.append(UInt8(Self.keepAlive >> 8)); vh.append(UInt8(Self.keepAlive & 0xFF))
        vh.append(mqttString("reach-" + randomHex(bytes: 8)))
        return frame(0x10, vh)
    }

    private func subscribePacket(topic: String) -> Data {
        var body = Data()
        packetID = packetID &+ 1
        body.append(UInt8(packetID >> 8)); body.append(UInt8(packetID & 0xFF))
        body.append(mqttString(topic))
        body.append(0) // QoS 0
        return frame(0x82, body)
    }

    private func publishPacket(topic: String, payload: Data) -> Data {
        var body = mqttString(topic)
        body.append(payload)
        return frame(0x30, body)
    }

    private func mqttString(_ s: String) -> Data {
        let u = Data(s.utf8)
        var d = Data([UInt8(u.count >> 8), UInt8(u.count & 0xFF)])
        d.append(u)
        return d
    }

    private func frame(_ header: UInt8, _ body: Data) -> Data {
        var d = Data([header])
        var len = body.count
        repeat {
            var byte = UInt8(len % 128)
            len /= 128
            if len > 0 { byte |= 0x80 }
            d.append(byte)
        } while len > 0
        d.append(body)
        return d
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        queue.async {
            guard webSocketTask === self.task else { return }
            self.scheduleReconnect(reason: "closed (\(closeCode.rawValue))")
        }
    }
}

// MARK: - In-process loopback

/// Delivers envelopes between engines in the same process through a process-wide registry, keyed by
/// relay namespace (the endpoint URL) and mailbox. Used by `reach-probe bench` so a host and a client
/// can signal without any public relay. Delivery is asynchronous, on a private serial queue, like a
/// real relay.
final class LocalRelay: RelayTransport, @unchecked Sendable {
    let name: String
    private let namespace: String
    private let lock = NSLock()
    private var _onMessage: ((Data) -> Void)?
    private var _onStatus: ((RelayStatus) -> Void)?
    private var mailbox: String?

    var onMessage: ((Data) -> Void)? {
        get { lock.withLock { _onMessage } }
        set { lock.withLock { _onMessage = newValue } }
    }
    var onStatus: ((RelayStatus) -> Void)? {
        get { lock.withLock { _onStatus } }
        set { lock.withLock { _onStatus = newValue } }
    }

    init(url: URL) {
        namespace = url.absoluteString
        name = "local(\(url.host ?? url.absoluteString))"
    }

    func start(mailbox: String) {
        lock.withLock { self.mailbox = mailbox }
        LocalRelayRegistry.shared.register(self, namespace: namespace, mailbox: mailbox)
        LocalRelayRegistry.shared.queue.async { [weak self] in self?.onStatus?(.online) }
    }

    func stop() {
        let box: String? = lock.withLock { let b = self.mailbox; self.mailbox = nil; return b }
        if let box { LocalRelayRegistry.shared.unregister(self, namespace: namespace, mailbox: box) }
    }

    func publish(_ payload: Data, to mailbox: String, completion: @escaping (Error?) -> Void) {
        let targets = LocalRelayRegistry.shared.transports(namespace: namespace, mailbox: mailbox)
        LocalRelayRegistry.shared.queue.async {
            for t in targets { t.onMessage?(payload) }
            completion(nil)
        }
    }
}

final class LocalRelayRegistry: @unchecked Sendable {
    static let shared = LocalRelayRegistry()
    let queue = DispatchQueue(label: "reach.relay.local")
    private let lock = NSLock()
    private var boxes: [String: [WeakTransport]] = [:]

    private struct WeakTransport { weak var transport: LocalRelay? }

    private func key(_ namespace: String, _ mailbox: String) -> String { namespace + "|" + mailbox }

    func register(_ t: LocalRelay, namespace: String, mailbox: String) {
        let k = key(namespace, mailbox)
        lock.withLock {
            var list = (boxes[k] ?? []).filter { $0.transport != nil && $0.transport !== t }
            list.append(WeakTransport(transport: t))
            boxes[k] = list
        }
    }

    func unregister(_ t: LocalRelay, namespace: String, mailbox: String) {
        let k = key(namespace, mailbox)
        lock.withLock {
            boxes[k] = (boxes[k] ?? []).filter { $0.transport != nil && $0.transport !== t }
        }
    }

    func transports(namespace: String, mailbox: String) -> [LocalRelay] {
        let k = key(namespace, mailbox)
        return lock.withLock { (boxes[k] ?? []).compactMap { $0.transport } }
    }
}
