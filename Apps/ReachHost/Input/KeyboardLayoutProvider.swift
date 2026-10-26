import Carbon
import os
import ReachCore

/// Keeps a reverse map for the Mac's current keyboard layout, rebuilt when the user switches input
/// sources. Built on the main thread (Text Input Source APIs require it); read from any thread.
final class KeyboardLayoutProvider: @unchecked Sendable {
    private let map = OSAllocatedUnfairLock<KeyboardLayoutMap?>(initialState: nil)
    private var observers: [NSObjectProtocol] = []

    var current: KeyboardLayoutMap? { map.withLock { $0 } }

    @MainActor
    func start() {
        rebuild()
        let center = DistributedNotificationCenter.default()
        let names: [CFString] = [kTISNotifySelectedKeyboardInputSourceChanged, kTISNotifyEnabledKeyboardInputSourcesChanged]
            .compactMap { $0 }
        observers = names.map { name in
            center.addObserver(forName: Notification.Name(name as String), object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.rebuild() }
            }
        }
    }

    @MainActor
    private func rebuild() {
        let layout = KeyboardLayoutMap.current()
        map.withLock { $0 = layout }
        if let layout {
            ReachLog.info("host", "keyboard layout: \(layout.layoutName), \(layout.count) characters" +
                          (layout.inputMethodActive ? ", input method active" : ""))
        } else {
            ReachLog.error("host", "no keyboard layout data; text will be typed as Unicode")
        }
    }

    deinit {
        observers.forEach(DistributedNotificationCenter.default().removeObserver)
    }
}
