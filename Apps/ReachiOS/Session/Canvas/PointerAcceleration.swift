import CoreGraphics
import Foundation

/// Trackpad-mode pointer ballistics.
///
/// Slow, deliberate finger movement maps to less than 1:1 for precision (hitting a 16-point close
/// button); fast flicks cover the whole display without lifting the finger repeatedly. The curve is a
/// smooth saturating function of finger speed, so there is no noticeable "gear change".
struct PointerAcceleration {
    /// User setting, 0.4…2.0 (1 = default).
    var speed: CGFloat = 1
    private var smoothedSpeed: CGFloat = 0

    /// Mac points to move for a finger movement of `delta` view points over `dt` seconds at `zoom`
    /// (view points per Mac point).
    mutating func macDelta(for delta: CGPoint, dt: TimeInterval, zoom: CGFloat) -> CGPoint {
        let distance = delta.length
        guard distance > 0 else { return .zero }
        let instantaneous = distance / CGFloat(max(dt, 1.0 / 240))
        // Light smoothing: touch sample timing jitters, and a single noisy sample shouldn't spike gain.
        smoothedSpeed = smoothedSpeed == 0 ? instantaneous : smoothedSpeed * 0.55 + instantaneous * 0.45
        let gain = 0.7 + 2.6 * (1 - exp(-smoothedSpeed / 900))
        // Zoomed out, a Mac point is tiny on screen, so move more Mac points per finger point; zoomed in,
        // fewer for precision. Square root keeps the effect gentle.
        let zoomFactor = sqrt(min(max(1 / max(zoom, 0.01), 0.5), 2.0))
        let k = gain * speed * zoomFactor
        return CGPoint(x: delta.x * k, y: delta.y * k)
    }

    mutating func reset() { smoothedSpeed = 0 }
}

/// Estimates release velocity from the last ~80 ms of samples (ignores a finger that paused before
/// lifting, so a stop-then-lift doesn't fling).
struct VelocityTracker {
    private var samples: [(t: TimeInterval, p: CGPoint)] = []

    mutating func reset() { samples.removeAll(keepingCapacity: true) }

    mutating func add(_ p: CGPoint, at t: TimeInterval) {
        samples.append((t, p))
        samples.removeAll { t - $0.t > 0.12 }
    }

    func velocity(at now: TimeInterval) -> CGPoint {
        guard let last = samples.last, now - last.t < 0.06 else { return .zero }
        let recent = samples.filter { last.t - $0.t <= 0.08 }
        guard let first = recent.first, last.t - first.t > 0.008 else { return .zero }
        let dt = CGFloat(last.t - first.t)
        return CGPoint(x: (last.p.x - first.p.x) / dt, y: (last.p.y - first.p.y) / dt)
    }
}
