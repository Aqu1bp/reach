import Foundation

/// Development switches read from launch arguments (`xcrun simctl launch <udid> <bundle id> -demo`).
enum LaunchOptions {
    private static let args = ProcessInfo.processInfo.arguments

    /// Adds demo Macs to Home whose sessions render a synthetic desktop locally (no host needed).
    static let demo = args.contains("-demo")
    /// Connect to the demo Mac immediately on launch.
    static let demoAutoConnect = args.contains("-demoConnect")
    /// Show the on-screen log of every input message the session would send.
    static let inputLog = args.contains("-inputLog")
    /// Start with an empty Home (ignores demo hosts) to inspect the empty state.
    static let emptyHome = args.contains("-emptyHome")
    /// Skip the first-session gesture coach.
    static let skipCoach = args.contains("-skipCoach")
    /// Force the gesture coach even if it was seen.
    static let forceCoach = args.contains("-forceCoach")

    /// `-openSheet shortcuts|apps|more|compose|stats|keyboard` — opens a session panel after the first
    /// frame so screenshots can be captured without manual taps.
    static var openSheet: String? { value(after: "-openSheet") }
    /// `-sheetTab windows` — which tab the Apps sheet opens on.
    static var openSheetTab: String? { value(after: "-sheetTab") }
    /// `-openHome settings|details` — open a Home panel on launch (screenshots).
    static var openHome: String? { value(after: "-openHome") }
    /// `-inputMode touch|trackpad` — override the stored input mode for this launch.
    static var inputMode: InputMode? { value(after: "-inputMode").flatMap(InputMode.init(rawValue:)) }
    /// `-zoom <factor>` — start the session zoomed (relative to fit) for viewport screenshots.
    static var initialZoom: Double? { value(after: "-zoom").flatMap(Double.init) }
    /// `-dock collapsed` — start with the dock collapsed.
    static var dockCollapsed: Bool { value(after: "-dock") == "collapsed" }
    /// `-landscape` — rotate the interface to landscape on launch (simulator screenshots).
    static let landscape = args.contains("-landscape")
    /// `-pairing scan|paste|success|failure` — open the pairing flow in a given state.
    static var pairing: String? { value(after: "-pairing") }

    /// `-renderBench <jitterMs>` — the demo Mac re-sends its frame 60 times a second, each delayed by up
    /// to `jitterMs`, so the renderer's decoded→glass timing can be measured on a device without a host.
    static var renderBench: Double? { value(after: "-renderBench").flatMap(Double.init) }
    /// `-renderBenchFPS <fps>` — the bench's frame rate (default 60), to make its phase drift either way.
    static var renderBenchFPS: Double { value(after: "-renderBenchFPS").flatMap(Double.init) ?? 60 }

    private static func value(after flag: String) -> String? {
        guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
        return args[i + 1]
    }
}
