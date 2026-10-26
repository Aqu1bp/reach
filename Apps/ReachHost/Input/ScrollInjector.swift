import CoreGraphics
import Foundation
import os
import ReachProtocol

/// Posts trackpad-style scroll gestures, then generates momentum on the Mac after the fingers lift.
///
/// Direction: `ScrollEvent.dy > 0` means content moves down. A scroll `CGEvent`'s wheel1/point
/// delta is already in "content movement" terms — positive scrolls toward the top of a document,
/// i.e. moves content down (checked in `--self-test`: a pixel event with wheel1 = +10 converts to an
/// `NSEvent` with `scrollingDeltaY == +10` and `isDirectionInvertedFromDevice == false`). "Natural
/// scrolling" is applied by the HID system to *physical* device input before it becomes a CGEvent,
/// so deltas are passed through unchanged and should scroll the same way whatever the user's
/// setting. (End-to-end posting couldn't be checked here without Accessibility permission.)
///
/// Threading: `handle` and `cancelMomentum` are called from the input path; momentum ticks run on a
/// private queue. All state, and every post, happens under `state`'s lock so phases can never
/// interleave (e.g. a stray "momentum continue" after "momentum end").
final class ScrollInjector: @unchecked Sendable {
    private struct Coast {
        let curve: ScrollMomentum
        let startedAt: TimeInterval
        var travelled: (dx: Double, dy: Double) = (0, 0)
        var announced = false
    }

    private struct State {
        var accumulator = ScrollAccumulator()
        var coast: Coast?
        var timer: DispatchSourceTimer?
    }

    /// 120 Hz, like a ProMotion trackpad stream; smooth on 60 Hz and 120 Hz displays alike.
    static let momentumInterval: TimeInterval = 1.0 / 120

    private let poster: EventPoster
    private let queue = DispatchQueue(label: "reach.host.input.momentum", qos: .userInteractive)
    private let state = OSAllocatedUnfairLock(initialState: State())

    init(poster: EventPoster) {
        self.poster = poster
    }

    func handle(_ event: ScrollEvent) {
        state.withLock { s in
            switch event.phase {
            case .began:
                stopCoasting(&s)
                s.accumulator.reset()
                post(&s, dx: event.dx, dy: event.dy, phase: .began)
            case .changed:
                post(&s, dx: event.dx, dy: event.dy, phase: .changed)
            case .ended:
                if event.dx != 0 || event.dy != 0 { post(&s, dx: event.dx, dy: event.dy, phase: .changed) }
                poster.scroll(dx: 0, dy: 0, phase: .ended, momentum: .none)
                if let curve = ScrollMomentum(velocityX: event.velocityX, velocityY: event.velocityY) {
                    startCoasting(&s, curve)
                }
            case .cancelled:
                poster.scroll(dx: 0, dy: 0, phase: .cancelled, momentum: .none)
            case .discrete:
                stopCoasting(&s)
                post(&s, dx: event.dx, dy: event.dy, phase: nil)
            }
        }
    }

    /// Stops any coasting immediately, the way touching a trackpad does.
    func cancelMomentum() {
        state.withLock { stopCoasting(&$0) }
    }

    // MARK: - Private (call with the lock held)

    private func post(_ s: inout State, dx: Double, dy: Double, phase: CGScrollPhase?) {
        let delta = s.accumulator.take(dx: dx, dy: dy)
        // A began/changed event with no movement is still meaningful (it carries the phase), but a
        // phaseless one isn't.
        if phase == nil && delta.dx == 0 && delta.dy == 0 { return }
        poster.scroll(dx: delta.dx, dy: delta.dy, phase: phase, momentum: .none)
    }

    private func startCoasting(_ s: inout State, _ curve: ScrollMomentum) {
        s.coast = Coast(curve: curve, startedAt: uptimeSeconds())
        guard s.timer == nil else { return }
        let timer = DispatchSource.makeTimerSource(flags: .strict, queue: queue)
        let interval = DispatchTimeInterval.nanoseconds(Int(Self.momentumInterval * 1e9))
        timer.schedule(deadline: .now() + interval, repeating: interval, leeway: .microseconds(500))
        timer.setEventHandler { [weak self] in self?.tick() }
        s.timer = timer
        timer.resume()
    }

    private func stopCoasting(_ s: inout State) {
        if let coast = s.coast, coast.announced {
            poster.scroll(dx: 0, dy: 0, phase: nil, momentum: .end)
        }
        s.coast = nil
        s.timer?.cancel()
        s.timer = nil
    }

    private func tick() {
        state.withLock { s in
            guard var coast = s.coast else {
                s.timer?.cancel()
                s.timer = nil
                return
            }
            let elapsed = uptimeSeconds() - coast.startedAt
            let offset = coast.curve.offset(at: elapsed)
            let delta = s.accumulator.take(dx: offset.dx - coast.travelled.dx, dy: offset.dy - coast.travelled.dy)
            coast.travelled = offset
            if !coast.announced {
                poster.scroll(dx: delta.dx, dy: delta.dy, phase: nil, momentum: .begin)
                coast.announced = true
            } else if delta.dx != 0 || delta.dy != 0 {
                poster.scroll(dx: delta.dx, dy: delta.dy, phase: nil, momentum: .continuous)
            }
            s.coast = coast
            if coast.curve.isFinished(at: elapsed) { stopCoasting(&s) }
        }
    }
}
