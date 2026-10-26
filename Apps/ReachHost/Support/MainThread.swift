import Foundation

/// Runs `body` on the main actor after the current main-queue work, preserving FIFO order with other
/// main-queue blocks (unlike `Task { @MainActor in }`, which may reorder).
func onMain(_ body: @escaping @MainActor () -> Void) {
    DispatchQueue.main.async { MainActor.assumeIsolated(body) }
}

/// Runs `body` on the main actor, synchronously when already on the main thread.
func onMainNowOrAsync(_ body: @escaping @MainActor () -> Void) {
    if Thread.isMainThread {
        MainActor.assumeIsolated(body)
    } else {
        onMain(body)
    }
}

/// Monotonic seconds, for measuring intervals.
@inline(__always)
func uptimeSeconds() -> TimeInterval {
    ProcessInfo.processInfo.systemUptime
}
