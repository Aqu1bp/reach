import SwiftUI

/// The menu bar popover.
struct MenuContentView: View {
    let model: AppModel
    /// Snapshot hook: show a device's remove confirmation.
    var confirmingRemovalID: String?
    /// Snapshot hook: show the relay server editor.
    var editingRelayServer = false

    static let width: CGFloat = 340

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            StatusHeader(model: model)
            if let session = model.session {
                SessionCard(session: session, onDisconnect: model.disconnect)
            }
            if let problem = model.problem {
                ProblemBanner(message: problem)
            }
            if !model.permissions.allGranted {
                PermissionsSection(permissions: model.permissions, onRelaunch: model.relaunch)
            }
            DevicesSection(model: model, confirmingRemovalID: confirmingRemovalID)
            Divider().padding(.horizontal, 6)
            SettingsSection(model: model, editingRelayServer: editingRelayServer)
            Divider().padding(.horizontal, 6)
            FooterBar(model: model)
        }
        .padding(10)
        .frame(width: Self.width)
    }
}

private struct ProblemBanner: View {
    let message: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text(message)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }
}
