import UIKit

/// Owns the live `Viewport` on the main thread: direct manipulation with rubber-banding, momentum with
/// spring-back at the edges, animated transitions (fit ⇄ 1:1, zoom to window, keyboard) and cursor
/// following. Every change is reported through `onChange` so the renderer can redraw immediately.
@MainActor
final class ViewportController {
    private(set) var viewport = Viewport()
    var onChange: ((Viewport) -> Void)?
    /// True while a finger, momentum or animation is moving the view (drives the minimap).
    var onMotionChanged: ((Bool) -> Void)?

    private enum Motion {
        case none
        case momentum(velocity: CGPoint)
        case animation(from: Snapshot, to: Snapshot, start: CFTimeInterval, duration: CFTimeInterval)
    }

    private struct Snapshot {
        var zoom: CGFloat
        /// Content point shown at the centre of the visible area.
        var center: CGPoint
    }

    private var motion: Motion = .none
    private var interacting = false
    private var link: CADisplayLink?
    private var lastTick: CFTimeInterval = 0
    private var reportedMoving = false

    var isMoving: Bool {
        if interacting { return true }
        if case .none = motion { return false }
        return true
    }

    // MARK: Layout

    func setBounds(_ size: CGSize) {
        guard size.width > 0, size.height > 0, size != viewport.bounds else { return }
        let wasFit = viewport.isAtFit || viewport.bounds.width <= 1
        let center = centerContentPoint
        stopMotion()
        viewport.bounds = size
        if wasFit {
            viewport.fit()
        } else {
            viewport.zoom = viewport.clampedZoom(viewport.zoom)
            place(center: center, zoom: viewport.zoom)
        }
        publish()
    }

    func setContentSize(_ size: CGSize) {
        guard size.width > 0, size.height > 0, size != viewport.contentSize else { return }
        stopMotion()
        viewport.contentSize = size
        viewport.fit()
        publish()
    }

    /// Keyboard and accessory bar coverage. Animated alongside the keyboard, keeping `keeping` (the
    /// cursor, normalized) inside the area that stays visible.
    func setInsets(_ insets: UIEdgeInsets, duration: TimeInterval, keeping normalizedPoint: CGPoint? = nil) {
        guard insets != viewport.insets else { return }
        viewport.insets = insets
        var targetOffset = viewport.clampedOffset(viewport.offset, zoom: viewport.zoom)
        if let n = normalizedPoint {
            var v = viewport
            v.offset = targetOffset
            let p = v.viewPoint(forNormalized: n)
            let safe = v.visibleArea.insetBy(dx: min(48, v.visibleArea.width * 0.2), dy: min(40, v.visibleArea.height * 0.2))
            var o = targetOffset
            if p.y > safe.maxY { o.y -= p.y - safe.maxY } else if p.y < safe.minY { o.y += safe.minY - p.y }
            if p.x > safe.maxX { o.x -= p.x - safe.maxX } else if p.x < safe.minX { o.x += safe.minX - p.x }
            targetOffset = viewport.clampedOffset(o, zoom: viewport.zoom)
        }
        if duration > 0.01, targetOffset != viewport.offset, !UIAccessibility.isReduceMotionEnabled {
            stopMotion()
            animate(to: snapshot(zoom: viewport.zoom, offset: targetOffset), duration: duration)
        } else {
            viewport.offset = targetOffset
            publish()
        }
    }

    func fit(animated: Bool) {
        var v = viewport
        v.fit()
        transition(zoom: v.zoom, offset: v.offset, animated: animated)
    }

    func setZoomRelativeToFit(_ factor: CGFloat) {
        let z = viewport.clampedZoom(viewport.fitZoom * factor)
        let center = CGPoint(x: viewport.contentSize.width / 2, y: viewport.contentSize.height / 2)
        place(center: center, zoom: z)
        publish()
    }

    // MARK: Direct manipulation

    func beginInteraction() {
        stopMotion()
        interacting = true
        publish()
    }

    /// Keep `anchorContent` under `anchorView` at `zoom`, with rubber-banding past the limits.
    func interact(anchorContent: CGPoint, anchorView: CGPoint, zoom rawZoom: CGFloat) {
        let z = viewport.rubberBandedZoom(rawZoom)
        let o = viewport.offset(keeping: anchorContent, at: anchorView, zoom: z)
        viewport.zoom = z
        viewport.offset = viewport.rubberBandedOffset(o, zoom: z)
        publish()
    }

    /// Fingers lifted with `velocity` (view points/s): settle zoom, then glide and spring back.
    func endInteraction(velocity: CGPoint, anchorView: CGPoint) {
        interacting = false
        let clampedZoom = viewport.clampedZoom(viewport.zoom)
        if abs(clampedZoom - viewport.zoom) > 0.0001 {
            let anchorContent = viewport.contentPoint(forView: anchorView)
            let o = viewport.clampedOffset(viewport.offset(keeping: anchorContent, at: anchorView, zoom: clampedZoom), zoom: clampedZoom)
            transition(zoom: clampedZoom, offset: o, animated: true)
            return
        }
        let speed = velocity.length
        let v = speed > 4000 ? CGPoint(x: velocity.x * 4000 / speed, y: velocity.y * 4000 / speed) : velocity
        if UIAccessibility.isReduceMotionEnabled {
            viewport.offset = viewport.clampedOffset(viewport.offset, zoom: viewport.zoom)
            publish()
            return
        }
        motion = .momentum(velocity: v)
        startLink()
    }

    /// Keep a view point (the cursor) inside the visible area, panning immediately. Trackpad mode uses
    /// this so you never pan manually while zoomed.
    func ensureVisible(_ p: CGPoint, margin: CGFloat = 56) {
        guard viewport.isZoomedIn, !interacting else { return }
        let v = viewport.visibleArea
        let mx = min(margin, v.width * 0.2), my = min(margin, v.height * 0.2)
        let safe = v.insetBy(dx: mx, dy: my)
        var dx: CGFloat = 0, dy: CGFloat = 0
        if p.x < safe.minX { dx = safe.minX - p.x } else if p.x > safe.maxX { dx = safe.maxX - p.x }
        if p.y < safe.minY { dy = safe.minY - p.y } else if p.y > safe.maxY { dy = safe.maxY - p.y }
        guard dx != 0 || dy != 0 else { return }
        if case .animation = motion { return } // a deliberate transition wins
        stopMotion()
        let o = CGPoint(x: viewport.offset.x + dx, y: viewport.offset.y + dy)
        viewport.offset = viewport.clampedOffset(o, zoom: viewport.zoom)
        publish()
    }

    /// Immediate pan (edge auto-scroll while dragging). Returns the distance actually moved.
    @discardableResult
    func nudge(by delta: CGPoint) -> CGPoint {
        stopMotion()
        let before = viewport.offset
        viewport.offset = viewport.clampedOffset(before + delta, zoom: viewport.zoom)
        publish()
        return viewport.offset - before
    }

    /// Two-finger double-tap: fit ⇄ 1:1 (Mac points at their native size) around the touch.
    func toggleFit(around viewPoint: CGPoint) {
        let fitZoom = viewport.fitZoom
        let oneToOne: CGFloat = fitZoom < 0.75 ? 1.0 : min(fitZoom * 2, viewport.maxZoom)
        if viewport.zoom < oneToOne * 0.92 {
            let c = viewport.contentPoint(forView: viewPoint)
            let o = viewport.clampedOffset(viewport.offset(keeping: c, at: viewPoint, zoom: oneToOne), zoom: oneToOne)
            transition(zoom: oneToOne, offset: o, animated: true)
        } else {
            fit(animated: true)
        }
    }

    func zoom(toContentRect rect: CGRect) {
        let target = viewport.framing(rect)
        transition(zoom: target.zoom, offset: target.offset, animated: true)
    }

    // MARK: Internals

    private var centerContentPoint: CGPoint {
        let v = viewport.visibleArea
        return viewport.contentPoint(forView: CGPoint(x: v.midX, y: v.midY))
    }

    private var snapshot: Snapshot { Snapshot(zoom: viewport.zoom, center: centerContentPoint) }

    private func snapshot(zoom: CGFloat, offset: CGPoint) -> Snapshot {
        var v = viewport
        v.zoom = zoom
        v.offset = offset
        let a = v.visibleArea
        return Snapshot(zoom: zoom, center: v.contentPoint(forView: CGPoint(x: a.midX, y: a.midY)))
    }

    private func place(center: CGPoint, zoom: CGFloat, clamp: Bool = true) {
        let v = viewport.visibleArea
        let o = viewport.offset(keeping: center, at: CGPoint(x: v.midX, y: v.midY), zoom: zoom)
        viewport.zoom = zoom
        viewport.offset = clamp ? viewport.clampedOffset(o, zoom: zoom) : o
    }

    private func transition(zoom: CGFloat, offset: CGPoint, animated: Bool) {
        stopMotion()
        let to = snapshot(zoom: zoom, offset: offset)
        if !animated || UIAccessibility.isReduceMotionEnabled {
            viewport.zoom = zoom
            viewport.offset = offset
            publish()
            return
        }
        animate(to: to, duration: 0.5)
    }

    private func animate(to: Snapshot, duration: TimeInterval) {
        motion = .animation(from: snapshot, to: to, start: CACurrentMediaTime(), duration: duration)
        startLink()
        publish()
    }

    private func stopMotion() {
        motion = .none
        link?.isPaused = true
    }

    private func startLink() {
        lastTick = CACurrentMediaTime()
        if let link {
            link.isPaused = false
            return
        }
        let l = CADisplayLink(target: DisplayLinkProxy { [weak self] in self?.tick() }, selector: #selector(DisplayLinkProxy.fire))
        l.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 120, preferred: 120)
        l.add(to: .main, forMode: .common)
        link = l
    }

    func invalidate() {
        link?.invalidate()
        link = nil
    }

    private func tick() {
        let now = CACurrentMediaTime()
        let dt = CGFloat(min(max(now - lastTick, 1.0 / 240), 1.0 / 30))
        lastTick = now
        switch motion {
        case .none:
            link?.isPaused = true
        case .momentum(let velocity):
            let r = viewport.offsetRange(zoom: viewport.zoom)
            let (x, vx, doneX) = Self.step(viewport.offset.x, velocity.x, range: r.x, dt: dt)
            let (y, vy, doneY) = Self.step(viewport.offset.y, velocity.y, range: r.y, dt: dt)
            viewport.offset = CGPoint(x: x, y: y)
            if doneX && doneY {
                viewport.offset = viewport.clampedOffset(viewport.offset, zoom: viewport.zoom)
                motion = .none
            } else {
                motion = .momentum(velocity: CGPoint(x: vx, y: vy))
            }
            publish()
        case .animation(let from, let to, let start, let duration):
            let t = min((now - start) / duration, 1)
            // Critically damped spring curve: fast start, soft landing, no overshoot.
            let omega = 9.0 / duration
            let p = t >= 1 ? 1 : 1 - (1 + omega * (now - start)) * exp(-omega * (now - start))
            // Geometric interpolation of the zoom: from × (to ÷ from)^p. Done on Doubles with the
            // Darwin `pow`: `log` of a CGFloat is ambiguous between the Darwin and CoreGraphics
            // overloads in the iOS 26 SDK.
            let z = from.zoom * CGFloat(Darwin.pow(Double(to.zoom / from.zoom), p))
            let c = CGPoint(x: from.center.x + (to.center.x - from.center.x) * p,
                            y: from.center.y + (to.center.y - from.center.y) * p)
            place(center: c, zoom: z, clamp: false)
            if t >= 1 {
                place(center: to.center, zoom: to.zoom, clamp: true)
                motion = .none
            }
            publish()
        }
    }

    /// One axis of momentum: UIScrollView-like deceleration inside the range, critically damped spring
    /// back to the edge outside it.
    private static func step(_ x: CGFloat, _ v: CGFloat, range: ClosedRange<CGFloat>, dt: CGFloat) -> (CGFloat, CGFloat, Bool) {
        var x = x, v = v
        if range.contains(x) {
            x += v * dt
            v *= pow(0.998, dt * 1000)
            if range.contains(x) { return (x, v, abs(v) < 6) }
            return (x, v, false)
        }
        let target = x.clamped(to: range)
        let k: CGFloat = 180, c: CGFloat = 2 * sqrt(180)
        let a = -k * (x - target) - c * v
        v += a * dt
        x += v * dt
        let done = abs(x - target) < 0.5 && abs(v) < 10
        return (done ? target : x, done ? 0 : v, done)
    }

    private func publish() {
        onChange?(viewport)
        let moving = isMoving
        if moving != reportedMoving {
            reportedMoving = moving
            onMotionChanged?(moving)
        }
    }
}
