import IOKit.pwr_mgt
import os
import ReachCore

/// Power assertions for remote access. Thread-safe (the input path wakes the display).
///
/// * "Keep Mac awake" holds `PreventUserIdleSystemSleep` for as long as the app runs, so the Mac stays
///   reachable; the display may still sleep and the screen still locks per the user's settings.
/// * During a session the display is woken and `PreventUserIdleDisplaySleep` is held, so the iPhone
///   never stares at a black screen.
final class PowerManager: @unchecked Sendable {
    private struct Assertions {
        var systemSleep: IOPMAssertionID = 0
        var displaySleep: IOPMAssertionID = 0
        var userActivity: IOPMAssertionID = 0
    }

    private let assertions = OSAllocatedUnfairLock(initialState: Assertions())

    func setKeepAwake(_ enabled: Bool) {
        assertions.withLock { a in
            if enabled {
                guard a.systemSleep == 0 else { return }
                a.systemSleep = Self.create(kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
                                            reason: "Reach Host keeps this Mac reachable from your iPhone")
            } else if a.systemSleep != 0 {
                IOPMAssertionRelease(a.systemSleep)
                a.systemSleep = 0
            }
        }
    }

    func beginSession() {
        wakeDisplay()
        assertions.withLock { a in
            guard a.displaySleep == 0 else { return }
            a.displaySleep = Self.create(kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
                                         reason: "Reach Host is showing this screen on your iPhone")
        }
    }

    func endSession() {
        assertions.withLock { a in
            if a.displaySleep != 0 {
                IOPMAssertionRelease(a.displaySleep)
                a.displaySleep = 0
            }
        }
    }

    /// Turns the display on (and postpones display sleep) as if someone touched the Mac.
    func wakeDisplay() {
        assertions.withLock { a in
            // "Local" because the screen must actually light up for capture; a remote-user declaration
            // may leave it off.
            let result = IOPMAssertionDeclareUserActivity("Reach Host: iPhone activity" as CFString, kIOPMUserActiveLocal, &a.userActivity)
            if result != kIOReturnSuccess { ReachLog.error("host", "declare user activity failed: \(result)") }
        }
    }

    func releaseAll() {
        assertions.withLock { a in
            for id in [a.systemSleep, a.displaySleep, a.userActivity] where id != 0 { IOPMAssertionRelease(id) }
            a = Assertions()
        }
    }

    private static func create(_ type: CFString, reason: String) -> IOPMAssertionID {
        var id: IOPMAssertionID = 0
        let result = IOPMAssertionCreateWithName(type, IOPMAssertionLevel(kIOPMAssertionLevelOn), reason as CFString, &id)
        if result != kIOReturnSuccess {
            ReachLog.error("host", "power assertion \(type) failed: \(result)")
            return 0
        }
        return id
    }
}
