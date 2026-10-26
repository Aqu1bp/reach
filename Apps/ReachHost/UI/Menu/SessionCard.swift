import SwiftUI

/// The iPhone currently controlling this Mac.
struct SessionCard: View {
    let session: AppModel.ActiveSession
    let onDisconnect: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            IconTile(systemName: "iphone.gen3", tint: .accentColor, size: 30)
            VStack(alignment: .leading, spacing: 2) {
                Text(session.deviceName)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                TimelineView(.periodic(from: session.startedAt, by: 30)) { context in
                    Text(detail(now: context.date))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            Button("Disconnect", action: onDisconnect)
                .controlSize(.small)
        }
        .card()
        .accessibilityElement(children: .contain)
    }

    private func detail(now: Date) -> String {
        let link = Formatting.link(route: session.route, roundTripMs: session.roundTripMs)
        return "\(link) · \(Formatting.duration(now.timeIntervalSince(session.startedAt)))"
    }
}
