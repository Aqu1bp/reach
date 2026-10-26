import Foundation
import ReachProtocol

/// A key plus the modifiers held while pressing it.
struct KeyChord: Equatable {
    var keyCode: UInt16
    var modifiers: KeyModifiers
}

/// System-wide shortcuts from System Settings → Keyboard → Keyboard Shortcuts.
///
/// Reading the user's actual bindings (instead of hard-coding ⌘Space, ⌃→ …) keeps actions working
/// when someone has remapped them. The ids and the `AppleSymbolicHotKeys` layout are not public API
/// but have been stable for many macOS releases; when an entry is missing the macOS default applies,
/// and when it can't be parsed we fall back to that default too.
enum SymbolicHotKey: Int, CaseIterable {
    case missionControl = 32
    case applicationWindows = 33
    case showDesktop = 36
    case spotlight = 64
    case previousSpace = 79
    case nextSpace = 81
    case notificationCenter = 163
    case screenshotOptions = 184

    /// The macOS default binding, or `nil` when the shortcut has no default (it's off until the user sets one).
    var defaultChord: KeyChord? {
        switch self {
        case .missionControl: return KeyChord(keyCode: MacKey.upArrow, modifiers: .control)
        case .applicationWindows: return KeyChord(keyCode: MacKey.downArrow, modifiers: .control)
        case .showDesktop: return KeyChord(keyCode: MacKey.f11, modifiers: [])
        case .spotlight: return KeyChord(keyCode: MacKey.space, modifiers: .command)
        case .previousSpace: return KeyChord(keyCode: MacKey.leftArrow, modifiers: .control)
        case .nextSpace: return KeyChord(keyCode: MacKey.rightArrow, modifiers: .control)
        case .notificationCenter: return nil
        case .screenshotOptions: return KeyChord(keyCode: MacKey.digit5, modifiers: [.shift, .command])
        }
    }
}

enum SymbolicHotKeys {
    static let domain = "com.apple.symbolichotkeys" as CFString
    static let key = "AppleSymbolicHotKeys" as CFString

    /// The binding currently in effect, or `nil` if the user turned the shortcut off.
    static func current(_ hotKey: SymbolicHotKey) -> KeyChord? {
        let table = CFPreferencesCopyAppValue(key, domain) as? [String: Any]
        return resolve(hotKey, in: table)
    }

    /// Pure resolution against an `AppleSymbolicHotKeys` dictionary (exposed for self-tests).
    static func resolve(_ hotKey: SymbolicHotKey, in table: [String: Any]?) -> KeyChord? {
        guard let entry = table?[String(hotKey.rawValue)] as? [String: Any] else { return hotKey.defaultChord }
        if let enabled = entry["enabled"] as? Bool, !enabled { return nil }
        guard let value = entry["value"] as? [String: Any],
              let parameters = value["parameters"] as? [Any], parameters.count >= 3,
              let keyCode = integer(parameters[1]), let mask = integer(parameters[2]),
              keyCode >= 0, keyCode < 0xFFFF else { return hotKey.defaultChord }
        let code = UInt16(keyCode)
        return KeyChord(keyCode: code, modifiers: modifiers(fromEventMask: mask, keyCode: code))
    }

    /// Converts an NSEvent modifier mask as stored in the preferences. Fn and NumericPad are dropped
    /// for keys that carry them intrinsically (arrows, F-keys) — pressing the Fn key itself would be wrong.
    static func modifiers(fromEventMask mask: Int, keyCode: UInt16) -> KeyModifiers {
        var result: KeyModifiers = []
        if mask & (1 << 17) != 0 { result.insert(.shift) }
        if mask & (1 << 18) != 0 { result.insert(.control) }
        if mask & (1 << 19) != 0 { result.insert(.option) }
        if mask & (1 << 20) != 0 { result.insert(.command) }
        if mask & (1 << 23) != 0, KeyFlags.intrinsicFlags(forKeyCode: keyCode).isEmpty { result.insert(.function) }
        return result
    }

    private static func integer(_ value: Any) -> Int? {
        if let number = value as? NSNumber { return number.intValue }
        return value as? Int
    }
}
