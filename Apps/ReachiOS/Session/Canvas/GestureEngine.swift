import UIKit
import ReachProtocol

enum GestureFeedback {
    case click, doubleClick, rightClick, dragStart, dragEnd, longPressArmed, zoomToggle
}

@MainActor
protocol GestureEngineDelegate: AnyObject {
    func gesture(_ engine: GestureEngine, feedback: GestureFeedback, at viewPoint: CGPoint)
    func gesture(_ engine: GestureEngine, zoomToWindowAt viewPoint: CGPoint)
    func gesture(_ engine: GestureEngine, performed action: SystemAction)
    func gesture(_ engine: GestureEngine, buttonHeld: Bool)
    func gestureDidBegin(_ engine: GestureEngine)
}

/// Raw-touch state machine implementing the DESIGN.md gesture table for both input modes.
///
/// Raw touches (rather than stacked UIGestureRecognizers with `require(toFail:)`) keep every gesture
/// latency-free: a tap clicks the moment the finger lifts, and a second tap simply sends click count 2
/// — exactly how a physical mouse reports a double-click — instead of waiting to rule out a double-tap.
/// The only deliberate delay is a two-finger tap's right-click (≈¼ s), which must wait to see whether a
/// second two-finger tap (fit ⇄ 1:1) follows.
///
/// | Gesture                 | Trackpad                          | Touch                                  |
/// |-------------------------|-----------------------------------|----------------------------------------|
/// | 1-finger drag           | move cursor (accelerated)         | scroll (momentum on the Mac)           |
/// | tap / double-tap        | click / double-click at cursor    | click / double-click where tapped      |
/// | 2-finger tap            | right-click at cursor             | right-click where tapped               |
/// | long-press (then drag)  | press-and-drag                    | release = right-click, drag = drag     |
/// | tap, then touch-drag    | drag                              | —                                      |
/// | 2-finger drag           | scroll                            | pan the view                           |
/// | pinch                   | zoom around the cursor            | zoom around the fingers                |
/// | 2-finger double-tap     | fit ⇄ 1:1                         | fit ⇄ 1:1                              |
/// | 2-finger long-press     | zoom to window                    | zoom to window                         |
/// | 3-finger swipe          | Mission Control / Exposé / Spaces | same                                   |
@MainActor
final class GestureEngine {
    struct Config: Equatable {
        var mode: InputMode = .trackpad
        var pointerSpeed: CGFloat = 1
        var naturalScrolling = true
    }

    var config = Config() {
        didSet { if config.mode != oldValue.mode { reset() } }
    }
    weak var delegate: GestureEngineDelegate?

    private let viewport: ViewportController
    private let cursor: CursorTracker
    private let input: InputSender
    private var acceleration = PointerAcceleration()

    // Tunables (points / seconds).
    private let tapSlop: CGFloat = 12
    private let trackpadMoveSlop: CGFloat = 4
    private let touchMoveSlop: CGFloat = 10
    private let trackpadTapMaxDuration: TimeInterval = 0.3
    private let longPressDuration: TimeInterval = 0.45
    private let twoFingerLongPressDuration: TimeInterval = 0.55
    private let followTapInterval: TimeInterval = 0.3
    private let multiClickInterval: TimeInterval = 0.42
    private let multiClickDistance: CGFloat = 40
    private let rightClickDelay: TimeInterval = 0.24
    private let threeFingerDistance: CGFloat = 54
    /// Trackpad-mode scroll speed: Mac points per finger point.
    private let trackpadScrollGain: CGFloat = 1.4

    private struct Track {
        var start: CGPoint
        var startTime: TimeInterval
        var location: CGPoint
        var previous: CGPoint
        var previousTime: TimeInterval
        var time: TimeInterval
        var maxDistance: CGFloat = 0
    }

    private enum Phase { case idle, one, two, three, draining }

    private enum OneKind { case pending, pointer, scrolling, dragging, longPressed }
    private struct OneState {
        var id: ObjectIdentifier?
        var kind: OneKind = .pending
        /// Began right after a tap: a drag becomes a press-and-drag ("tap-and-a-half").
        var followsTap = false
        var velocity = VelocityTracker()
    }

    private enum TwoKind { case pending, scrolling, zooming, panZoom, longPressed, finished }
    private struct TwoState {
        var ids: [ObjectIdentifier] = []
        var startCentroid = CGPoint.zero
        var startDistance: CGFloat = 1
        var lastCentroid = CGPoint.zero
        var startTime: TimeInterval = 0
        var kind: TwoKind = .pending
        var lifted = 0
        var firstLiftTime: TimeInterval?
        var anchorContent = CGPoint.zero
        var anchorView = CGPoint.zero
        var startZoom: CGFloat = 1
        var velocity = VelocityTracker()
    }

    private struct ThreeState {
        var starts: [ObjectIdentifier: CGPoint] = [:]
        var fired = false
    }

    private var tracks: [ObjectIdentifier: Track] = [:]
    private var phase: Phase = .idle
    private var one = OneState()
    private var two = TwoState()
    private var three = ThreeState()

    private var longPressWork: DispatchWorkItem?
    private var twoLongPressWork: DispatchWorkItem?
    private var pendingRightClick: (work: DispatchWorkItem, target: CGPoint, view: CGPoint)?
    private var deferredRightClick: (target: CGPoint, view: CGPoint)?

    private var lastTapTime: TimeInterval = -1
    private var lastTapView = CGPoint.zero
    private var lastTapTarget = CGPoint.zero
    private var lastClickCount = 0

    private var autoPanLink: CADisplayLink?
    private var autoPanVelocity = CGPoint.zero

    // Indirect pointer (iPad trackpad / mouse).
    private var indirectButton: MouseButton?

    init(viewport: ViewportController, cursor: CursorTracker, input: InputSender) {
        self.viewport = viewport
        self.cursor = cursor
        self.input = input
    }

    // MARK: Helpers

    private var vp: Viewport { viewport.viewport }
    private var cursorViewPoint: CGPoint { vp.viewPoint(forNormalized: cursor.position) }
    private func normalized(_ p: CGPoint) -> CGPoint { vp.normalized(forView: p) }
    private var isTrackpad: Bool { config.mode == .trackpad }

    private func centroid(_ ids: [ObjectIdentifier]) -> CGPoint {
        let pts = ids.compactMap { tracks[$0]?.location }
        guard !pts.isEmpty else { return .zero }
        let s = pts.reduce(CGPoint.zero, +)
        return CGPoint(x: s.x / CGFloat(pts.count), y: s.y / CGFloat(pts.count))
    }

    private func spread(_ ids: [ObjectIdentifier]) -> CGFloat {
        let pts = ids.compactMap { tracks[$0]?.location }
        guard pts.count == 2 else { return 1 }
        return max(pts[0].distance(to: pts[1]), 1)
    }

    private func feedback(_ kind: GestureFeedback, at p: CGPoint) {
        delegate?.gesture(self, feedback: kind, at: p)
    }

    // MARK: Touches

    func touchesBegan(_ touches: Set<UITouch>, in view: UIView, event: UIEvent?) {
        var direct = false
        for t in touches {
            if t.type == .indirectPointer {
                indirectBegan(t, in: view, event: event)
                continue
            }
            direct = true
            let p = t.location(in: view)
            tracks[ObjectIdentifier(t)] = Track(start: p, startTime: t.timestamp, location: p, previous: p,
                                                previousTime: t.timestamp, time: t.timestamp)
        }
        guard direct else { return }
        delegate?.gestureDidBegin(self)
        let now = touches.first?.timestamp ?? ProcessInfo.processInfo.systemUptime
        let ids = Array(tracks.keys)

        switch phase {
        case .idle:
            if ids.count == 1 { beginOne(ids[0], now: now) }
            else if ids.count == 2 { beginTwo(ids, now: now) }
            else { beginThree() }
        case .one:
            // Extra fingers during a drag are ignored: the drag continues with the first finger.
            if one.kind == .dragging { return }
            endOneForMultiTouch()
            if ids.count == 2 { beginTwo(ids, now: now) } else { beginThree() }
        case .two:
            if ids.count >= 3, two.kind != .finished, two.lifted == 0 {
                endTwoForThree(now: now)
                beginThree()
            }
        case .three, .draining:
            break
        }
    }

    func touchesMoved(_ touches: Set<UITouch>, in view: UIView, event: UIEvent?) {
        var moved: [ObjectIdentifier] = []
        for t in touches {
            if t.type == .indirectPointer {
                indirectMoved(t, in: view)
                continue
            }
            let id = ObjectIdentifier(t)
            guard var tr = tracks[id] else { continue }
            tr.previous = tr.location
            tr.previousTime = tr.time
            tr.location = t.location(in: view)
            tr.time = t.timestamp
            tr.maxDistance = max(tr.maxDistance, tr.location.distance(to: tr.start))
            tracks[id] = tr
            moved.append(id)
        }
        guard !moved.isEmpty else { return }
        let now = touches.first?.timestamp ?? ProcessInfo.processInfo.systemUptime
        switch phase {
        case .one: if let id = one.id, moved.contains(id) { oneMoved(now: now) }
        case .two: twoMoved(now: now)
        case .three: threeMoved()
        case .idle, .draining: break
        }
    }

    func touchesEnded(_ touches: Set<UITouch>, in view: UIView, event: UIEvent?, cancelled: Bool) {
        var ended: Set<ObjectIdentifier> = []
        for t in touches {
            if t.type == .indirectPointer {
                indirectEnded(t, in: view, cancelled: cancelled)
                continue
            }
            let id = ObjectIdentifier(t)
            guard var tr = tracks[id] else { continue }
            tr.location = t.location(in: view)
            tr.time = t.timestamp
            tracks[id] = tr
            ended.insert(id)
        }
        guard !ended.isEmpty else { return }
        let now = touches.first?.timestamp ?? ProcessInfo.processInfo.systemUptime

        switch phase {
        case .one:
            if let id = one.id, ended.contains(id) {
                oneEnded(now: now, cancelled: cancelled)
                phase = .draining
            }
        case .two:
            twoLifted(ended, now: now, cancelled: cancelled)
        case .three, .idle, .draining:
            break
        }
        for id in ended { tracks.removeValue(forKey: id) }
        if tracks.isEmpty { phase = .idle }
    }

    /// Release anything in progress (mode switch, keyboard, interruption).
    func reset() {
        cancelLongPress()
        cancelTwoLongPress()
        stopAutoPan()
        flushDeferredRightClick()
        if phase == .one, one.kind == .dragging { setHeld(false) }
        if phase == .two, two.kind == .zooming || two.kind == .panZoom {
            viewport.endInteraction(velocity: .zero, anchorView: two.anchorView)
        }
        input.releaseAll()
        setHeld(false)
        phase = tracks.isEmpty ? .idle : .draining
    }

    // MARK: One finger

    private func beginOne(_ id: ObjectIdentifier, now: TimeInterval) {
        phase = .one
        let p = tracks[id]?.location ?? .zero
        let follows = now - lastTapTime < followTapInterval && (isTrackpad || p.distance(to: lastTapView) < multiClickDistance)
        one = OneState(id: id, kind: .pending, followsTap: follows)
        one.velocity.add(p, at: now)
        acceleration.reset()
        acceleration.speed = config.pointerSpeed
        scheduleLongPress()
    }

    private func oneMoved(now: TimeInterval) {
        guard let id = one.id, let tr = tracks[id] else { return }
        one.velocity.add(tr.location, at: now)
        let delta = tr.location - tr.previous
        let dt = tr.time - tr.previousTime

        if isTrackpad {
            switch one.kind {
            case .pending:
                guard tr.maxDistance > trackpadMoveSlop else { return }
                cancelLongPress()
                if one.followsTap {
                    one.kind = .dragging
                    input.button(.left, down: true, at: cursor.position)
                    setHeld(true)
                    feedback(.dragStart, at: cursorViewPoint)
                } else {
                    one.kind = .pointer
                }
                // Apply the movement that happened inside the slop too, so nothing is lost.
                movePointer(by: tr.location - tr.start, dt: tr.time - tr.startTime)
            case .pointer, .dragging:
                movePointer(by: delta, dt: dt)
            case .scrolling, .longPressed:
                break
            }
        } else {
            switch one.kind {
            case .pending:
                guard tr.maxDistance > touchMoveSlop else { return }
                cancelLongPress()
                one.kind = .scrolling
                // Scroll events go to whatever is under the Mac's pointer, so put it under the finger.
                let n = normalized(tr.start)
                cursor.moveLocally(to: n)
                input.movePointer(to: n)
                input.scroll(by: touchScrollDelta(tr.location - tr.start))
            case .scrolling:
                input.scroll(by: touchScrollDelta(delta))
            case .longPressed:
                guard tr.maxDistance > touchMoveSlop else { return }
                one.kind = .dragging
                let n = normalized(tr.start)
                cursor.moveLocally(to: n)
                input.button(.left, down: true, at: n)
                setHeld(true)
                feedback(.dragStart, at: tr.start)
                dragTo(tr.location)
            case .dragging:
                dragTo(tr.location)
                updateAutoPan(for: tr.location)
            case .pointer:
                break
            }
        }
    }

    private func oneEnded(now: TimeInterval, cancelled: Bool) {
        cancelLongPress()
        stopAutoPan()
        guard let id = one.id, let tr = tracks[id] else { return }

        if cancelled {
            switch one.kind {
            case .dragging:
                input.button(.left, down: false, at: cursor.position)
                setHeld(false)
            case .scrolling:
                input.cancelScroll()
            default: break
            }
            return
        }

        if isTrackpad {
            switch one.kind {
            case .pending:
                if now - tr.startTime < trackpadTapMaxDuration || one.followsTap { tap(at: tr.start, now: now) }
            case .dragging:
                input.button(.left, down: false, at: cursor.position)
                setHeld(false)
                feedback(.dragEnd, at: cursorViewPoint)
            case .pointer, .scrolling, .longPressed:
                break
            }
        } else {
            switch one.kind {
            case .pending:
                tap(at: tr.start, now: now)
            case .scrolling:
                let v = one.velocity.velocity(at: now)
                input.endScroll(velocity: CGVector(dx: v.x / vp.zoom, dy: v.y / vp.zoom))
            case .longPressed:
                let n = normalized(tr.start)
                cursor.moveLocally(to: n)
                input.movePointer(to: n)
                input.click(.right, at: n)
                feedback(.rightClick, at: tr.start)
            case .dragging:
                let n = normalized(tr.location)
                cursor.moveLocally(to: n)
                input.button(.left, down: false, at: n)
                setHeld(false)
                feedback(.dragEnd, at: tr.location)
            case .pointer:
                break
            }
        }
    }

    /// A second finger arrived: wind down the one-finger gesture without side effects.
    private func endOneForMultiTouch() {
        cancelLongPress()
        stopAutoPan()
        if one.kind == .scrolling { input.endScroll(velocity: .zero) }
    }

    private func tap(at viewPoint: CGPoint, now: TimeInterval) {
        let isRepeat = now - lastTapTime < multiClickInterval
            && (isTrackpad || viewPoint.distance(to: lastTapView) < multiClickDistance)
        let count = isRepeat ? min(lastClickCount + 1, 3) : 1
        let target: CGPoint
        if isTrackpad {
            target = cursor.position
        } else {
            // Later clicks of a double/triple-click land exactly where the first did.
            target = isRepeat ? lastTapTarget : normalized(viewPoint)
            cursor.moveLocally(to: target)
            input.movePointer(to: target)
        }
        input.click(.left, at: target, clickCount: count)
        lastTapTime = now
        lastTapView = viewPoint
        lastTapTarget = target
        lastClickCount = count
        feedback(count > 1 ? .doubleClick : .click, at: isTrackpad ? cursorViewPoint : viewPoint)
    }

    private func movePointer(by viewDelta: CGPoint, dt: TimeInterval) {
        let v = vp
        guard v.contentSize.width > 0, v.contentSize.height > 0 else { return }
        let mac = acceleration.macDelta(for: viewDelta, dt: dt, zoom: v.zoom)
        var p = cursor.position
        p.x += mac.x / v.contentSize.width
        p.y += mac.y / v.contentSize.height
        cursor.moveLocally(to: p)
        let clamped = cursor.position
        input.movePointer(to: clamped)
        viewport.ensureVisible(vp.viewPoint(forNormalized: clamped))
    }

    private func dragTo(_ viewPoint: CGPoint) {
        let n = normalized(viewPoint)
        cursor.moveLocally(to: n)
        input.movePointer(to: n)
    }

    /// Touch mode: content follows the finger exactly (direct manipulation), so the Mac delta is the
    /// finger delta divided by the zoom. The natural-scrolling setting doesn't apply to direct touch.
    private func touchScrollDelta(_ d: CGPoint) -> CGVector {
        CGVector(dx: d.x / vp.zoom, dy: d.y / vp.zoom)
    }

    private func trackpadScrollDelta(_ d: CGPoint) -> CGVector {
        let sign: CGFloat = config.naturalScrolling ? 1 : -1
        return CGVector(dx: d.x * trackpadScrollGain * sign, dy: d.y * trackpadScrollGain * sign)
    }

    private func setHeld(_ held: Bool) {
        if held { cursor.holdPrediction() }
        delegate?.gesture(self, buttonHeld: held)
    }

    private func scheduleLongPress() {
        cancelLongPress()
        let work = DispatchWorkItem { [weak self] in self?.longPressFired() }
        longPressWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + longPressDuration, execute: work)
    }

    private func cancelLongPress() {
        longPressWork?.cancel()
        longPressWork = nil
    }

    private func longPressFired() {
        longPressWork = nil
        guard phase == .one, one.kind == .pending, let id = one.id, let tr = tracks[id], tr.maxDistance <= tapSlop else { return }
        if isTrackpad {
            one.kind = .dragging
            input.button(.left, down: true, at: cursor.position)
            setHeld(true)
            feedback(.dragStart, at: cursorViewPoint)
        } else {
            one.kind = .longPressed
            feedback(.longPressArmed, at: tr.start)
        }
    }

    // MARK: Edge auto-pan (touch-mode drag while zoomed in)

    private func updateAutoPan(for p: CGPoint) {
        let area = vp.visibleArea
        let edge: CGFloat = 44
        func push(_ d: CGFloat) -> CGFloat { d < edge ? (edge - d) / edge : 0 }
        let vx = push(p.x - area.minX) - push(area.maxX - p.x)
        let vy = push(p.y - area.minY) - push(area.maxY - p.y)
        autoPanVelocity = CGPoint(x: vx * 700, y: vy * 700)
        guard vp.isZoomedIn, vx != 0 || vy != 0 else { stopAutoPan(); return }
        if autoPanLink == nil {
            let link = CADisplayLink(target: DisplayLinkProxy { [weak self] in self?.autoPanTick() }, selector: #selector(DisplayLinkProxy.fire))
            link.add(to: .main, forMode: .common)
            autoPanLink = link
        }
    }

    private func autoPanTick() {
        guard phase == .one, one.kind == .dragging, let id = one.id, let tr = tracks[id] else { stopAutoPan(); return }
        let dt: CGFloat = 1.0 / 60
        let moved = viewport.nudge(by: CGPoint(x: autoPanVelocity.x * dt, y: autoPanVelocity.y * dt))
        if moved != .zero { dragTo(tr.location) }
    }

    private func stopAutoPan() {
        autoPanLink?.invalidate()
        autoPanLink = nil
    }

    // MARK: Two fingers

    private func beginTwo(_ ids: [ObjectIdentifier], now: TimeInterval) {
        phase = .two
        let ids = Array(ids.prefix(2))
        let c = centroid(ids)
        two = TwoState(ids: ids, startCentroid: c, startDistance: spread(ids), lastCentroid: c, startTime: now,
                       startZoom: vp.zoom)
        two.velocity.add(c, at: now)
        // A two-finger tap is waiting to see if this is its second tap (fit ⇄ 1:1).
        if let pending = pendingRightClick {
            pending.work.cancel()
            deferredRightClick = (pending.target, pending.view)
            pendingRightClick = nil
        }
        scheduleTwoLongPress()
    }

    private func twoMoved(now: TimeInterval) {
        guard two.lifted == 0, two.kind != .finished, two.kind != .longPressed else { return }
        let c = centroid(two.ids)
        let d = spread(two.ids)
        two.velocity.add(c, at: now)
        let translation = c - two.startCentroid
        let maxFinger = two.ids.compactMap { tracks[$0]?.maxDistance }.max() ?? 0
        if maxFinger > 10 { cancelTwoLongPress() }
        defer { two.lastCentroid = c }

        switch two.kind {
        case .pending:
            let pinch = abs(d - two.startDistance)
            if isTrackpad {
                if pinch > 22, pinch > translation.length * 0.8 {
                    two.kind = .zooming
                    flushDeferredRightClick()
                    viewport.beginInteraction()
                    let anchor = cursorViewPoint
                    let area = vp.visibleArea
                    two.anchorView = CGPoint(x: anchor.x.clamped(to: area.minX...area.maxX), y: anchor.y.clamped(to: area.minY...area.maxY))
                    two.anchorContent = vp.contentPoint(forView: two.anchorView)
                    two.startZoom = vp.zoom
                    two.startDistance = d
                } else if translation.length > 8 {
                    two.kind = .scrolling
                    flushDeferredRightClick()
                    input.scroll(by: trackpadScrollDelta(translation))
                }
            } else if pinch > 10 || translation.length > 8 {
                two.kind = .panZoom
                flushDeferredRightClick()
                viewport.beginInteraction()
                two.anchorContent = vp.contentPoint(forView: c)
                two.startZoom = vp.zoom
                two.startDistance = d
            }
        case .scrolling:
            input.scroll(by: trackpadScrollDelta(c - two.lastCentroid))
        case .zooming:
            viewport.interact(anchorContent: two.anchorContent, anchorView: two.anchorView, zoom: two.startZoom * d / two.startDistance)
        case .panZoom:
            viewport.interact(anchorContent: two.anchorContent, anchorView: c, zoom: two.startZoom * d / two.startDistance)
        case .longPressed, .finished:
            break
        }
    }

    private func twoLifted(_ ended: Set<ObjectIdentifier>, now: TimeInterval, cancelled: Bool) {
        let count = two.ids.filter(ended.contains).count
        guard count > 0 else { return }
        cancelTwoLongPress()
        switch two.kind {
        case .pending:
            two.lifted += count
            if two.firstLiftTime == nil { two.firstLiftTime = now }
            guard two.lifted >= 2 else { return }
            let quick = now - two.startTime < 0.4 && now - (two.firstLiftTime ?? now) < 0.2
            let still = (two.ids.compactMap { tracks[$0]?.maxDistance }.max() ?? 0) < tapSlop
            if !cancelled, quick, still {
                twoFingerTap(at: two.startCentroid, now: now)
            } else {
                flushDeferredRightClick()
            }
        case .scrolling:
            if cancelled {
                input.cancelScroll()
            } else {
                let v = two.velocity.velocity(at: now)
                input.endScroll(velocity: trackpadScrollDelta(v))
            }
        case .zooming:
            viewport.endInteraction(velocity: .zero, anchorView: two.anchorView)
        case .panZoom:
            viewport.endInteraction(velocity: cancelled ? .zero : two.velocity.velocity(at: now), anchorView: two.lastCentroid)
        case .longPressed, .finished:
            break
        }
        two.kind = .finished
    }

    private func endTwoForThree(now: TimeInterval) {
        cancelTwoLongPress()
        switch two.kind {
        case .scrolling: input.endScroll(velocity: .zero)
        case .zooming: viewport.endInteraction(velocity: .zero, anchorView: two.anchorView)
        case .panZoom: viewport.endInteraction(velocity: .zero, anchorView: two.lastCentroid)
        default: break
        }
        two.kind = .finished
    }

    private func twoFingerTap(at centroid: CGPoint, now: TimeInterval) {
        if deferredRightClick != nil {
            // Second two-finger tap: toggle fit ⇄ 1:1 and drop the pending right-click.
            deferredRightClick = nil
            viewport.toggleFit(around: centroid)
            feedback(.zoomToggle, at: centroid)
            return
        }
        let target = isTrackpad ? cursor.position : normalized(centroid)
        let view = isTrackpad ? cursorViewPoint : centroid
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.pendingRightClick = nil
            self.rightClick(at: target, view: view)
        }
        pendingRightClick = (work, target, view)
        DispatchQueue.main.asyncAfter(deadline: .now() + rightClickDelay, execute: work)
    }

    private func flushDeferredRightClick() {
        guard let d = deferredRightClick else { return }
        deferredRightClick = nil
        rightClick(at: d.target, view: d.view)
    }

    private func rightClick(at target: CGPoint, view: CGPoint) {
        if !isTrackpad {
            cursor.moveLocally(to: target)
            input.movePointer(to: target)
        }
        input.click(.right, at: target)
        feedback(.rightClick, at: view)
    }

    private func scheduleTwoLongPress() {
        cancelTwoLongPress()
        let work = DispatchWorkItem { [weak self] in self?.twoLongPressFired() }
        twoLongPressWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + twoFingerLongPressDuration, execute: work)
    }

    private func cancelTwoLongPress() {
        twoLongPressWork?.cancel()
        twoLongPressWork = nil
    }

    private func twoLongPressFired() {
        twoLongPressWork = nil
        guard phase == .two, two.kind == .pending, two.lifted == 0 else { return }
        two.kind = .longPressed
        flushDeferredRightClick()
        delegate?.gesture(self, zoomToWindowAt: centroid(two.ids))
    }

    // MARK: Three fingers

    private func beginThree() {
        cancelLongPress()
        cancelTwoLongPress()
        stopAutoPan()
        flushDeferredRightClick()
        phase = .three
        three = ThreeState(starts: tracks.mapValues(\.location), fired: false)
    }

    private func threeMoved() {
        guard !three.fired else { return }
        let deltas = three.starts.compactMap { id, start in tracks[id].map { $0.location - start } }
        guard !deltas.isEmpty else { return }
        let sum = deltas.reduce(CGPoint.zero, +)
        let avg = CGPoint(x: sum.x / CGFloat(deltas.count), y: sum.y / CGFloat(deltas.count))
        guard max(abs(avg.x), abs(avg.y)) > threeFingerDistance else { return }
        three.fired = true
        let action: SystemAction
        if abs(avg.y) > abs(avg.x) {
            action = avg.y < 0 ? .missionControl : .appExpose
        } else {
            // Like a Mac trackpad: swiping left reveals the Space to the right.
            action = avg.x < 0 ? .nextSpace : .previousSpace
        }
        input.action(action)
        delegate?.gesture(self, performed: action)
    }

    // MARK: Indirect pointer (iPad trackpad / mouse): absolute, like a real mouse

    func hover(at viewPoint: CGPoint) {
        guard indirectButton == nil else { return }
        let n = normalized(viewPoint)
        cursor.moveLocally(to: n)
        input.movePointer(to: n)
    }

    private func indirectBegan(_ t: UITouch, in view: UIView, event: UIEvent?) {
        let p = t.location(in: view)
        let n = normalized(p)
        let button: MouseButton = event?.buttonMask.contains(.secondary) == true ? .right : .left
        indirectButton = button
        cursor.moveLocally(to: n)
        input.movePointer(to: n)
        let now = t.timestamp
        let isRepeat = now - lastTapTime < multiClickInterval && p.distance(to: lastTapView) < 6 && button == .left
        let count = isRepeat ? min(lastClickCount + 1, 3) : 1
        lastClickCount = count
        lastTapTime = now
        lastTapView = p
        input.button(button, down: true, at: n, clickCount: count)
    }

    private func indirectMoved(_ t: UITouch, in view: UIView) {
        let n = normalized(t.location(in: view))
        cursor.moveLocally(to: n)
        input.movePointer(to: n)
    }

    private func indirectEnded(_ t: UITouch, in view: UIView, cancelled: Bool) {
        guard let button = indirectButton else { return }
        indirectButton = nil
        let n = normalized(t.location(in: view))
        input.button(button, down: false, at: n, clickCount: lastClickCount)
    }

    /// Two-finger scroll on an iPad trackpad or a mouse wheel (view points).
    func indirectScroll(translationDelta d: CGPoint, phase: UIGestureRecognizer.State, velocity: CGPoint) {
        switch phase {
        case .began, .changed:
            input.scroll(by: CGVector(dx: d.x, dy: d.y))
        case .ended:
            input.endScroll(velocity: CGVector(dx: velocity.x, dy: velocity.y))
        default:
            input.cancelScroll()
        }
    }
}
