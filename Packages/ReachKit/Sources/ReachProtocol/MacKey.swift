import Foundation

/// macOS virtual key codes (`kVK_*` from Carbon's Events.h). These identify physical key positions,
/// independent of the active keyboard layout.
public enum MacKey {
    public static let a: UInt16 = 0x00, s: UInt16 = 0x01, d: UInt16 = 0x02, f: UInt16 = 0x03
    public static let h: UInt16 = 0x04, g: UInt16 = 0x05, z: UInt16 = 0x06, x: UInt16 = 0x07
    public static let c: UInt16 = 0x08, v: UInt16 = 0x09, isoSection: UInt16 = 0x0A, b: UInt16 = 0x0B
    public static let q: UInt16 = 0x0C, w: UInt16 = 0x0D, e: UInt16 = 0x0E, r: UInt16 = 0x0F
    public static let y: UInt16 = 0x10, t: UInt16 = 0x11
    public static let digit1: UInt16 = 0x12, digit2: UInt16 = 0x13, digit3: UInt16 = 0x14, digit4: UInt16 = 0x15
    public static let digit6: UInt16 = 0x16, digit5: UInt16 = 0x17, equal: UInt16 = 0x18, digit9: UInt16 = 0x19
    public static let digit7: UInt16 = 0x1A, minus: UInt16 = 0x1B, digit8: UInt16 = 0x1C, digit0: UInt16 = 0x1D
    public static let rightBracket: UInt16 = 0x1E, o: UInt16 = 0x1F, u: UInt16 = 0x20, leftBracket: UInt16 = 0x21
    public static let i: UInt16 = 0x22, p: UInt16 = 0x23, returnKey: UInt16 = 0x24, l: UInt16 = 0x25
    public static let j: UInt16 = 0x26, quote: UInt16 = 0x27, k: UInt16 = 0x28, semicolon: UInt16 = 0x29
    public static let backslash: UInt16 = 0x2A, comma: UInt16 = 0x2B, slash: UInt16 = 0x2C, n: UInt16 = 0x2D
    public static let m: UInt16 = 0x2E, period: UInt16 = 0x2F, tab: UInt16 = 0x30, space: UInt16 = 0x31
    public static let grave: UInt16 = 0x32, delete: UInt16 = 0x33, escape: UInt16 = 0x35
    public static let rightCommand: UInt16 = 0x36, command: UInt16 = 0x37, shift: UInt16 = 0x38
    public static let capsLock: UInt16 = 0x39, option: UInt16 = 0x3A, control: UInt16 = 0x3B
    public static let rightShift: UInt16 = 0x3C, rightOption: UInt16 = 0x3D, rightControl: UInt16 = 0x3E
    public static let function: UInt16 = 0x3F
    public static let f17: UInt16 = 0x40, keypadDecimal: UInt16 = 0x41, keypadMultiply: UInt16 = 0x43
    public static let keypadPlus: UInt16 = 0x45, keypadClear: UInt16 = 0x47
    public static let volumeUp: UInt16 = 0x48, volumeDown: UInt16 = 0x49, mute: UInt16 = 0x4A
    public static let keypadDivide: UInt16 = 0x4B, keypadEnter: UInt16 = 0x4C, keypadMinus: UInt16 = 0x4E
    public static let f18: UInt16 = 0x4F, f19: UInt16 = 0x50, keypadEquals: UInt16 = 0x51
    public static let keypad0: UInt16 = 0x52, keypad1: UInt16 = 0x53, keypad2: UInt16 = 0x54, keypad3: UInt16 = 0x55
    public static let keypad4: UInt16 = 0x56, keypad5: UInt16 = 0x57, keypad6: UInt16 = 0x58, keypad7: UInt16 = 0x59
    public static let f20: UInt16 = 0x5A, keypad8: UInt16 = 0x5B, keypad9: UInt16 = 0x5C
    public static let jisYen: UInt16 = 0x5D, jisUnderscore: UInt16 = 0x5E, jisKeypadComma: UInt16 = 0x5F
    public static let f5: UInt16 = 0x60, f6: UInt16 = 0x61, f7: UInt16 = 0x62, f3: UInt16 = 0x63
    public static let f8: UInt16 = 0x64, f9: UInt16 = 0x65, jisEisu: UInt16 = 0x66, f11: UInt16 = 0x67
    public static let jisKana: UInt16 = 0x68, f13: UInt16 = 0x69, f16: UInt16 = 0x6A, f14: UInt16 = 0x6B
    public static let f10: UInt16 = 0x6D, f12: UInt16 = 0x6F, f15: UInt16 = 0x71, help: UInt16 = 0x72
    public static let home: UInt16 = 0x73, pageUp: UInt16 = 0x74, forwardDelete: UInt16 = 0x75, f4: UInt16 = 0x76
    public static let end: UInt16 = 0x77, f2: UInt16 = 0x78, pageDown: UInt16 = 0x79, f1: UInt16 = 0x7A
    public static let leftArrow: UInt16 = 0x7B, rightArrow: UInt16 = 0x7C, downArrow: UInt16 = 0x7D, upArrow: UInt16 = 0x7E

    public static let functionKeys: [UInt16] = [f1, f2, f3, f4, f5, f6, f7, f8, f9, f10, f11, f12,
                                                f13, f14, f15, f16, f17, f18, f19, f20]

    /// Key codes that are modifier keys themselves.
    public static let modifierKeys: Set<UInt16> = [command, rightCommand, shift, rightShift, option, rightOption,
                                                   control, rightControl, function, capsLock]

    /// The modifier flag a modifier key code contributes, if any.
    public static func modifier(for code: UInt16) -> KeyModifiers? {
        switch code {
        case command, rightCommand: return .command
        case shift, rightShift: return .shift
        case option, rightOption: return .option
        case control, rightControl: return .control
        case function: return .function
        case capsLock: return .capsLock
        default: return nil
        }
    }

    /// Maps a USB HID keyboard usage (what `UIKey.keyCode` reports on iOS) to a Mac virtual key code.
    public static func fromHIDUsage(_ usage: Int) -> UInt16? {
        hidTable[usage]
    }

    private static let hidTable: [Int: UInt16] = {
        var map: [Int: UInt16] = [:]
        // Letters a...z (HID 0x04...0x1D)
        let letters: [UInt16] = [a, b, c, d, e, f, g, h, i, j, k, l, m, n, o, p, q, r, s, t, u, v, w, x, y, z]
        for (idx, code) in letters.enumerated() { map[0x04 + idx] = code }
        // Digits 1...9, 0 (HID 0x1E...0x27)
        let digits: [UInt16] = [digit1, digit2, digit3, digit4, digit5, digit6, digit7, digit8, digit9, digit0]
        for (idx, code) in digits.enumerated() { map[0x1E + idx] = code }
        map[0x28] = returnKey; map[0x29] = escape; map[0x2A] = delete; map[0x2B] = tab; map[0x2C] = space
        map[0x2D] = minus; map[0x2E] = equal; map[0x2F] = leftBracket; map[0x30] = rightBracket
        map[0x31] = backslash; map[0x32] = backslash; map[0x33] = semicolon; map[0x34] = quote
        map[0x35] = grave; map[0x36] = comma; map[0x37] = period; map[0x38] = slash; map[0x39] = capsLock
        // F1...F12 (HID 0x3A...0x45)
        for (idx, code) in functionKeys.prefix(12).enumerated() { map[0x3A + idx] = code }
        map[0x46] = f13; map[0x47] = f14; map[0x48] = f15 // PrintScreen/ScrollLock/Pause → F13–F15 like Apple keyboards
        map[0x49] = help; map[0x4A] = home; map[0x4B] = pageUp; map[0x4C] = forwardDelete; map[0x4D] = end
        map[0x4E] = pageDown; map[0x4F] = rightArrow; map[0x50] = leftArrow; map[0x51] = downArrow; map[0x52] = upArrow
        map[0x53] = keypadClear; map[0x54] = keypadDivide; map[0x55] = keypadMultiply; map[0x56] = keypadMinus
        map[0x57] = keypadPlus; map[0x58] = keypadEnter
        let keypad: [UInt16] = [keypad1, keypad2, keypad3, keypad4, keypad5, keypad6, keypad7, keypad8, keypad9, keypad0]
        for (idx, code) in keypad.enumerated() { map[0x59 + idx] = code }
        map[0x63] = keypadDecimal; map[0x64] = isoSection; map[0x67] = keypadEquals
        // F13...F20 (HID 0x68...0x6F)
        for (idx, code) in functionKeys[12..<20].enumerated() { map[0x68 + idx] = code }
        map[0x7F] = mute; map[0x80] = volumeUp; map[0x81] = volumeDown
        map[0x85] = jisKeypadComma; map[0x87] = jisUnderscore; map[0x89] = jisYen
        map[0x90] = jisKana; map[0x91] = jisEisu
        map[0xE0] = control; map[0xE1] = shift; map[0xE2] = option; map[0xE3] = command
        map[0xE4] = rightControl; map[0xE5] = rightShift; map[0xE6] = rightOption; map[0xE7] = rightCommand
        return map
    }()
}
