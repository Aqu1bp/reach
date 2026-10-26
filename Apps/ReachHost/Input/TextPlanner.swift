import ReachProtocol

/// One unit of typed text.
enum TextStep: Equatable {
    /// A physical key on the current layout, and the text it types.
    case key(KeyStroke, text: String)
    /// One grapheme cluster posted as a Unicode keyboard event (emoji, accented letters reachable only
    /// through dead keys, characters the layout doesn't have).
    case unicode(String)
}

/// Turns text from the iPhone into keystrokes for the Mac's current keyboard layout.
enum TextPlanner {
    static func plan(_ text: String, layout: KeyboardLayoutMap?, modifiers: KeyModifiers = []) -> [TextStep] {
        var steps: [TextStep] = []
        steps.reserveCapacity(text.count)
        let isShortcut = !modifiers.subtracting(.capsLock).isEmpty
        for character in text {
            switch character {
            case "\n", "\r", "\r\n":
                steps.append(.key(KeyStroke(keyCode: MacKey.returnKey, modifiers: []), text: "\r"))
            case "\t":
                steps.append(.key(KeyStroke(keyCode: MacKey.tab, modifiers: []), text: "\t"))
            default:
                if let step = keyStep(for: character, layout: layout, isShortcut: isShortcut) {
                    steps.append(step)
                } else if !character.unicodeScalars.allSatisfy({ $0.properties.generalCategory == .control }) {
                    steps.append(.unicode(String(character)))
                }
            }
        }
        return steps
    }

    private static func keyStep(for character: Character, layout: KeyboardLayoutMap?, isShortcut: Bool) -> TextStep? {
        guard let layout else { return nil }
        // An input method would compose plain key events (e.g. romaji → kana), so only shortcuts use keys.
        if layout.inputMethodActive && !isShortcut { return nil }
        if let stroke = layout.stroke(for: character) { return .key(stroke, text: String(character)) }
        // ⌘ + "É" should still reach the É key's base letter if the layout lacks a direct stroke.
        if isShortcut, let lower = character.lowercased().first, let stroke = layout.stroke(for: lower) {
            return .key(stroke, text: String(lower))
        }
        return nil
    }
}
