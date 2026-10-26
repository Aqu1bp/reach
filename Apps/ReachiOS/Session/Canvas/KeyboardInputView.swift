import UIKit
import ReachProtocol

/// Invisible first responder that brings up the system keyboard and forwards every keystroke straight
/// to the Mac. All text "smarts" are off: the Mac app being typed into owns autocorrect, capitalisation
/// and punctuation, and iOS rewriting characters after the fact can't be undone remotely.
final class KeyboardInputView: UIView, UIKeyInput {
    var onText: ((String) -> Void)?
    var onDelete: (() -> Void)?
    var onReturn: (() -> Void)?
    /// Hardware keyboard presses. Return true if handled.
    var onPress: ((UIPress, Bool) -> Bool)?

    // UITextInputTraits
    var autocorrectionType: UITextAutocorrectionType = .no
    var autocapitalizationType: UITextAutocapitalizationType = .none
    var spellCheckingType: UITextSpellCheckingType = .no
    var smartQuotesType: UITextSmartQuotesType = .no
    var smartDashesType: UITextSmartDashesType = .no
    var smartInsertDeleteType: UITextSmartInsertDeleteType = .no
    var inlinePredictionType: UITextInlinePredictionType = .no
    var keyboardType: UIKeyboardType = .default
    var keyboardAppearance: UIKeyboardAppearance = .dark
    var returnKeyType: UIReturnKeyType = .default
    var enablesReturnKeyAutomatically = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        isAccessibilityElement = false
        // No shortcuts bar on iPad: the glass accessory bar provides Mac-specific keys instead.
        inputAssistantItem.leadingBarButtonGroups = []
        inputAssistantItem.trailingBarButtonGroups = []
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var canBecomeFirstResponder: Bool { true }

    /// No three-finger undo/redo/copy/paste editing gestures — three-finger swipes belong to the Mac.
    override var editingInteractionConfiguration: UIEditingInteractionConfiguration { .none }

    /// Always "has text" so Delete is delivered even though nothing is stored locally.
    var hasText: Bool { true }

    func insertText(_ text: String) {
        if text == "\n" || text == "\r" {
            onReturn?()
        } else {
            onText?(text)
        }
    }

    func deleteBackward() { onDelete?() }

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        let unhandled = presses.filter { !(onPress?($0, true) ?? false) }
        if !unhandled.isEmpty { super.pressesBegan(unhandled, with: event) }
    }

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        let unhandled = presses.filter { !(onPress?($0, false) ?? false) }
        if !unhandled.isEmpty { super.pressesEnded(unhandled, with: event) }
    }

    override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        let unhandled = presses.filter { !(onPress?($0, false) ?? false) }
        if !unhandled.isEmpty { super.pressesCancelled(unhandled, with: event) }
    }
}

/// Hardware keyboard → Mac key events (USB HID usage → macOS virtual key code).
enum HardwareKeys {
    static func macKey(for press: UIPress) -> (code: UInt16, modifiers: KeyModifiers)? {
        guard let key = press.key, let code = MacKey.fromHIDUsage(key.keyCode.rawValue) else { return nil }
        return (code, modifiers(from: key.modifierFlags))
    }

    static func modifiers(from flags: UIKeyModifierFlags) -> KeyModifiers {
        var m: KeyModifiers = []
        if flags.contains(.shift) { m.insert(.shift) }
        if flags.contains(.control) { m.insert(.control) }
        if flags.contains(.alternate) { m.insert(.option) }
        if flags.contains(.command) { m.insert(.command) }
        if flags.contains(.alphaShift) { m.insert(.capsLock) }
        return m
    }
}
