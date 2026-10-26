import AppKit
import os
import ReachCore
import ReachProtocol

/// Receives problems the injector can't solve on its own. Called from the input path (any thread).
protocol InputInjectorDelegate: AnyObject {
    /// Input arrived, but macOS won't accept synthetic events until Accessibility is granted.
    func injectorNeedsAccessibility()
    /// Something the user asked for couldn't be done.
    func injector(didFail notice: Notice)
}

/// Turns iPhone input into macOS HID-level events.
///
/// Threading: methods are called on `HostEngine`'s input queue (serial, user-interactive), so
/// pointer, click and key events are posted with no extra thread hop. State lives behind `state`'s
/// lock, which also serialises pointer/key posts with the ⌘Tab latch timer and paced typing (both on
/// private queues). Scrolling has its own lock in `ScrollInjector`, which keeps gesture and momentum
/// phases in order; pointer motion interleaving with momentum is fine, as with a real trackpad.
final class InputInjector: @unchecked Sendable {
    /// Text up to this many keystrokes is typed immediately; longer text is paced.
    static let inlineTextLimit = 32
    static let typingChunk = 16
    /// Pause between chunks of long text so slower apps (terminals, Electron) keep up — ~1,000 chars/s.
    static let typingPause: TimeInterval = 0.012
    /// The ⌘Tab switcher stays up this long after the last switcher action, then ⌘ is released and
    /// the selected app comes forward — "tap to cycle, pause to commit".
    static let switcherCommitDelay: TimeInterval = 1.2

    weak var delegate: InputInjectorDelegate?

    private struct State {
        var pressedButtons: Set<MouseButton> = []
        var heldModifierKeys: Set<UInt16> = []
        var pressedKeys: Set<UInt16> = []
        var switcherLatched = false
        var switcherGeneration = 0
        /// Bumped when a session ends (`releaseAll`). Work that was waiting checks it, under this lock,
        /// right before it touches the Mac, so nothing from an ended session runs after the session ends.
        var generation = 0
        /// Operations waiting on `orderedQueue` behind paced typing.
        var queuedOperations = 0
        /// Modifiers paced typing pressed for its text, released by `releaseAll` if the session ends
        /// mid-text.
        var typingModifiers: HeldModifiers?
    }

    private let poster: EventPoster
    private let scroller: ScrollInjector
    private let geometry: DisplayGeometry
    private let layouts: KeyboardLayoutProvider
    private let trust: AccessibilityTrust
    private let power: PowerManager
    private let state = OSAllocatedUnfairLock(initialState: State())
    /// Held by `releaseAll` and by deferred actions while they act (see `ifCurrent`), so a session
    /// can't end midway through one. Taken before `state`, never after.
    private let sessionGate = NSLock()
    private let orderedQueue = DispatchQueue(label: "reach.host.input.ordered", qos: .userInteractive)
    private let timerQueue = DispatchQueue(label: "reach.host.input.timers", qos: .userInteractive)
    private let accessibilityQueue = DispatchQueue(label: "reach.host.input.ax", qos: .userInitiated)
    /// Uptime of the last "needs Accessibility" report; pointer input alone arrives up to 120×/s.
    private let lastAccessibilityReport = OSAllocatedUnfairLock(initialState: -TimeInterval.infinity)

    init(geometry: DisplayGeometry, layouts: KeyboardLayoutProvider, trust: AccessibilityTrust, power: PowerManager) {
        let poster = EventPoster()
        self.poster = poster
        self.scroller = ScrollInjector(poster: poster)
        self.geometry = geometry
        self.layouts = layouts
        self.trust = trust
        self.power = power
    }

    // MARK: - Pointer

    func pointer(_ packet: PointerPacket) {
        guard admit(),
              let target = PointerMapper.globalPoint(normalizedX: Double(packet.x), y: Double(packet.y), in: geometry.frame)
        else { return }
        inOrder { self.move(to: target, &$0) }
    }

    func mouseButton(_ event: MouseButtonEvent) {
        guard admit(),
              let target = PointerMapper.globalPoint(normalizedX: event.x, y: event.y, in: geometry.frame)
        else { return }
        if event.isDown { scroller.cancelMomentum() }
        inOrder { s in
            // Hover first: menus and tracking areas need to see the pointer arrive before the press.
            let current = self.poster.cursorLocation
            if hypot(current.x - target.x, current.y - target.y) > 0.5 { self.move(to: target, &s) }
            if event.isDown, s.pressedButtons.contains(event.button) {
                // A release went missing; resynchronise so the system doesn't see two downs.
                self.postButton(event.button, down: false, at: target, clickCount: 1, modifiers: [], s)
            }
            self.postButton(event.button, down: event.isDown, at: target, clickCount: max(1, event.clickCount),
                            modifiers: event.modifiers, s)
            if event.isDown { s.pressedButtons.insert(event.button) } else { s.pressedButtons.remove(event.button) }
            // Clicking an app in the ⌘Tab switcher picks it, like letting go of ⌘.
            if !event.isDown && s.switcherLatched { self.releaseSwitcher(&s) }
        }
    }

    func scroll(_ event: ScrollEvent) {
        guard admit() else { return }
        inOrder { _ in self.scroller.handle(event) }
    }

    // MARK: - Keyboard

    func key(_ event: KeyEvent) {
        guard admit() else { return }
        inOrder { s in
            self.postKey(event, &s)
            if s.switcherLatched { self.scheduleSwitcherCommit(&s) }
        }
    }

    func keyPress(code: UInt16, modifiers: KeyModifiers) {
        guard admit() else { return }
        inOrder { s in
            self.press(KeyChord(keyCode: code, modifiers: modifiers), &s)
            if s.switcherLatched { self.scheduleSwitcherCommit(&s) }
        }
    }

    func type(_ input: TextInput) {
        guard admit() else { return }
        let steps = TextPlanner.plan(input.text, layout: layouts.current, modifiers: input.modifiers)
        guard !steps.isEmpty else { return }
        if steps.count <= Self.inlineTextLimit {
            inOrder { s in
                let held = self.holdModifiers(input.modifiers, s)
                steps.forEach { self.postStep($0, active: held.active, heldKeys: held.keys) }
                self.releaseModifiers(held)
            }
        } else {
            let generation = state.withLock { $0.generation }
            enqueue { self.typePaced(steps, modifiers: input.modifiers, generation: generation) }
        }
    }

    func media(_ key: MediaKey) {
        guard admit() else { return }
        // Media keys are built as NSEvents, which belong on the main thread. They don't interact with
        // held keys or buttons, so they needn't be ordered with the rest of the input.
        let keyType = Self.auxiliaryKeyType(for: key)
        let generation = self.generation
        onMain { self.ifCurrent(generation) { self.poster.auxiliaryKey(keyType) } }
    }

    // MARK: - System actions

    func perform(_ action: SystemAction) {
        let mechanism = SystemActionResolver.mechanism(for: action)
        if mechanism.needsAccessibility { guard admit() else { return } }
        switch mechanism {
        case .docklet(let app, let argument):
            if !SystemActionRunner.runDocklet(app, argument: argument) {
                delegate?.injector(didFail: Notice(level: .warning, message: "Couldn't open \(app.deletingPathExtension().lastPathComponent)."))
            }
        case .openApplication(let app):
            SystemActionRunner.openApplication(app)
        case .chord(let chord):
            inOrder { self.press(chord, &$0) }
        case .appSwitcher:
            inOrder { self.advanceSwitcher(&$0) }
        case .notificationCenter(let fallback):
            let generation = self.generation
            accessibilityQueue.async {
                // Found outside the gate (it's IPC that can stall), pressed inside it.
                let clock = SystemActionRunner.menuBarClock()
                var pressed = false
                guard self.ifCurrent(generation, { pressed = clock.map(SystemActionRunner.press) ?? false }) else { return }
                guard !pressed else { return }
                if let fallback {
                    self.inOrder(generation: generation) { self.press(fallback, &$0) }
                } else {
                    self.delegate?.injector(didFail: Notice(level: .warning, message: "Couldn't open Notification Center."))
                }
            }
        case .wakeDisplay:
            power.wakeDisplay()
        case .unavailable(let reason):
            delegate?.injector(didFail: Notice(level: .info, message: reason))
        }
    }

    // MARK: - Session lifecycle

    /// The current session generation. Capture it when input arrives and act later through
    /// `ifCurrent`, so an action that was waiting is dropped if the session ended meanwhile.
    var generation: Int { state.withLock { $0.generation } }

    func isCurrent(_ generation: Int) -> Bool { state.withLock { $0.generation == generation } }

    /// Runs `body` if the session is still `generation`, and holds off the session's end until it's
    /// done: once `releaseAll` returns, no such action is midway or still to come. Keep `body` short
    /// (it may block the end of a session), and don't call back into this from it. Returns whether
    /// `body` ran.
    @discardableResult
    func ifCurrent(_ generation: Int, _ body: () -> Void) -> Bool {
        sessionGate.withLock {
            guard isCurrent(generation) else { return false }
            body()
            return true
        }
    }

    /// `ifCurrent` bound to `generation`, for handing to code that acts later on other queues.
    func gate(_ generation: Int) -> @Sendable (() -> Void) -> Bool {
        { [self] body in ifCurrent(generation, body) }
    }

    /// Releases everything Reach is holding down — buttons, keys, modifiers, the ⌘Tab latch — stops
    /// momentum and paced typing, and drops input still waiting. Called as soon as a session ends.
    func releaseAll() {
        sessionGate.lock(); defer { sessionGate.unlock() }
        state.withLock { s in
            s.generation += 1
            // Inside the lock, so a scroll that was waiting can't start momentum again after this.
            scroller.cancelMomentum()
            if let held = s.typingModifiers {
                releaseModifiers(held)
                s.typingModifiers = nil
            }
            let location = poster.cursorLocation
            for button in s.pressedButtons {
                postButton(button, down: false, at: location, clickCount: 1, modifiers: [], s)
            }
            s.pressedButtons.removeAll()
            for code in s.pressedKeys { poster.key(code, down: false, modifiers: heldModifiers(s), heldKeys: heldKeys(s)) }
            s.pressedKeys.removeAll()
            releaseSwitcher(&s)
            for code in s.heldModifierKeys {
                s.heldModifierKeys.remove(code)
                poster.key(code, down: false, modifiers: heldModifiers(s), heldKeys: s.heldModifierKeys)
            }
        }
    }

    // MARK: - Ordering

    private func admit() -> Bool {
        guard trust.isTrusted else {
            let now = uptimeSeconds()
            let report = lastAccessibilityReport.withLock { last -> Bool in
                guard now - last >= 2 else { return false }
                last = now
                return true
            }
            if report { delegate?.injectorNeedsAccessibility() }
            return false
        }
        return true
    }

    /// Runs `work` with the lock held, now — unless paced typing is in progress, in which case it
    /// queues behind it so the Mac sees input in the order the iPhone sent it. Either way it runs only
    /// if the session is still `generation` (default: the current one), checked under the same lock
    /// as `work`'s posts, so `releaseAll` can't slip in between.
    private func inOrder(generation: Int? = nil, _ work: @escaping (inout State) -> Void) {
        let queuedIn = state.withLock { s -> Int? in
            let expected = generation ?? s.generation
            guard s.queuedOperations > 0 else {
                if s.generation == expected { work(&s) }
                return nil
            }
            s.queuedOperations += 1
            return expected
        }
        guard let queuedIn else { return }
        orderedQueue.async {
            self.state.withLock { s in
                if s.generation == queuedIn { work(&s) }
                s.queuedOperations -= 1
            }
        }
    }

    private func enqueue(_ work: @escaping () -> Void) {
        state.withLock { $0.queuedOperations += 1 }
        orderedQueue.async {
            work()
            self.state.withLock { $0.queuedOperations -= 1 }
        }
    }

    // MARK: - Mouse (lock held)

    private func move(to target: CGPoint, _ s: inout State) {
        let (type, button) = Self.motionEvent(for: s.pressedButtons)
        guard let event = poster.mouseEvent(type, at: target, button: button) else { return }
        // Relative deltas matter to apps that read raw motion (games, 3D tools, some drag handlers).
        let origin = poster.cursorLocation
        event.setIntegerValueField(.mouseEventDeltaX, value: Int64((target.x - origin.x).rounded()))
        event.setIntegerValueField(.mouseEventDeltaY, value: Int64((target.y - origin.y).rounded()))
        KeyFlags.apply(heldModifiers(s), heldKeys: heldKeys(s), keyCode: nil, to: event)
        poster.post(event)
    }

    private func postButton(_ button: MouseButton, down: Bool, at point: CGPoint, clickCount: Int,
                            modifiers: KeyModifiers, _ s: State) {
        let type: CGEventType
        let cgButton: CGMouseButton
        switch button {
        case .left: (type, cgButton) = (down ? .leftMouseDown : .leftMouseUp, .left)
        case .right: (type, cgButton) = (down ? .rightMouseDown : .rightMouseUp, .right)
        case .middle: (type, cgButton) = (down ? .otherMouseDown : .otherMouseUp, .center)
        }
        guard let event = poster.mouseEvent(type, at: point, button: cgButton) else { return }
        event.setIntegerValueField(.mouseEventClickState, value: Int64(clickCount))
        KeyFlags.apply(modifiers.union(heldModifiers(s)), heldKeys: heldKeys(s), keyCode: nil, to: event)
        poster.post(event)
    }

    static func motionEvent(for buttons: Set<MouseButton>) -> (CGEventType, CGMouseButton) {
        if buttons.contains(.left) { return (.leftMouseDragged, .left) }
        if buttons.contains(.right) { return (.rightMouseDragged, .right) }
        if buttons.contains(.middle) { return (.otherMouseDragged, .center) }
        return (.mouseMoved, .left)
    }

    // MARK: - Keyboard (lock held)

    private func heldModifiers(_ s: State) -> KeyModifiers {
        var modifiers = KeyFlags.modifiers(ofHeldKeys: s.heldModifierKeys)
        if s.switcherLatched { modifiers.insert(.command) }
        return modifiers
    }

    private func heldKeys(_ s: State) -> Set<UInt16> {
        s.switcherLatched ? s.heldModifierKeys.union([MacKey.command]) : s.heldModifierKeys
    }

    private func postKey(_ event: KeyEvent, _ s: inout State) {
        guard let modifier = MacKey.modifier(for: event.code) else {
            if event.isDown { s.pressedKeys.insert(event.code) } else { s.pressedKeys.remove(event.code) }
            poster.key(event.code, down: event.isDown, modifiers: event.modifiers.union(heldModifiers(s)), heldKeys: heldKeys(s))
            return
        }
        // A modifier key itself: becomes a `flagsChanged` event (CGEvent picks the type from the key code).
        if modifier != .capsLock {
            if event.isDown { s.heldModifierKeys.insert(event.code) } else { s.heldModifierKeys.remove(event.code) }
        }
        var modifiers = event.modifiers.union(heldModifiers(s))
        if event.isDown {
            modifiers.insert(modifier)
        } else if modifier != .capsLock && !heldModifiers(s).contains(modifier) {
            modifiers.remove(modifier)
        }
        poster.key(event.code, down: event.isDown, modifiers: modifiers, heldKeys: heldKeys(s))
    }

    /// Presses a chord the way a person does — modifier keys down, key down and up, modifiers up —
    /// with real `flagsChanged` events, which window-server shortcuts and the ⌘Tab switcher rely on.
    private func press(_ chord: KeyChord, _ s: inout State) {
        let held = holdModifiers(chord.modifiers, s)
        if let modifier = MacKey.modifier(for: chord.keyCode) {
            poster.key(chord.keyCode, down: true, modifiers: held.active.union(modifier), heldKeys: held.keys.union([chord.keyCode]))
            poster.key(chord.keyCode, down: false, modifiers: held.active, heldKeys: held.keys)
        } else {
            poster.key(chord.keyCode, down: true, modifiers: held.active, heldKeys: held.keys)
            poster.key(chord.keyCode, down: false, modifiers: held.active, heldKeys: held.keys)
        }
        releaseModifiers(held)
    }

    private struct HeldModifiers {
        var pressed: [(code: UInt16, modifier: KeyModifiers)]
        var active: KeyModifiers
        var keys: Set<UInt16>
    }

    /// Presses whichever of `modifiers` aren't already down.
    private func holdModifiers(_ modifiers: KeyModifiers, _ s: State) -> HeldModifiers {
        let alreadyHeld = heldModifiers(s)
        var held = HeldModifiers(pressed: KeyFlags.keysToHold(for: modifiers.subtracting(alreadyHeld)),
                                 active: alreadyHeld.union(modifiers.intersection(.capsLock)), keys: heldKeys(s))
        for key in held.pressed {
            held.active.insert(key.modifier)
            held.keys.insert(key.code)
            poster.key(key.code, down: true, modifiers: held.active, heldKeys: held.keys)
        }
        return held
    }

    private func releaseModifiers(_ held: HeldModifiers) {
        var active = held.active
        var keys = held.keys
        for key in held.pressed.reversed() {
            active.remove(key.modifier)
            keys.remove(key.code)
            poster.key(key.code, down: false, modifiers: active, heldKeys: keys)
        }
    }

    private func postStep(_ step: TextStep, active: KeyModifiers, heldKeys: Set<UInt16>) {
        switch step {
        case .key(let stroke, let text):
            let modifiers = active.union(stroke.modifiers)
            // With ⌃ held a hardware event's string is a control character, so only attach text when
            // the active modifiers can't change what the key types.
            let attached = active.isDisjoint(with: [.control, .command]) ? text : nil
            poster.key(stroke.keyCode, down: true, modifiers: modifiers, heldKeys: heldKeys, text: attached)
            poster.key(stroke.keyCode, down: false, modifiers: modifiers, heldKeys: heldKeys, text: attached)
        case .unicode(let text):
            poster.unicode(text)
        }
    }

    /// Long text, typed in chunks on `orderedQueue` with short pauses. Input that arrives meanwhile
    /// queues behind it (see `inOrder`); a session ending bumps `generation` and stops it.
    private func typePaced(_ steps: [TextStep], modifiers: KeyModifiers, generation: Int) {
        guard let held = state.withLock({ s -> HeldModifiers? in
            guard s.generation == generation else { return nil }
            s.typingModifiers = holdModifiers(modifiers, s)
            return s.typingModifiers
        }) else { return }
        var index = 0
        while index < steps.count {
            let chunk = steps[index..<min(steps.count, index + Self.typingChunk)]
            let proceed = state.withLock { s -> Bool in
                guard s.generation == generation else { return false }
                chunk.forEach { postStep($0, active: held.active, heldKeys: held.keys) }
                return true
            }
            guard proceed else { break }
            index = chunk.endIndex
            if index < steps.count { Thread.sleep(forTimeInterval: Self.typingPause) }
        }
        state.withLock { s in
            // If the session ended, `releaseAll` already let go of them.
            guard s.generation == generation else { return }
            releaseModifiers(held)
            s.typingModifiers = nil
        }
    }

    // MARK: - ⌘Tab switcher (lock held)

    private func advanceSwitcher(_ s: inout State) {
        if !s.switcherLatched {
            s.switcherLatched = true
            poster.key(MacKey.command, down: true, modifiers: heldModifiers(s), heldKeys: heldKeys(s))
        }
        poster.key(MacKey.tab, down: true, modifiers: heldModifiers(s), heldKeys: heldKeys(s))
        poster.key(MacKey.tab, down: false, modifiers: heldModifiers(s), heldKeys: heldKeys(s))
        scheduleSwitcherCommit(&s)
    }

    private func scheduleSwitcherCommit(_ s: inout State) {
        s.switcherGeneration += 1
        let generation = s.switcherGeneration
        timerQueue.asyncAfter(deadline: .now() + Self.switcherCommitDelay) { [weak self] in
            guard let self else { return }
            self.state.withLock { s in
                if s.switcherGeneration == generation { self.releaseSwitcher(&s) }
            }
        }
    }

    private func releaseSwitcher(_ s: inout State) {
        guard s.switcherLatched else { return }
        s.switcherLatched = false
        // Keep ⌘ down if the iPhone is separately holding it.
        guard !s.heldModifierKeys.contains(MacKey.command) else { return }
        poster.key(MacKey.command, down: false, modifiers: heldModifiers(s), heldKeys: heldKeys(s))
    }

    // MARK: - Media keys

    /// `NX_KEYTYPE_*` from IOKit/hidsystem/ev_keymap.h.
    static func auxiliaryKeyType(for key: MediaKey) -> Int32 {
        switch key {
        case .volumeUp: return 0 // NX_KEYTYPE_SOUND_UP
        case .volumeDown: return 1 // NX_KEYTYPE_SOUND_DOWN
        case .brightnessUp: return 2 // NX_KEYTYPE_BRIGHTNESS_UP
        case .brightnessDown: return 3 // NX_KEYTYPE_BRIGHTNESS_DOWN
        case .mute: return 7 // NX_KEYTYPE_MUTE
        case .playPause: return 16 // NX_KEYTYPE_PLAY
        case .next: return 17 // NX_KEYTYPE_NEXT
        case .previous: return 18 // NX_KEYTYPE_PREVIOUS
        }
    }
}
