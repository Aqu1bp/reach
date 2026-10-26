import UIKit

/// Tiny display-link tween for values the renderer needs per frame (minimap opacity, dimming).
@MainActor
final class ValueAnimator {
    private(set) var value: CGFloat
    var onUpdate: ((CGFloat) -> Void)?

    private var from: CGFloat = 0
    private var to: CGFloat = 0
    private var start: CFTimeInterval = 0
    private var duration: CFTimeInterval = 0
    private var link: CADisplayLink?

    init(_ value: CGFloat = 0) { self.value = value }

    var target: CGFloat { link == nil ? value : to }

    func animate(to target: CGFloat, duration: CFTimeInterval) {
        guard target != self.target else { return }
        if duration <= 0 || UIAccessibility.isReduceMotionEnabled && duration > 0.2 {
            set(target)
            return
        }
        from = value
        to = target
        start = CACurrentMediaTime()
        self.duration = duration
        if link == nil {
            let l = CADisplayLink(target: DisplayLinkProxy { [weak self] in self?.tick() }, selector: #selector(DisplayLinkProxy.fire))
            l.add(to: .main, forMode: .common)
            link = l
        }
    }

    func set(_ v: CGFloat) {
        link?.invalidate()
        link = nil
        value = v
        onUpdate?(v)
    }

    func invalidate() {
        link?.invalidate()
        link = nil
    }

    private func tick() {
        let t = min((CACurrentMediaTime() - start) / duration, 1)
        let eased = 1 - pow(1 - t, 3)
        value = from + (to - from) * eased
        onUpdate?(value)
        if t >= 1 {
            link?.invalidate()
            link = nil
        }
    }
}
