import Foundation
import Observation
import ReachProtocol

/// The ⌃ ⌥ ⌘ ⇧ keys of the accessory bar. Tap arms a modifier for the next key or click; a quick second
/// tap locks it until tapped again. Decided instantly on each tap (no double-tap delay).
@MainActor
@Observable
final class StickyModifiers {
    enum State: Equatable { case off, once, locked }

    nonisolated static let order: [KeyModifiers] = [.control, .option, .command, .shift]

    private(set) var states: [UInt8: State] = [:]
    @ObservationIgnored private var lastTap: [UInt8: TimeInterval] = [:]

    func state(of m: KeyModifiers) -> State { states[m.rawValue] ?? .off }

    var active: KeyModifiers {
        var result: KeyModifiers = []
        for m in Self.order where state(of: m) != .off { result.insert(m) }
        return result
    }

    var isEmpty: Bool { active.isEmpty }

    func tap(_ m: KeyModifiers, now: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        let previous = lastTap[m.rawValue] ?? 0
        lastTap[m.rawValue] = now
        switch state(of: m) {
        case .off: states[m.rawValue] = .once
        case .once: states[m.rawValue] = now - previous < 0.35 ? .locked : .off
        case .locked: states[m.rawValue] = .off
        }
    }

    /// The modifiers to apply to the next key or click; one-shot modifiers are cleared.
    func consume() -> KeyModifiers {
        let result = active
        for m in Self.order where state(of: m) == .once { states[m.rawValue] = .off }
        return result
    }

    func clear() { states.removeAll() }

    nonisolated static func glyph(_ m: KeyModifiers) -> String {
        switch m {
        case .control: return "⌃"
        case .option: return "⌥"
        case .command: return "⌘"
        case .shift: return "⇧"
        default: return "?"
        }
    }

    nonisolated static func name(_ m: KeyModifiers) -> String {
        switch m {
        case .control: return "Control"
        case .option: return "Option"
        case .command: return "Command"
        case .shift: return "Shift"
        default: return "Modifier"
        }
    }

    /// "⌃⌥⇧⌘" in Apple's canonical order.
    nonisolated static func symbols(_ mods: KeyModifiers) -> String {
        var s = ""
        if mods.contains(.control) { s += "⌃" }
        if mods.contains(.option) { s += "⌥" }
        if mods.contains(.shift) { s += "⇧" }
        if mods.contains(.command) { s += "⌘" }
        if mods.contains(.function) { s += "fn " }
        return s
    }
}
