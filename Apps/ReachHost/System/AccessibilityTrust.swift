import ApplicationServices
import os

/// Thread-safe, cached answer to "may this process post events / use Accessibility?".
///
/// The input path asks on every event, so the TCC query is made at most once a second while
/// untrusted (to notice a fresh grant quickly) and every five seconds while trusted (to notice a
/// revocation).
final class AccessibilityTrust: @unchecked Sendable {
    private struct State {
        var trusted: Bool
        var checkedAt: TimeInterval
    }

    private let state: OSAllocatedUnfairLock<State>

    init() {
        state = OSAllocatedUnfairLock(initialState: State(trusted: AXIsProcessTrusted(), checkedAt: uptimeSeconds()))
    }

    var isTrusted: Bool {
        let now = uptimeSeconds()
        let cached = state.withLock { $0 }
        let maxAge: TimeInterval = cached.trusted ? 5 : 1
        guard now - cached.checkedAt > maxAge else { return cached.trusted }
        let fresh = AXIsProcessTrusted()
        state.withLock { $0 = State(trusted: fresh, checkedAt: now) }
        return fresh
    }

    func record(_ trusted: Bool) {
        state.withLock { $0 = State(trusted: trusted, checkedAt: uptimeSeconds()) }
    }
}
