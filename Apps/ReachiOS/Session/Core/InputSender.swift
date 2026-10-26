import UIKit
import ReachProtocol

/// Turns gesture-level intents into wire messages.
///
/// * Pointer moves and scroll deltas go out the moment they happen — waiting for the next display
///   refresh would add up to a whole frame (16 ms at 60 Hz) to every move. Updates closer together than
///   `minSendInterval` (several touch callbacks in one frame) are coalesced and flushed by a display link.
/// * Any pending pointer move is flushed before a button or scroll event so the Mac sees them in order;
///   button events also carry the position and share the pointer sequence space.
/// * Every mouse-down is remembered so it can always be paired with a mouse-up (cancelled touches,
///   backgrounding, disconnect) — a stuck button on the Mac is the worst failure mode of remote input.
@MainActor
final class InputSender {
    var source: RemoteSessionSource?
    let log: InputLog
    let modifiers: StickyModifiers

    private var pendingPointer: CGPoint?
    private var scrollAccum = CGVector.zero
    private var scrollActive = false
    private var scrollBeganSent = false
    private var link: CADisplayLink?
    private var held: [MouseButton: KeyModifiers] = [:]
    private var lastPointer = CGPoint(x: 0.5, y: 0.5)
    private var lastPointerSentAt: CFTimeInterval = 0
    private var lastScrollSentAt: CFTimeInterval = 0

    /// 240 Hz: above any display's refresh rate, below anything that would load the channel.
    static let minSendInterval: CFTimeInterval = 1.0 / 240

    init(log: InputLog, modifiers: StickyModifiers) {
        self.log = log
        self.modifiers = modifiers
    }

    var isButtonHeld: Bool { !held.isEmpty }

    // MARK: Pointer

    /// Normalized position within the active display (0…1).
    func movePointer(to p: CGPoint) {
        pendingPointer = p
        lastPointer = p
        if CACurrentMediaTime() - lastPointerSentAt >= Self.minSendInterval { flushPointer() } else { startLink() }
    }

    func flushPointer() {
        guard let p = pendingPointer else { return }
        pendingPointer = nil
        lastPointerSentAt = CACurrentMediaTime()
        let x = Float(p.x), y = Float(p.y)
        let seq = source?.sendPointer(x: x, y: y) ?? 0
        log.recordPointer(x: x, y: y, seq: seq)
    }

    // MARK: Buttons

    func button(_ button: MouseButton, down: Bool, at p: CGPoint, clickCount: Int = 1) {
        flushPointer()
        lastPointer = p
        let mods: KeyModifiers
        if down {
            mods = modifiers.consume()
            held[button] = mods
        } else {
            guard let m = held.removeValue(forKey: button) else { return } // never send an unmatched up
            mods = m
        }
        let seq = source?.nextSequence() ?? 0
        send(.mouseButton(MouseButtonEvent(seq: seq, button: button, isDown: down, x: Double(p.x), y: Double(p.y),
                                           clickCount: clickCount, modifiers: mods)))
    }

    func click(_ button: MouseButton = .left, at p: CGPoint, clickCount: Int = 1) {
        self.button(button, down: true, at: p, clickCount: clickCount)
        self.button(button, down: false, at: p, clickCount: clickCount)
    }

    // MARK: Scroll

    /// Content movement in Mac points (positive dy reveals what is above, like dragging a page down).
    func scroll(by delta: CGVector) {
        if !scrollActive {
            scrollActive = true
            scrollBeganSent = false
            scrollAccum = .zero
        }
        scrollAccum.dx += delta.dx
        scrollAccum.dy += delta.dy
        if CACurrentMediaTime() - lastScrollSentAt >= Self.minSendInterval { flushScroll() } else { startLink() }
    }

    private func flushScroll() {
        guard scrollActive, scrollAccum.dx != 0 || scrollAccum.dy != 0 else { return }
        flushPointer()
        let phase: ScrollPhase = scrollBeganSent ? .changed : .began
        send(.scroll(ScrollEvent(dx: Double(scrollAccum.dx), dy: Double(scrollAccum.dy), phase: phase)))
        scrollBeganSent = true
        scrollAccum = .zero
        lastScrollSentAt = CACurrentMediaTime()
    }

    /// Fingers lifted. `velocity` (Mac points/s) lets the Mac run its own momentum, immune to jitter.
    func endScroll(velocity: CGVector) {
        guard scrollActive else { return }
        flushScroll()
        scrollActive = false
        guard scrollBeganSent else { return }
        send(.scroll(ScrollEvent(dx: 0, dy: 0, phase: .ended, velocityX: Double(velocity.dx), velocityY: Double(velocity.dy))))
    }

    func cancelScroll() {
        guard scrollActive else { return }
        scrollActive = false
        scrollAccum = .zero
        guard scrollBeganSent else { return }
        send(.scroll(ScrollEvent(dx: 0, dy: 0, phase: .cancelled)))
    }

    func discreteScroll(dx: Double, dy: Double) {
        flushPointer()
        send(.scroll(ScrollEvent(dx: dx, dy: dy, phase: .discrete)))
    }

    // MARK: Keys

    /// Press-and-release with the sticky modifiers (one-shots are consumed) plus `extra`.
    func keyPress(_ code: UInt16, extra: KeyModifiers = []) {
        send(.keyPress(code: code, modifiers: modifiers.consume().union(extra)))
    }

    /// Raw key transitions from a hardware keyboard. Sticky modifiers from the accessory bar still apply
    /// to the next non-modifier key so the two can be mixed.
    func key(_ code: UInt16, down: Bool, modifiers hw: KeyModifiers) {
        var mods = hw
        if down, !MacKey.modifierKeys.contains(code) { mods.formUnion(modifiers.consume()) }
        send(.key(KeyEvent(code: code, isDown: down, modifiers: mods)))
    }

    func text(_ string: String) {
        guard !string.isEmpty else { return }
        send(.text(TextInput(text: string, modifiers: modifiers.consume())))
    }

    /// Text that must not pick up sticky modifiers (compose sheet).
    func plainText(_ string: String) {
        guard !string.isEmpty else { return }
        send(.text(TextInput(text: string)))
    }

    func action(_ a: SystemAction) { send(.action(a)) }
    func media(_ m: MediaKey) { send(.media(m)) }

    func send(_ message: ClientMessage) {
        source?.send(message)
        log.record(message)
    }

    // MARK: Safety

    /// Release anything held and end any scroll. Called on cancelled touches, mode switches,
    /// backgrounding and disconnect.
    func releaseAll() {
        flushPointer()
        cancelScroll()
        for button in Array(held.keys) { self.button(button, down: false, at: lastPointer) }
    }

    func invalidate() {
        link?.invalidate()
        link = nil
    }

    // MARK: Frame pacing

    private func startLink() {
        if let link {
            link.isPaused = false
            return
        }
        let l = CADisplayLink(target: DisplayLinkProxy { [weak self] in self?.tick() }, selector: #selector(DisplayLinkProxy.fire))
        l.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 120, preferred: 120)
        l.add(to: .main, forMode: .common)
        link = l
    }

    private func tick() {
        flushPointer()
        flushScroll()
        if pendingPointer == nil, scrollAccum == .zero { link?.isPaused = true }
    }
}

/// CADisplayLink retains its target; this proxy breaks the cycle.
final class DisplayLinkProxy: NSObject {
    private let handler: () -> Void
    init(_ handler: @escaping () -> Void) { self.handler = handler }
    @objc func fire() { handler() }
}
