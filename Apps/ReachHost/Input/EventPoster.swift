import AppKit
import ReachProtocol

/// Creates and posts HID-level events from a single event source, so the system treats them like
/// input from a real mouse and keyboard (they reset the idle timer, drive hot corners, reach the
/// window server's shortcut matching, and so on). Thread-safe: `CGEventPost` may be called from any
/// thread; callers serialize ordering themselves.
final class EventPoster: @unchecked Sendable {
    /// Stamped into `kCGEventSourceUserData` so Reach's own events are recognisable when debugging.
    static let userDataTag: Int64 = 0x5245_4143_48 // "REACH"

    let source: CGEventSource?

    init() {
        source = CGEventSource(stateID: .hidSystemState)
        // By default the system ignores the Mac's own mouse and keyboard for 0.25 s after every
        // synthetic event. Turn that off so someone at the Mac can still use it during a session.
        source?.localEventsSuppressionInterval = 0
        source?.userData = Self.userDataTag
    }

    func post(_ event: CGEvent) {
        event.post(tap: .cghidEventTap)
    }

    /// The real cursor position in global points (reads shared memory; ~0.1 µs).
    var cursorLocation: CGPoint {
        CGEvent(source: nil)?.location ?? .zero
    }

    // MARK: Mouse

    func mouseEvent(_ type: CGEventType, at point: CGPoint, button: CGMouseButton) -> CGEvent? {
        CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: point, mouseButton: button)
    }

    // MARK: Keyboard

    /// Posts a key (or, for modifier key codes, a `flagsChanged`) event with exactly `modifiers` set.
    ///
    /// `text` is attached as the event's Unicode string when known. CGEvent computes that string when
    /// the event is created — before our flags are applied — so a shifted "a" would otherwise still
    /// carry "a" (AppKit recomputes `NSEvent.characters` from key code + flags, but not every
    /// consumer goes through AppKit).
    func key(_ code: UInt16, down: Bool, modifiers: KeyModifiers, heldKeys: Set<UInt16> = [], text: String? = nil) {
        guard let event = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: down) else { return }
        KeyFlags.apply(modifiers, heldKeys: heldKeys, keyCode: code, to: event)
        if let text {
            let units = Array(text.utf16)
            event.keyboardSetUnicodeString(stringLength: units.count, unicodeString: units)
        }
        post(event)
    }

    /// Types `text` (one grapheme) as a Unicode keyboard event. Modifiers are cleared so a held ⌘
    /// can't turn literal text into a shortcut.
    func unicode(_ text: String) {
        let units = Array(text.utf16)
        guard !units.isEmpty else { return }
        for down in [true, false] {
            // Key code 0 is the usual carrier for Unicode events; apps that honour the attached
            // string (nearly all Cocoa and web text fields) insert exactly `text`.
            guard let event = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: down) else { continue }
            KeyFlags.apply([], keyCode: nil, to: event)
            event.keyboardSetUnicodeString(stringLength: units.count, unicodeString: units)
            post(event)
        }
    }

    // MARK: Scroll

    /// A pixel-unit, continuous (trackpad-style) scroll event. Positive `dy` moves content down.
    func scroll(dx: Int32, dy: Int32, phase: CGScrollPhase?, momentum: CGMomentumScrollPhase) {
        guard let event = CGEvent(scrollWheelEvent2Source: source, units: .pixel, wheelCount: 2,
                                  wheel1: dy, wheel2: dx, wheel3: 0) else { return }
        event.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
        event.setIntegerValueField(.scrollWheelEventScrollPhase, value: Int64(phase?.rawValue ?? 0))
        event.setIntegerValueField(.scrollWheelEventMomentumPhase, value: Int64(momentum.rawValue))
        post(event)
    }

    // MARK: System-defined (media keys)

    /// Posts an `NX_SYSDEFINED` / `NX_SUBTYPE_AUX_CONTROL_BUTTONS` key press — what the volume,
    /// brightness and playback keys on Apple keyboards send.
    func auxiliaryKey(_ keyType: Int32) {
        let subtypeAuxControlButtons: Int16 = 8 // IOLLEvent.h NX_SUBTYPE_AUX_CONTROL_BUTTONS
        let keyDown = 0xA, keyUp = 0xB // IOLLEvent.h NX_KEYDOWN / NX_KEYUP
        for state in [keyDown, keyUp] {
            let event = NSEvent.otherEvent(with: .systemDefined, location: .zero,
                                           modifierFlags: NSEvent.ModifierFlags(rawValue: UInt(state << 8)),
                                           timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: 0,
                                           context: nil, subtype: subtypeAuxControlButtons,
                                           data1: (Int(keyType) << 16) | (state << 8), data2: -1)
            if let cgEvent = event?.cgEvent { post(cgEvent) }
        }
    }
}
