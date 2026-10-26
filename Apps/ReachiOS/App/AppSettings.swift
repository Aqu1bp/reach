import Foundation
import ReachProtocol

/// How touches on the remote screen are interpreted. Remembered across sessions.
enum InputMode: String, CaseIterable, Identifiable {
    /// The phone is a trackpad: relative, accelerated cursor movement; taps click at the cursor.
    case trackpad
    /// Direct manipulation: taps land where you touch, one finger scrolls.
    case touch

    var id: String { rawValue }

    var title: String {
        switch self {
        case .trackpad: return "Trackpad"
        case .touch: return "Touch"
        }
    }

    var symbol: String {
        switch self {
        case .trackpad: return "rectangle.and.hand.point.up.left"
        case .touch: return "hand.point.up.left"
        }
    }

    var toggled: InputMode { self == .trackpad ? .touch : .trackpad }
}

extension QualityMode {
    var title: String {
        switch self {
        case .sharp: return "Sharp"
        case .balanced: return "Balanced"
        case .smooth: return "Smooth"
        case .dataSaver: return "Data Saver"
        }
    }

    var detail: String {
        switch self {
        case .sharp: return "Full resolution. Best for text and code."
        case .balanced: return "Adapts resolution and frame rate."
        case .smooth: return "Keeps motion fluid. Best for video."
        case .dataSaver: return "Half resolution, low data use."
        }
    }

    var symbol: String {
        switch self {
        case .sharp: return "textformat.size"
        case .balanced: return "circle.lefthalf.filled"
        case .smooth: return "film"
        case .dataSaver: return "leaf"
        }
    }
}

/// `@AppStorage` keys and defaults. Views bind with `@AppStorage(SettingsKey.x)`; non-view code reads
/// a snapshot through `AppSettings.current`.
enum SettingsKey {
    static let inputMode = "settings.inputMode"
    static let qualityMode = "settings.qualityMode"
    static let maxFPS = "settings.maxFPS"
    static let pointerSpeed = "settings.pointerSpeed"
    static let naturalScrolling = "settings.naturalScrolling"
    static let haptics = "settings.haptics"
    static let showStats = "settings.showStats"
    static let coachSeenPrefix = "coach.seen."
}

struct AppSettings {
    var inputMode: InputMode
    var qualityMode: QualityMode
    var maxFPS: Int
    var pointerSpeed: Double
    var naturalScrolling: Bool
    var haptics: Bool
    var showStats: Bool

    static let defaults: [String: Any] = [
        SettingsKey.inputMode: InputMode.trackpad.rawValue,
        SettingsKey.qualityMode: QualityMode.balanced.rawValue,
        SettingsKey.maxFPS: 60,
        SettingsKey.pointerSpeed: 1.0,
        SettingsKey.naturalScrolling: true,
        SettingsKey.haptics: true,
        SettingsKey.showStats: false,
    ]

    static func registerDefaults() {
        UserDefaults.standard.register(defaults: defaults)
    }

    static var current: AppSettings {
        let d = UserDefaults.standard
        return AppSettings(
            inputMode: InputMode(rawValue: d.string(forKey: SettingsKey.inputMode) ?? "") ?? .trackpad,
            qualityMode: QualityMode(rawValue: d.string(forKey: SettingsKey.qualityMode) ?? "") ?? .balanced,
            maxFPS: d.integer(forKey: SettingsKey.maxFPS) == 0 ? 60 : d.integer(forKey: SettingsKey.maxFPS),
            pointerSpeed: d.double(forKey: SettingsKey.pointerSpeed) == 0 ? 1 : d.double(forKey: SettingsKey.pointerSpeed),
            naturalScrolling: d.bool(forKey: SettingsKey.naturalScrolling),
            haptics: d.bool(forKey: SettingsKey.haptics),
            showStats: d.bool(forKey: SettingsKey.showStats)
        )
    }

    var quality: QualityPreference {
        QualityPreference(mode: qualityMode, maxFramesPerSecond: maxFPS)
    }

    static func coachSeenKey(for mode: InputMode) -> String { SettingsKey.coachSeenPrefix + mode.rawValue }

    static func resetCoachMarks() {
        for mode in InputMode.allCases { UserDefaults.standard.removeObject(forKey: coachSeenKey(for: mode)) }
    }
}
