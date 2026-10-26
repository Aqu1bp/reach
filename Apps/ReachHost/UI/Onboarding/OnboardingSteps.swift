import AppKit
import SwiftUI

struct WelcomeStep: View {
    var body: some View {
        VStack(spacing: 18) {
            Image(nsImage: NSApp?.applicationIconImage ?? NSImage())
                .resizable()
                .frame(width: 88, height: 88)
                .accessibilityHidden(true)
            VStack(spacing: 6) {
                Text("Welcome to Reach")
                    .font(.system(size: 26, weight: .bold))
                Text("Control this Mac from your iPhone — from the next room or the other side of the world.")
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 400)
            }
            VStack(alignment: .leading, spacing: 14) {
                FeatureRow(systemName: "bolt.fill", tint: .orange, title: "Fast and fluid",
                           detail: "A low-latency stream that adapts to your connection.")
                FeatureRow(systemName: "cursorarrow.click.2", tint: .blue, title: "Your whole Mac",
                           detail: "Trackpad, keyboard, shortcuts, apps and windows.")
                FeatureRow(systemName: "lock.shield.fill", tint: .green, title: "Private by design",
                           detail: "End-to-end encrypted, and only iPhones you pair can connect.")
            }
            .padding(.top, 6)
            Spacer(minLength: 0)
        }
    }
}

private struct FeatureRow: View {
    let systemName: String
    let tint: Color
    let title: String
    let detail: String

    var body: some View {
        HStack(spacing: 12) {
            IconTile(systemName: systemName, tint: tint, size: 32)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                Text(detail)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: 380, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

/// One privacy permission: why it's needed, its live status, and how to grant it.
struct PermissionStep: View {
    let kind: PermissionMonitor.Kind
    let permissions: PermissionMonitor
    let onRelaunch: () -> Void

    private var isGranted: Bool {
        switch kind {
        case .screenRecording: return permissions.screenRecording
        case .accessibility: return permissions.accessibility
        }
    }

    private var needsRelaunch: Bool {
        kind == .screenRecording && !isGranted && permissions.screenRecordingNeedsRelaunch
    }

    var body: some View {
        VStack(spacing: 18) {
            Spacer(minLength: 0)
            IconTile(systemName: kind.symbolName, tint: kind.tint, size: 72)
            VStack(spacing: 8) {
                Text(kind.headline)
                    .font(.system(size: 22, weight: .bold))
                    .multilineTextAlignment(.center)
                Text(kind.explanation)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 430)
            }
            Group {
                if isGranted {
                    StatusPill(title: "Allowed", systemImage: "checkmark.circle.fill", tint: .green)
                } else {
                    VStack(spacing: 10) {
                        if needsRelaunch {
                            Button("Relaunch Reach Host", action: onRelaunch)
                                .buttonStyle(.borderedProminent)
                                .controlSize(.large)
                            Text("Turned it on? macOS applies Screen Recording once Reach Host relaunches.")
                                .hint()
                            Button("Open System Settings…") { permissions.openSettings(kind) }
                                .buttonStyle(.link)
                                .font(.system(size: 12))
                        } else {
                            Button(kind.actionTitle) { permissions.request(kind) }
                                .buttonStyle(.borderedProminent)
                                .controlSize(.large)
                            Text("In System Settings, turn on Reach Host under Privacy & Security → \(kind.title).")
                                .hint()
                        }
                    }
                }
            }
            .animation(.smooth(duration: 0.25), value: isGranted)
            Spacer(minLength: 0)
            Spacer(minLength: 0)
        }
    }
}

private extension Text {
    func hint() -> some View {
        font(.system(size: 11))
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: 400)
    }
}

extension PermissionMonitor.Kind {
    var headline: String {
        switch self {
        case .screenRecording: return "Let your iPhone see this screen"
        case .accessibility: return "Let your iPhone use the pointer and keyboard"
        }
    }

    var explanation: String {
        switch self {
        case .screenRecording:
            return "Reach Host needs Screen Recording permission to stream this Mac's display to your iPhone. "
                + "The stream is encrypted and only goes to iPhones you've paired."
        case .accessibility:
            return "Reach Host needs Accessibility permission to move the pointer, click, scroll and type "
                + "when you control this Mac from your iPhone."
        }
    }

    var actionTitle: String {
        switch self {
        case .screenRecording: return "Allow Screen Recording…"
        case .accessibility: return "Allow Accessibility…"
        }
    }
}

struct PairStep: View {
    let model: AppModel

    var body: some View {
        if case .paired(let name) = model.pairing.state {
            PairingSuccessView(deviceName: name)
        } else {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Pair your iPhone")
                        .font(.system(size: 22, weight: .bold))
                    Text("Install Reach on your iPhone, then scan this code.")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                }
                HStack(alignment: .top, spacing: 24) {
                    PairingCodePanel(pairing: model.pairing, qrSize: 200)
                    PairingSteps(hostName: model.hostInfo.name, fingerprint: model.fingerprint)
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
