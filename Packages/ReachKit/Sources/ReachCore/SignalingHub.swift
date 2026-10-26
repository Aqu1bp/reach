import Foundation

/// Publishes every signaling envelope through all configured relays at once and merges what comes
/// back, so a single relay outage (or a slow one) never blocks a connection.
final class SignalingHub: @unchecked Sendable {
    private let transports: [RelayTransport]
    private let queue: DispatchQueue
    private let ownMailbox: String
    private var statuses: [String: RelayStatus] = [:]
    private var seenNonces: [String: Date] = [:]

    /// Called on `queue` with each unique envelope.
    var onEnvelope: ((Envelope) -> Void)?
    /// Called on `queue` whenever the aggregate status changes.
    var onStatus: ((_ online: Bool, _ detail: [String: RelayStatus]) -> Void)?

    init(ownID: String, relays: [RelayEndpoint], queue: DispatchQueue) {
        self.queue = queue
        self.ownMailbox = mailbox(for: ownID)
        self.transports = relays.map { $0.makeTransport() }
        for t in transports {
            statuses[t.name] = .connecting
            t.onStatus = { [weak self, name = t.name] status in
                self?.queue.async { self?.update(name, status) }
            }
            t.onMessage = { [weak self, name = t.name] data in
                self?.queue.async { self?.receive(data, via: name) }
            }
        }
    }

    var isOnline: Bool { statuses.values.contains(.online) }
    var detail: [String: RelayStatus] { statuses }

    func start() {
        transports.forEach { $0.start(mailbox: ownMailbox) }
    }

    func stop() {
        transports.forEach { $0.stop() }
    }

    /// Publish to every relay. `completion(true)` as soon as one accepts.
    func send(_ data: Data, toPeer peerID: String, completion: ((Bool) -> Void)? = nil) {
        let box = mailbox(for: peerID)
        let group = DispatchGroup()
        let lock = NSLock()
        var anySuccess = false
        var reported = false
        for t in transports {
            group.enter()
            t.publish(data, to: box) { [queue] err in
                lock.lock()
                if err == nil {
                    anySuccess = true
                    if !reported { reported = true; lock.unlock(); queue.async { completion?(true) }; group.leave(); return }
                } else {
                    ReachLog.debug("relay", "\(t.name) publish failed: \(err!.localizedDescription)")
                }
                lock.unlock()
                group.leave()
            }
        }
        group.notify(queue: queue) {
            lock.lock(); defer { lock.unlock() }
            if !anySuccess && !reported { reported = true; completion?(false) }
        }
    }

    private func update(_ name: String, _ status: RelayStatus) {
        let wasOnline = isOnline
        let previous = statuses[name]
        statuses[name] = status
        if previous != status { ReachLog.info("relay", "\(name): \(status)") }
        if wasOnline != isOnline || previous != status { onStatus?(isOnline, statuses) }
    }

    private func receive(_ data: Data, via relay: String) {
        guard let env = EnvelopeCrypto.peek(data) else { return }
        let now = Date()
        if seenNonces.count > 1024 {
            seenNonces = seenNonces.filter { now.timeIntervalSince($0.value) < 600 }
            // Anyone can post to a mailbox, so this isn't authenticated traffic: past the cap, forget
            // everything (a late duplicate then reaches the replay filter, which drops it).
            if seenNonces.count > 1024 { seenNonces.removeAll() }
        }
        if let first = seenNonces[env.n] {
            // Same message via another relay.
            ReachLog.debug("relay", "duplicate via \(relay) +\(Int(now.timeIntervalSince(first) * 1000))ms")
            return
        }
        ReachLog.debug("relay", "message from \(env.f.prefix(6)) first via \(relay)")
        seenNonces[env.n] = now
        onEnvelope?(env)
    }
}
