import Foundation
import QuartzCore
import ReachProtocol

/// The cursor position the app draws, in normalized display coordinates.
///
/// Trackpad movement is applied locally the instant a finger moves (zero network latency). The Mac's
/// reported position (`CursorPacket`, arriving on a network thread) only takes over when the user hasn't
/// moved the pointer for a moment — otherwise in-flight packets describing older positions would pull
/// the cursor backwards. That also picks up moves made on the Mac itself or by apps (warping).
///
/// Thread-safe: `hostReported` is called from the network thread, everything else from main.
final class CursorTracker: @unchecked Sendable {
    struct Snapshot: Equatable {
        var position: CGPoint
        var visible: Bool
        /// The cursor is on another display of the Mac (reported outside 0…1).
        var offDisplay: Bool
    }

    /// Called after every change, on the thread that made it.
    var onChange: ((Snapshot) -> Void)? {
        get { lock.withLock { _onChange } }
        set { lock.withLock { _onChange = newValue } }
    }

    /// Called on the network thread when the Mac moved the cursor somewhere we didn't predict.
    var onHostMove: ((CGPoint) -> Void)? {
        get { lock.withLock { _onHostMove } }
        set { lock.withLock { _onHostMove = newValue } }
    }

    private let lock = NSLock()
    private var _onChange: ((Snapshot) -> Void)?
    private var _onHostMove: ((CGPoint) -> Void)?
    private var state = Snapshot(position: CGPoint(x: 0.5, y: 0.5), visible: true, offDisplay: false)
    private var lastLocalMove: CFTimeInterval = 0
    private var lastHostSeq: UInt32?
    private var hasHostPosition = false

    /// How long after the last local move the Mac's reports are ignored.
    static let reconcileDelay: CFTimeInterval = 0.4

    var snapshot: Snapshot { lock.withLock { state } }
    var position: CGPoint { lock.withLock { state.position } }

    /// A move made on the phone (trackpad delta or touch location). Clamped to the display.
    func moveLocally(to p: CGPoint) {
        let clamped = CGPoint(x: min(max(p.x, 0), 1), y: min(max(p.y, 0), 1))
        let (snap, cb) = lock.withLock { () -> (Snapshot, ((Snapshot) -> Void)?) in
            state.position = clamped
            state.offDisplay = false
            state.visible = true
            lastLocalMove = CACurrentMediaTime()
            return (state, _onChange)
        }
        cb?(snap)
    }

    /// Keeps the local prediction authoritative for a little longer (e.g. while a button is held).
    func holdPrediction() {
        lock.withLock { lastLocalMove = CACurrentMediaTime() }
    }

    func hostReported(_ packet: CursorPacket) {
        let result = lock.withLock { () -> (Snapshot, ((Snapshot) -> Void)?, ((CGPoint) -> Void)?, Bool)? in
            if let last = lastHostSeq, !seqIsNewer(packet.seq, than: last) { return nil }
            lastHostSeq = packet.seq
            let p = CGPoint(x: CGFloat(packet.x), y: CGFloat(packet.y))
            guard p.x.isFinite, p.y.isFinite else { return nil }
            let off = p.x < 0 || p.x > 1 || p.y < 0 || p.y > 1
            var changed = state.visible != packet.visible
            state.visible = packet.visible
            var jumped = false
            let idle = CACurrentMediaTime() - lastLocalMove > Self.reconcileDelay
            if idle || !hasHostPosition {
                let moved = abs(state.position.x - p.x) > 0.0001 || abs(state.position.y - p.y) > 0.0001
                if moved || state.offDisplay != off {
                    jumped = moved
                    state.position = off ? CGPoint(x: min(max(p.x, 0), 1), y: min(max(p.y, 0), 1)) : p
                    state.offDisplay = off
                    changed = true
                }
            }
            hasHostPosition = true
            return changed ? (state, _onChange, _onHostMove, jumped) : nil
        }
        guard let (snap, onChange, onHostMove, jumped) = result else { return }
        onChange?(snap)
        if jumped, !snap.offDisplay { onHostMove?(snap.position) }
    }

    func reset() {
        lock.withLock {
            lastHostSeq = nil
            hasHostPosition = false
        }
    }
}
