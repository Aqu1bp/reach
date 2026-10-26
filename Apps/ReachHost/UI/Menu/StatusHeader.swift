import SwiftUI

/// The Mac's name and whether iPhones can reach it.
struct StatusHeader: View {
    let model: AppModel

    var body: some View {
        HStack(spacing: 10) {
            IconTile(systemName: model.modelSymbol, tint: .gray, size: 34)
            VStack(alignment: .leading, spacing: 2) {
                Text(model.hostInfo.name)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                HStack(spacing: 6) {
                    StatusDot(color: status.color, size: 6)
                    Text(status.text)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 6)
        .padding(.top, 4)
        .accessibilityElement(children: .combine)
    }

    private var status: (text: String, color: Color) {
        switch model.connectivity {
        case .unavailable(let reason):
            return (reason, .red)
        case .offline:
            return ("Offline — waiting for the internet", .orange)
        case .connecting:
            return ("Connecting…", .gray)
        case .online:
            if let session = model.session { return ("In use by \(session.deviceName)", .accentColor) }
            if !model.permissions.allGranted { return ("Waiting for permissions", .orange) }
            if model.pairedDevices.isEmpty { return ("Ready to pair with your iPhone", .green) }
            return ("Ready — reachable from anywhere", .green)
        }
    }
}
