import CoreGraphics
import os
import ReachProtocol

/// The display the iPhone is looking at, readable from any thread. Written on the main thread when
/// the session picks a display or the arrangement changes; read by the input and cursor paths.
final class DisplayGeometry: @unchecked Sendable {
    struct Snapshot: Equatable {
        var displayID: DisplayID
        /// Frame in global points.
        var frame: CGRect
    }

    private let state: OSAllocatedUnfairLock<Snapshot>

    init() {
        let main = CGMainDisplayID()
        state = OSAllocatedUnfairLock(initialState: Snapshot(displayID: main, frame: CGDisplayBounds(main)))
    }

    var snapshot: Snapshot { state.withLock { $0 } }
    var frame: CGRect { state.withLock { $0.frame } }

    func update(_ snapshot: Snapshot) {
        state.withLock { $0 = snapshot }
    }
}
