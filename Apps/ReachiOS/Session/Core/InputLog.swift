import Foundation
import Observation
import os
import ReachProtocol

/// Records every input message the session sends — its kind only to the unified log (category
/// `input`; never what was typed or which keys), and in full to an on-screen overlay, when enabled,
/// used to verify gestures.
@MainActor
@Observable
final class InputLog {
    struct Entry: Identifiable, Equatable {
        let id: Int
        var text: String
        var count: Int
        var isPointer: Bool
    }

    var isVisible: Bool
    private(set) var entries: [Entry] = []
    @ObservationIgnored private var nextID = 0
    @ObservationIgnored private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "reach", category: "input")

    init(visible: Bool) { isVisible = visible }

    func record(_ message: ClientMessage) {
        logger.debug("\(Self.kind(of: message), privacy: .public)")
        guard isVisible else { return }
        append(Self.describe(message), pointer: false)
    }

    func recordPointer(x: Float, y: Float, seq: UInt32) {
        guard isVisible else { return }
        append(String(format: "pointer → %.3f, %.3f", x, y), pointer: true)
    }

    func clear() { entries.removeAll() }

    private func append(_ text: String, pointer: Bool) {
        guard isVisible else { return }
        // Collapse runs of pointer moves into one line with a counter so the log stays readable.
        if pointer, let last = entries.last, last.isPointer {
            entries[entries.count - 1].text = text
            entries[entries.count - 1].count += 1
            return
        }
        nextID += 1
        entries.append(Entry(id: nextID, text: text, count: 1, isPointer: pointer))
        if entries.count > 14 { entries.removeFirst(entries.count - 14) }
    }

    /// The message's case name ("text", "key", "scroll"…), without its contents.
    static func kind(of m: ClientMessage) -> String {
        String(String(describing: m).prefix { $0 != "(" })
    }

    static func describe(_ m: ClientMessage) -> String {
        switch m {
        case .mouseButton(let e):
            let cc = e.clickCount > 1 ? " ×\(e.clickCount)" : ""
            return String(format: "%@%@ %@%@ @ %.3f, %.3f", StickyModifiers.symbols(e.modifiers), e.button.rawValue,
                          e.isDown ? "down" : "up", cc, e.x, e.y)
        case .scroll(let s):
            if s.phase == .ended {
                return String(format: "scroll ended v=(%.0f, %.0f)", s.velocityX, s.velocityY)
            }
            return String(format: "scroll %@ (%.1f, %.1f)", s.phase.rawValue, s.dx, s.dy)
        case .key(let k):
            // A modifier key's own transition already names it; don't print "⇧⇧".
            let mods = MacKey.modifierKeys.contains(k.code) ? "" : StickyModifiers.symbols(k.modifiers)
            return "key \(mods)\(KeyNames.name(for: k.code)) \(k.isDown ? "down" : "up")"
        case .keyPress(let code, let mods):
            return "press \(StickyModifiers.symbols(mods))\(KeyNames.name(for: code))"
        case .text(let t):
            let shown = t.text.replacingOccurrences(of: "\n", with: "⏎")
            return "text \(StickyModifiers.symbols(t.modifiers))“\(shown.prefix(24))”"
        case .action(let a): return "action \(a.rawValue)"
        case .media(let k): return "media \(k.rawValue)"
        case .selectDisplay(let id): return "select display \(id)"
        case .setQuality(let q): return "quality \(q.mode.rawValue) \(q.maxFramesPerSecond)fps"
        case .viewport(let v): return "viewport \(v.displayedPixelWidth)×\(v.displayedPixelHeight) px"
        case .activateApp(let pid): return "activate app \(pid)"
        case .focusWindow(let id): return "focus window \(id)"
        case .requestApps: return "request apps"
        case .requestWindows: return "request windows"
        case .setClipboard(let c): return "clipboard → Mac (\(c.text.map { "\($0.count) chars" } ?? "image"))"
        case .hello: return "hello"
        case .ping: return "ping"
        }
    }
}

/// Human-readable names for the Mac key codes the app sends.
enum KeyNames {
    static func name(for code: UInt16) -> String {
        switch code {
        case MacKey.returnKey: return "↩"
        case MacKey.tab: return "⇥"
        case MacKey.escape: return "esc"
        case MacKey.delete: return "⌫"
        case MacKey.forwardDelete: return "⌦"
        case MacKey.space: return "space"
        case MacKey.leftArrow: return "←"
        case MacKey.rightArrow: return "→"
        case MacKey.upArrow: return "↑"
        case MacKey.downArrow: return "↓"
        case MacKey.home: return "home"
        case MacKey.end: return "end"
        case MacKey.pageUp: return "pgup"
        case MacKey.pageDown: return "pgdn"
        case MacKey.command, MacKey.rightCommand: return "⌘"
        case MacKey.shift, MacKey.rightShift: return "⇧"
        case MacKey.option, MacKey.rightOption: return "⌥"
        case MacKey.control, MacKey.rightControl: return "⌃"
        case MacKey.capsLock: return "⇪"
        default:
            if let i = MacKey.functionKeys.firstIndex(of: code) { return "F\(i + 1)" }
            if let letter = letters[code] { return letter }
            return String(format: "0x%02X", code)
        }
    }

    private static let letters: [UInt16: String] = {
        let pairs: [(UInt16, String)] = [
            (MacKey.a, "A"), (MacKey.b, "B"), (MacKey.c, "C"), (MacKey.d, "D"), (MacKey.e, "E"), (MacKey.f, "F"),
            (MacKey.g, "G"), (MacKey.h, "H"), (MacKey.i, "I"), (MacKey.j, "J"), (MacKey.k, "K"), (MacKey.l, "L"),
            (MacKey.m, "M"), (MacKey.n, "N"), (MacKey.o, "O"), (MacKey.p, "P"), (MacKey.q, "Q"), (MacKey.r, "R"),
            (MacKey.s, "S"), (MacKey.t, "T"), (MacKey.u, "U"), (MacKey.v, "V"), (MacKey.w, "W"), (MacKey.x, "X"),
            (MacKey.y, "Y"), (MacKey.z, "Z"), (MacKey.digit0, "0"), (MacKey.digit1, "1"), (MacKey.digit2, "2"),
            (MacKey.digit3, "3"), (MacKey.digit4, "4"), (MacKey.digit5, "5"), (MacKey.digit6, "6"),
            (MacKey.digit7, "7"), (MacKey.digit8, "8"), (MacKey.digit9, "9"), (MacKey.comma, ","),
            (MacKey.period, "."), (MacKey.slash, "/"), (MacKey.minus, "-"), (MacKey.equal, "="),
            (MacKey.leftBracket, "["), (MacKey.rightBracket, "]"), (MacKey.grave, "`"), (MacKey.semicolon, ";"),
            (MacKey.quote, "'"), (MacKey.backslash, "\\"),
        ]
        return Dictionary(pairs, uniquingKeysWith: { a, _ in a })
    }()
}
