import SwiftUI

/// "Pair iPhone" window: a QR code with instructions, then a success state.
struct PairingView: View {
    let model: AppModel
    let onDone: () -> Void

    /// Content size; the window adds its (transparent) title bar above.
    static let size = CGSize(width: 620, height: 400)

    var body: some View {
        ZStack {
            switch model.pairing.state {
            case .paired(let name):
                PairingSuccessView(deviceName: name, onDone: onDone)
                    .transition(.opacity.combined(with: .scale(scale: 0.96)))
            case .showing, .idle:
                VStack(alignment: .leading, spacing: 18) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Pair your iPhone")
                            .font(.system(size: 20, weight: .bold))
                        Text("Pair once, then connect to this Mac from anywhere.")
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                    }
                    HStack(alignment: .top, spacing: 24) {
                        PairingCodePanel(pairing: model.pairing, qrSize: 220)
                        PairingSteps(hostName: model.hostInfo.name, fingerprint: model.fingerprint)
                    }
                }
                .transition(.opacity)
            }
        }
        .padding(.horizontal, 28)
        .padding(.top, 6)
        .padding(.bottom, 26)
        .frame(width: Self.size.width, height: Self.size.height)
        .animation(.smooth(duration: 0.35), value: model.pairing.state)
    }
}

/// The three steps beside the code.
struct PairingSteps: View {
    let hostName: String
    let fingerprint: String

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            StepRow(number: 1, title: "Open Reach on your iPhone",
                    detail: "Or point the iPhone's Camera at the code — it opens Reach for you.")
            StepRow(number: 2, title: "Tap Add a Mac, then Scan Code",
                    detail: "No camera handy? Copy Code here, then Paste Code on the iPhone.")
            StepRow(number: 3, title: "Check the key fingerprint",
                    detail: "Reach on your iPhone shows \(fingerprint) in the details for “\(hostName)”.")
            Spacer(minLength: 0)
            Label("End-to-end encrypted. The code works once and only for this Mac.", systemImage: "lock.fill")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct StepRow: View {
    let number: Int
    let title: String
    let detail: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text("\(number)")
                .font(.system(size: 12, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .frame(width: 20, height: 20)
                .background(Circle().fill(Color.accentColor))
                .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4 }
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                Text(detail)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

struct PairingSuccessView: View {
    let deviceName: String
    var onDone: (() -> Void)?

    var body: some View {
        VStack(spacing: 14) {
            Spacer(minLength: 0)
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 60, weight: .regular))
                .foregroundStyle(.white, .green)
                .symbolRenderingMode(.palette)
            VStack(spacing: 4) {
                Text("Paired with \(deviceName)")
                    .font(.system(size: 18, weight: .bold))
                    .multilineTextAlignment(.center)
                Text("You can now control this Mac from your iPhone, wherever you are.")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            if let onDone {
                Button("Done", action: onDone)
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .padding(.top, 6)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity)
    }
}
