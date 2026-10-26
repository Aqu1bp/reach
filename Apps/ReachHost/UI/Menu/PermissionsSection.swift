import SwiftUI

/// Shown only while a permission is missing: what's needed, why, and a one-click way to fix it.
struct PermissionsSection: View {
    let permissions: PermissionMonitor
    let onRelaunch: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !permissions.screenRecording {
                PermissionRow(kind: .screenRecording, needsRelaunch: permissions.screenRecordingNeedsRelaunch,
                              onAllow: { permissions.request(.screenRecording) }, onRelaunch: onRelaunch)
            }
            if !permissions.accessibility {
                PermissionRow(kind: .accessibility, needsRelaunch: false,
                              onAllow: { permissions.request(.accessibility) }, onRelaunch: onRelaunch)
            }
        }
        .card()
    }
}

struct PermissionRow: View {
    let kind: PermissionMonitor.Kind
    let needsRelaunch: Bool
    let onAllow: () -> Void
    let onRelaunch: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            IconTile(systemName: kind.symbolName, tint: kind.tint, size: 26)
            VStack(alignment: .leading, spacing: 1) {
                Text(kind.title)
                    .font(.system(size: 12, weight: .semibold))
                Text(needsRelaunch ? "Allowed it? Relaunch Reach Host to apply." : kind.reason)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 6)
            if needsRelaunch {
                Button("Relaunch", action: onRelaunch)
                    .controlSize(.small)
            } else {
                Button("Allow…", action: onAllow)
                    .controlSize(.small)
            }
        }
    }
}

extension PermissionMonitor.Kind {
    var title: String {
        switch self {
        case .screenRecording: return "Screen Recording"
        case .accessibility: return "Accessibility"
        }
    }

    /// One line on why, in terms of what the user gets.
    var reason: String {
        switch self {
        case .screenRecording: return "Lets your iPhone see this Mac's screen."
        case .accessibility: return "Lets your iPhone use the pointer and keyboard."
        }
    }

    var symbolName: String {
        switch self {
        case .screenRecording: return "rectangle.dashed.badge.record"
        case .accessibility: return "accessibility"
        }
    }

    var tint: Color {
        switch self {
        case .screenRecording: return .red
        case .accessibility: return .blue
        }
    }
}
