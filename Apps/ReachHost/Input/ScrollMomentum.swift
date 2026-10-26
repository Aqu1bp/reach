import Foundation

/// Host-side scroll momentum after the fingers lift, decaying exponentially like a trackpad flick.
///
/// Generating momentum on the Mac (rather than streaming it from the iPhone) makes it immune to
/// network jitter. The curve is a closed-form function of elapsed time, so a late timer tick only
/// changes how the distance is sliced into events, never the total distance or the duration.
struct ScrollMomentum: Equatable {
    /// Fraction of velocity kept per millisecond. 0.998 is UIKit's `.normal` deceleration rate, which
    /// is also very close to how far and how long a macOS trackpad flick coasts.
    static let retentionPerMillisecond = 0.998
    /// Releases slower than this just stop, as they do on a real trackpad.
    static let minimumStartSpeed = 60.0 // pt/s
    /// Coasting ends once the speed drops below this (≈ 0.08 pt per 120 Hz tick — imperceptible).
    static let stopSpeed = 10.0 // pt/s
    static let maximumSpeed = 9_000.0 // pt/s
    static let maximumDuration: TimeInterval = 4

    /// Natural-log decay rate per second (negative).
    static let decayRate = 1000 * log(retentionPerMillisecond)

    let velocityX: Double
    let velocityY: Double
    /// Seconds from release until coasting stops.
    let duration: TimeInterval

    /// `nil` when the release is too slow to coast.
    init?(velocityX: Double, velocityY: Double) {
        guard velocityX.isFinite, velocityY.isFinite else { return nil }
        let speed = hypot(velocityX, velocityY)
        guard speed >= Self.minimumStartSpeed else { return nil }
        let limit = min(1, Self.maximumSpeed / speed)
        self.velocityX = velocityX * limit
        self.velocityY = velocityY * limit
        duration = min(Self.maximumDuration, log(Self.stopSpeed / (speed * limit)) / Self.decayRate)
    }

    /// Distance travelled `t` seconds after release.
    func offset(at t: TimeInterval) -> (dx: Double, dy: Double) {
        let clamped = min(max(0, t), duration)
        let factor = (exp(Self.decayRate * clamped) - 1) / Self.decayRate
        return (velocityX * factor, velocityY * factor)
    }

    func speed(at t: TimeInterval) -> Double {
        hypot(velocityX, velocityY) * exp(Self.decayRate * min(max(0, t), duration))
    }

    func isFinished(at t: TimeInterval) -> Bool { t >= duration }

    var totalDistance: (dx: Double, dy: Double) { offset(at: duration) }
}

/// Turns fractional point deltas into the whole-pixel deltas a scroll `CGEvent` carries, carrying the
/// remainder forward so slow scrolls still move and nothing drifts over a long gesture.
struct ScrollAccumulator: Equatable {
    private var remainderX = 0.0
    private var remainderY = 0.0

    mutating func reset() {
        remainderX = 0
        remainderY = 0
    }

    mutating func take(dx: Double, dy: Double) -> (dx: Int32, dy: Int32) {
        if dx.isFinite { remainderX += dx }
        if dy.isFinite { remainderY += dy }
        // Deltas come off the network: clamp before converting, since Int(Double) traps out of range.
        let wholeX = Self.clamped(remainderX.rounded())
        let wholeY = Self.clamped(remainderY.rounded())
        remainderX = Self.clamped(remainderX - wholeX)
        remainderY = Self.clamped(remainderY - wholeY)
        return (Int32(wholeX), Int32(wholeY))
    }

    private static let limit = 100_000.0

    private static func clamped(_ value: Double) -> Double {
        min(max(value, -limit), limit)
    }
}
