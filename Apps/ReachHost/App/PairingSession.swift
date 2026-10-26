import AppKit
import Observation
import ReachCore

/// The pairing code currently on screen. Shared by the pairing window and onboarding: each holds it
/// while visible, and the code is withdrawn from the engine once nobody is showing it.
@MainActor
@Observable
final class PairingSession {
    enum State: Equatable {
        case idle
        case showing(Code)
        case paired(deviceName: String)
    }

    struct Code: Equatable {
        var link: String
        var expiresAt: Date
        var qr: CGImage

        static func == (lhs: Code, rhs: Code) -> Bool { lhs.link == rhs.link && lhs.expiresAt == rhs.expiresAt }
    }

    struct Backend {
        var makeCode: () -> PairingCode
        var cancel: () -> Void
    }

    private(set) var state: State = .idle

    @ObservationIgnored private let backend: Backend?
    @ObservationIgnored private var holders: Set<Holder> = []
    @ObservationIgnored private var refreshTimer: Timer?

    /// Codes are valid for ten minutes in `HostEngine`; refresh a little early so a code that's
    /// being scanned right at the end still works.
    static let lifetime: TimeInterval = 600
    private static let refreshMargin: TimeInterval = 5

    init(backend: Backend) {
        self.backend = backend
    }

    /// A fixed state for UI snapshots.
    init(previewState: State) {
        backend = nil
        state = previewState
    }

    /// Who is showing the code. Holding is idempotent per holder, so repeated appear/close
    /// callbacks can't unbalance it.
    enum Holder: Hashable {
        case pairingWindow
        case onboarding
    }

    func setVisible(_ visible: Bool, for holder: Holder) {
        if visible {
            let wasEmpty = holders.isEmpty
            guard holders.insert(holder).inserted else { return }
            // A newly shown pairing UI always wants a live code (not a previous success state).
            if case .showing = state, !wasEmpty { return }
            refresh()
        } else {
            guard holders.remove(holder) != nil, holders.isEmpty, backend != nil else { return }
            refreshTimer?.invalidate()
            refreshTimer = nil
            if case .showing = state { backend?.cancel() }
            state = .idle
        }
    }

    /// Replaces the code with a new one (also invalidating the old one).
    func refresh() {
        guard let backend else { return }
        let code = backend.makeCode()
        let link = code.url.absoluteString
        guard let qr = QRCodeRenderer.image(for: link) else {
            ReachLog.error("host", "couldn't render the pairing QR code")
            return
        }
        let expiresAt = Date().addingTimeInterval(Self.lifetime)
        state = .showing(Code(link: link, expiresAt: expiresAt, qr: qr))
        scheduleRefresh(at: expiresAt.addingTimeInterval(-Self.refreshMargin))
    }

    func didPair(deviceName: String) {
        guard !holders.isEmpty else { return }
        refreshTimer?.invalidate()
        refreshTimer = nil
        state = .paired(deviceName: deviceName)
    }

    private func scheduleRefresh(at date: Date) {
        refreshTimer?.invalidate()
        let timer = Timer(fire: date, interval: 0, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        RunLoop.main.add(timer, forMode: .common)
        refreshTimer = timer
    }
}
