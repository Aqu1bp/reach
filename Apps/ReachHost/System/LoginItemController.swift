import Observation
import ReachCore
import ServiceManagement

/// "Launch at login", backed by `SMAppService.mainApp`.
@MainActor
@Observable
final class LoginItemController {
    private(set) var isEnabled = false
    /// Registered, but the user still has to allow it in System Settings → General → Login Items.
    private(set) var needsApproval = false

    @ObservationIgnored private let isLive: Bool

    init() {
        isLive = true
        refresh()
    }

    init(previewEnabled: Bool) {
        isLive = false
        isEnabled = previewEnabled
    }

    func refresh() {
        guard isLive else { return }
        let status = SMAppService.mainApp.status
        isEnabled = status == .enabled || status == .requiresApproval
        needsApproval = status == .requiresApproval
    }

    func setEnabled(_ enabled: Bool) {
        guard isLive else {
            isEnabled = enabled
            return
        }
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            ReachLog.error("host", "login item \(enabled ? "register" : "unregister") failed: \(error.localizedDescription)")
        }
        refresh()
    }

    func openSystemSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
