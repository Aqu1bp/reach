import ReachCore
import SwiftUI

/// Paired iPhones and the way to add one.
struct DevicesSection: View {
    let model: AppModel
    @State private var confirmingRemovalID: String?

    init(model: AppModel, confirmingRemovalID: String? = nil) {
        self.model = model
        _confirmingRemovalID = State(initialValue: confirmingRemovalID)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            SectionHeader(title: "Paired iPhones")
                .padding(.bottom, 2)
            if model.pairedDevices.isEmpty {
                Text("Pair your iPhone to control this Mac from anywhere.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.bottom, 4)
            }
            ForEach(model.pairedDevices) { device in
                if confirmingRemovalID == device.id {
                    RemoveConfirmation(device: device,
                                       onCancel: { confirmingRemovalID = nil },
                                       onRemove: {
                                           confirmingRemovalID = nil
                                           model.remove(device)
                                       })
                } else {
                    DeviceRow(device: device, isConnected: model.session?.clientID == device.id,
                              onRemove: { confirmingRemovalID = device.id })
                }
            }
            Button(action: model.showPairing) {
                Label {
                    Text("Pair iPhone…")
                } icon: {
                    Image(systemName: "plus")
                        .font(.system(size: 11, weight: .bold))
                        .frame(width: 26, height: 26)
                        .background(Circle().fill(Color.primary.opacity(0.08)))
                }
            }
            .buttonStyle(.menuRow)
        }
        .animation(.snappy(duration: 0.2), value: confirmingRemovalID)
    }
}

private struct DeviceRow: View {
    let device: TrustedClient
    let isConnected: Bool
    let onRemove: () -> Void
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "iphone.gen3")
                .font(.system(size: 15))
                .foregroundStyle(isConnected ? Color.accentColor : .secondary)
                .frame(width: 26, height: 26)
            VStack(alignment: .leading, spacing: 1) {
                HStack(alignment: .firstTextBaseline) {
                    Text(device.name)
                        .font(.system(size: 13))
                        .lineLimit(1)
                    Spacer(minLength: 6)
                    // Reach on the iPhone shows this same fingerprint for itself in Settings.
                    Text(device.fingerprint)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .opacity(isHovered ? 0 : 1)
                        .help("Key fingerprint")
                }
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            // Room for the remove button, so text truncates rather than running under it.
            .padding(.trailing, isHovered ? 22 : 0)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .overlay(alignment: .trailing) {
            if isHovered {
                Button(action: onRemove) {
                    Image(systemName: "minus.circle.fill")
                        .font(.system(size: 15))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6)
                        .frame(maxHeight: .infinity)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Remove \(device.name)")
                .accessibilityLabel("Remove \(device.name)")
            }
        }
        .background {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.primary.opacity(isHovered ? 0.05 : 0))
        }
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .accessibilityElement(children: .combine)
        .accessibilityAction(named: "Remove") { onRemove() }
    }

    private var subtitle: String {
        if isConnected { return "Connected now" }
        let model = device.deviceModel.isEmpty ? nil : device.deviceModel
        let seen = Formatting.lastSeen(pairedAt: device.pairedAt, lastConnectedAt: device.lastConnectedAt)
        return [model, seen].compactMap { $0 }.joined(separator: " · ")
    }
}

/// Removing a device is inline rather than an alert: alerts detach awkwardly from a menu bar panel.
private struct RemoveConfirmation: View {
    let device: TrustedClient
    let onCancel: () -> Void
    let onRemove: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Remove “\(device.name)”?")
                .font(.system(size: 12, weight: .semibold))
            Text("It won't be able to connect until you pair it again.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("Remove", role: .destructive, action: onRemove)
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
            }
            .controlSize(.small)
        }
        .card()
        .transition(.opacity)
    }
}
