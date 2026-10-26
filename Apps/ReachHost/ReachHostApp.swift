import SwiftUI

/// The menu bar app. Launched from `Entry` unless a debug command is running instead.
struct ReachHostApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        MenuBarExtra {
            MenuContentView(model: delegate.model)
        } label: {
            MenuBarIcon(model: delegate.model)
        }
        .menuBarExtraStyle(.window)
    }
}

/// Filled while an iPhone is connected, so it's obvious at a glance that the Mac is being controlled.
struct MenuBarIcon: View {
    let model: AppModel

    var body: some View {
        Image(systemName: model.session == nil ? "iphone.gen3.radiowaves.left.and.right"
                                               : "iphone.gen3.radiowaves.left.and.right.circle.fill")
            .accessibilityLabel(model.session == nil ? "Reach" : "Reach — iPhone connected")
    }
}
