import SwiftUI

struct SettingsSection: View {
    @Bindable var model: AppModel
    /// Snapshot hook: show the relay server editor.
    var editingRelayServer = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            SettingToggle(title: "Launch at login",
                          subtitle: model.loginItem.needsApproval ? "Allow Reach Host in Login Items to finish." : nil,
                          isOn: Binding(get: { model.loginItem.isEnabled },
                                        set: { model.loginItem.setEnabled($0) }))
            if model.loginItem.needsApproval {
                Button("Open Login Items Settings…", action: model.loginItem.openSystemSettings)
                    .buttonStyle(.link)
                    .font(.system(size: 11))
                    .padding(.horizontal, 6)
            }
            SettingToggle(title: "Keep Mac awake",
                          subtitle: "So your iPhone can always connect.",
                          isOn: $model.keepAwake)
            RelayServerSetting(model: model, isEditing: editingRelayServer)
        }
    }
}

private struct SettingToggle: View {
    let title: String
    let subtitle: String?
    @Binding var isOn: Bool

    var body: some View {
        Toggle(isOn: $isOn) {
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 13))
                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .toggleStyle(.switch)
        .controlSize(.mini)
        .padding(.horizontal, 6)
    }
}
