import AppKit
import ReachCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = AppModel()

    /// Time for the "bye" to reach the iPhone before the process exits, so it shows "Mac quit"
    /// immediately instead of waiting for the connection to time out.
    private static let goodbyeGrace: TimeInterval = 0.4

    func applicationDidFinishLaunching(_ notification: Notification) {
        model.start()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard model.shutdown() else { return .terminateNow }
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.goodbyeGrace) {
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    /// Opening the app again (Finder, Spotlight) while it runs shows the setup guide, since a
    /// menu-bar app has no window of its own to bring forward.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { model.showOnboarding() }
        return true
    }
}
