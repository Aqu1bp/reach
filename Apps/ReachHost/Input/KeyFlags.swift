import CoreGraphics
import ReachProtocol

/// Maps protocol modifiers to the `CGEventFlags` a real keyboard produces.
enum KeyFlags {
    /// Device-dependent bits (IOLLEvent.h `NX_DEVICE*KEYMASK`). Hardware events set them next to the
    /// generic masks, and some apps use them to tell left from right modifiers.
    enum Device {
        static let leftControl: UInt64 = 0x0000_0001
        static let leftShift: UInt64 = 0x0000_0002
        static let rightShift: UInt64 = 0x0000_0004
        static let leftCommand: UInt64 = 0x0000_0008
        static let rightCommand: UInt64 = 0x0000_0010
        static let leftOption: UInt64 = 0x0000_0020
        static let rightOption: UInt64 = 0x0000_0040
        static let rightControl: UInt64 = 0x0000_2000
        static let all: UInt64 = 0x0000_207F
    }

    /// Bits this app owns on every posted event; everything else the event was created with is kept.
    static let ownedBits: UInt64 = CGEventFlags.maskShift.rawValue | CGEventFlags.maskControl.rawValue
        | CGEventFlags.maskAlternate.rawValue | CGEventFlags.maskCommand.rawValue
        | CGEventFlags.maskAlphaShift.rawValue | CGEventFlags.maskSecondaryFn.rawValue
        | CGEventFlags.maskNumericPad.rawValue | Device.all

    /// Flags for `modifiers`. `heldKeys` (modifier key codes currently down) selects left/right
    /// device bits; a modifier with no held key reports as the left-hand key.
    static func flags(for modifiers: KeyModifiers, heldKeys: Set<UInt16> = []) -> CGEventFlags {
        var raw: UInt64 = 0
        func add(_ mask: CGEventFlags, left: UInt64, right: UInt64, rightKey: UInt16, leftKey: UInt16) {
            raw |= mask.rawValue
            let rightHeld = heldKeys.contains(rightKey)
            if rightHeld { raw |= right }
            if !rightHeld || heldKeys.contains(leftKey) { raw |= left }
        }
        if modifiers.contains(.shift) {
            add(.maskShift, left: Device.leftShift, right: Device.rightShift, rightKey: MacKey.rightShift, leftKey: MacKey.shift)
        }
        if modifiers.contains(.control) {
            add(.maskControl, left: Device.leftControl, right: Device.rightControl, rightKey: MacKey.rightControl, leftKey: MacKey.control)
        }
        if modifiers.contains(.option) {
            add(.maskAlternate, left: Device.leftOption, right: Device.rightOption, rightKey: MacKey.rightOption, leftKey: MacKey.option)
        }
        if modifiers.contains(.command) {
            add(.maskCommand, left: Device.leftCommand, right: Device.rightCommand, rightKey: MacKey.rightCommand, leftKey: MacKey.command)
        }
        if modifiers.contains(.function) { raw |= CGEventFlags.maskSecondaryFn.rawValue }
        if modifiers.contains(.capsLock) { raw |= CGEventFlags.maskAlphaShift.rawValue }
        return CGEventFlags(rawValue: raw)
    }

    /// Flags real hardware always sets for a key, regardless of modifiers. NSEvent.h documents Fn for
    /// the F-keys and navigation keys, and NumericPad for the keypad and the arrow keys. Shortcut
    /// matching (e.g. ⌃→ for "Move right a space") compares against these, so they must be present.
    static func intrinsicFlags(forKeyCode code: UInt16) -> CGEventFlags {
        if arrowKeys.contains(code) { return [.maskSecondaryFn, .maskNumericPad] }
        if functionAndNavigationKeys.contains(code) { return .maskSecondaryFn }
        if keypadKeys.contains(code) { return .maskNumericPad }
        return []
    }

    /// Replaces the modifier state on `event` with exactly `modifiers` (plus the key's intrinsic flags).
    static func apply(_ modifiers: KeyModifiers, heldKeys: Set<UInt16> = [], keyCode: UInt16?, to event: CGEvent) {
        var raw = event.flags.rawValue & ~ownedBits
        raw |= flags(for: modifiers, heldKeys: heldKeys).rawValue
        if let keyCode { raw |= intrinsicFlags(forKeyCode: keyCode).rawValue }
        event.flags = CGEventFlags(rawValue: raw)
    }

    /// Modifier keys to hold for `modifiers`, in the order a person presses them. Caps Lock is a
    /// toggle, not a held key, so it is expressed only as a flag.
    static func keysToHold(for modifiers: KeyModifiers) -> [(code: UInt16, modifier: KeyModifiers)] {
        var keys: [(UInt16, KeyModifiers)] = []
        if modifiers.contains(.control) { keys.append((MacKey.control, .control)) }
        if modifiers.contains(.option) { keys.append((MacKey.option, .option)) }
        if modifiers.contains(.shift) { keys.append((MacKey.shift, .shift)) }
        if modifiers.contains(.command) { keys.append((MacKey.command, .command)) }
        if modifiers.contains(.function) { keys.append((MacKey.function, .function)) }
        return keys
    }

    /// Modifiers contributed by a set of held modifier key codes.
    static func modifiers(ofHeldKeys keys: Set<UInt16>) -> KeyModifiers {
        keys.reduce(into: KeyModifiers()) { result, code in
            if let modifier = MacKey.modifier(for: code), modifier != .capsLock { result.insert(modifier) }
        }
    }

    private static let arrowKeys: Set<UInt16> = [MacKey.leftArrow, MacKey.rightArrow, MacKey.upArrow, MacKey.downArrow]
    private static let functionAndNavigationKeys: Set<UInt16> = Set(MacKey.functionKeys).union([
        MacKey.home, MacKey.end, MacKey.pageUp, MacKey.pageDown, MacKey.forwardDelete, MacKey.help,
    ])
    private static let keypadKeys: Set<UInt16> = [
        MacKey.keypad0, MacKey.keypad1, MacKey.keypad2, MacKey.keypad3, MacKey.keypad4, MacKey.keypad5,
        MacKey.keypad6, MacKey.keypad7, MacKey.keypad8, MacKey.keypad9, MacKey.keypadDecimal,
        MacKey.keypadMultiply, MacKey.keypadPlus, MacKey.keypadClear, MacKey.keypadDivide,
        MacKey.keypadEnter, MacKey.keypadMinus, MacKey.keypadEquals,
    ]
}
