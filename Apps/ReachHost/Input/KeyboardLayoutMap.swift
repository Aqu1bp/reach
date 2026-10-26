import Carbon
import ReachProtocol

/// A physical key plus the modifiers that make it type a particular character.
struct KeyStroke: Hashable {
    var keyCode: UInt16
    var modifiers: KeyModifiers
}

/// Reverse map from characters to the keystrokes that type them on one keyboard layout.
///
/// Typing real key events (instead of Unicode-string events) works in every app, including those
/// that ignore the attached string and translate key codes themselves (terminals, games, VMs,
/// remote-desktop clients), and makes shortcuts like sticky ⌘ + "s" hit the right key on AZERTY,
/// Dvorak, etc. Characters the layout can't produce — or only via dead keys — are left out and get
/// typed as Unicode strings instead.
struct KeyboardLayoutMap {
    /// Modifier combinations tried, cheapest first, so "a" never maps to an Option variant.
    static let modifierCombinations: [KeyModifiers] = [[], [.shift], [.option], [.shift, .option]]

    /// Keys that produce text: the main block first (so digits come from the top row), then the
    /// keypad as a last resort. Return, Tab and the like are handled explicitly by the text planner.
    static let textKeyCodes: [UInt16] = {
        let excluded: Set<UInt16> = [MacKey.returnKey, MacKey.tab]
        let mainBlock = (UInt16(0x00)...UInt16(0x32)).filter { !excluded.contains($0) }
            + [MacKey.jisYen, MacKey.jisUnderscore]
        let keypad: [UInt16] = [
            MacKey.keypad0, MacKey.keypad1, MacKey.keypad2, MacKey.keypad3, MacKey.keypad4, MacKey.keypad5,
            MacKey.keypad6, MacKey.keypad7, MacKey.keypad8, MacKey.keypad9, MacKey.keypadDecimal,
            MacKey.keypadMultiply, MacKey.keypadPlus, MacKey.keypadDivide, MacKey.keypadMinus,
            MacKey.keypadEquals, MacKey.jisKeypadComma,
        ]
        return mainBlock + keypad
    }()

    let layoutName: String
    /// True when an input method (e.g. Japanese, Chinese) rather than a plain layout is selected. Key
    /// events would then be composed by the input method, so plain text goes as Unicode instead.
    let inputMethodActive: Bool
    private(set) var strokes: [Character: KeyStroke] = [:]

    /// `translate(keyCode, modifiers)` returns what the key types, or `nil` for nothing / a dead key.
    init(layoutName: String, inputMethodActive: Bool = false, translate: (UInt16, KeyModifiers) -> String?) {
        self.layoutName = layoutName
        self.inputMethodActive = inputMethodActive
        for modifiers in Self.modifierCombinations {
            for code in Self.textKeyCodes {
                guard let output = translate(code, modifiers), output.count == 1, let character = output.first,
                      strokes[character] == nil, !Self.isControl(character) else { continue }
                strokes[character] = KeyStroke(keyCode: code, modifiers: modifiers)
            }
        }
    }

    func stroke(for character: Character) -> KeyStroke? { strokes[character] }

    var count: Int { strokes.count }

    private static func isControl(_ character: Character) -> Bool {
        character.unicodeScalars.allSatisfy { $0.properties.generalCategory == .control }
    }
}

// MARK: - Current layout (Text Input Sources)

extension KeyboardLayoutMap {
    /// Builds the map for the keyboard layout currently selected on this Mac. Call on the main thread
    /// (Text Input Source APIs are main-thread-only on recent macOS).
    static func current() -> KeyboardLayoutMap? {
        let candidates = [TISCopyCurrentKeyboardLayoutInputSource(), TISCopyCurrentASCIICapableKeyboardLayoutInputSource()]
        for unmanaged in candidates {
            guard let unmanaged else { continue }
            let source = unmanaged.takeRetainedValue()
            guard let rawData = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { continue }
            let layoutData = Unmanaged<CFData>.fromOpaque(rawData).takeUnretainedValue() as Data
            let name = stringProperty(source, kTISPropertyLocalizedName) ?? "Keyboard"
            return make(layoutData: layoutData, name: name, inputMethodActive: isInputMethodSelected())
        }
        return nil
    }

    private static func make(layoutData: Data, name: String, inputMethodActive: Bool) -> KeyboardLayoutMap? {
        let keyboardType = UInt32(LMGetKbdType())
        return layoutData.withUnsafeBytes { raw -> KeyboardLayoutMap? in
            guard let layout = raw.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else { return nil }
            return KeyboardLayoutMap(layoutName: name, inputMethodActive: inputMethodActive) { code, modifiers in
                var deadKeyState: UInt32 = 0
                var length = 0
                var characters = [UniChar](repeating: 0, count: 8)
                // Dead keys stay active (no kUCKeyTranslateNoDeadKeysBit): a dead key then reports zero
                // length, which correctly excludes it — pressing it alone wouldn't type anything.
                let status = UCKeyTranslate(layout, code, UInt16(kUCKeyActionDown), carbonModifierState(modifiers),
                                            keyboardType, 0, &deadKeyState, characters.count, &length, &characters)
                guard status == noErr, length > 0 else { return nil }
                return String(utf16CodeUnits: characters, count: length)
            }
        }
    }

    /// UCKeyTranslate takes Carbon modifier bits shifted right by 8.
    private static func carbonModifierState(_ modifiers: KeyModifiers) -> UInt32 {
        var state = 0
        if modifiers.contains(.shift) { state |= shiftKey }
        if modifiers.contains(.option) { state |= optionKey }
        return UInt32((state >> 8) & 0xFF)
    }

    private static func isInputMethodSelected() -> Bool {
        guard let unmanaged = TISCopyCurrentKeyboardInputSource() else { return false }
        let source = unmanaged.takeRetainedValue()
        guard let type = stringProperty(source, kTISPropertyInputSourceType) else { return false }
        return type == (kTISTypeKeyboardInputMode as String) || type == (kTISTypeKeyboardInputMethodModeEnabled as String)
    }

    private static func stringProperty(_ source: TISInputSource, _ key: CFString) -> String? {
        guard let raw = TISGetInputSourceProperty(source, key) else { return nil }
        return Unmanaged<CFString>.fromOpaque(raw).takeUnretainedValue() as String
    }
}
