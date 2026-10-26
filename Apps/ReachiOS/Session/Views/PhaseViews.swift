import SwiftUI

/// First connection: the Mac, its name, and three honest stages (they track the real connection state).
struct ConnectingView: View {
    let host: SessionHost
    let stage: SessionController.ConnectStage
    var onCancel: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pulse = false

    var body: some View {
        ZStack {
            Theme.backdrop
            Theme.glow(radius: 300)
                .scaleEffect(pulse ? 1.12 : 0.92)
                .opacity(pulse ? 1 : 0.7)
                .offset(y: -90)
                .allowsHitTesting(false)

            VStack(spacing: 28) {
                Spacer()
                Image(systemName: MacGlyph.symbol(forModel: host.model))
                    .font(.system(size: 76, weight: .thin))
                    .foregroundStyle(.white)
                    .symbolEffect(.pulse, options: .repeating, isActive: !reduceMotion)
                    .accessibilityHidden(true)
                VStack(spacing: 6) {
                    Text("Connecting to")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Text(host.name)
                        .font(.title2.weight(.semibold))
                        .multilineTextAlignment(.center)
                }
                VStack(alignment: .leading, spacing: 14) {
                    StageRow(title: "Finding your Mac", state: state(for: .finding))
                    StageRow(title: "Securing the connection", state: state(for: .securing))
                    StageRow(title: "Starting the screen", state: state(for: .streaming))
                }
                .padding(.top, 6)
                Spacer()
                Button("Cancel", action: onCancel)
                    .font(.body.weight(.medium))
                    .controlSize(.large)
                    .glassButton()
                    .padding(.bottom, 24)
            }
            .padding(.horizontal, 32)
        }
        .accessibilityElement(children: .contain)
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 1.6).repeatForever(autoreverses: true)) { pulse = true }
        }
    }

    private func state(for s: SessionController.ConnectStage) -> StageRow.State {
        s < stage ? .done : s == stage ? .active : .pending
    }
}

private struct StageRow: View {
    enum State { case pending, active, done }
    let title: String
    let state: State

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                switch state {
                case .done:
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(Theme.online)
                        .transition(.scale.combined(with: .opacity))
                case .active:
                    ProgressView().controlSize(.small)
                case .pending:
                    Circle().strokeBorder(.white.opacity(0.25), lineWidth: 1.5)
                        .frame(width: 18, height: 18)
                }
            }
            .frame(width: 22, height: 22)
            Text(title)
                .font(.callout)
                .foregroundStyle(state == .pending ? .secondary : .primary)
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.8), value: state)
        .accessibilityElement(children: .combine)
        .accessibilityValue(state == .done ? "Done" : state == .active ? "In progress" : "Waiting")
    }
}

/// Over the last (dimmed) frame while the connection recovers.
struct ReconnectingOverlay: View {
    var onDisconnect: () -> Void

    /// The connection keeps retrying indefinitely; after a while, say so honestly instead of "a moment".
    @State private var slow = false

    var body: some View {
        VStack(spacing: 14) {
            ProgressView()
                .controlSize(.large)
                .tint(.white)
            Text(slow ? "Still Reconnecting…" : "Reconnecting…")
                .font(.headline)
            Text(slow ? "Your Mac may be asleep or off the network. Reach keeps trying until you disconnect."
                      : "Your Mac’s screen will be back in a moment.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .contentTransition(.opacity)
            // Full-width so the capsule reads as a button on top of the glass card (a compact one blends in).
            Button(role: .destructive, action: onDisconnect) {
                Text("Disconnect").frame(maxWidth: .infinity)
            }
            .font(.body.weight(.medium))
            .foregroundStyle(Theme.danger)
            .controlSize(.large)
            .glassButton()
            .padding(.top, 4)
        }
        .padding(24)
        .frame(maxWidth: 300)
        .glassSurface(in: RoundedRectangle(cornerRadius: 28, style: .continuous))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .contain)
        .animation(.easeInOut(duration: 0.3), value: slow)
        .task {
            try? await Task.sleep(for: .seconds(15))
            slow = true
        }
    }
}

/// Connection failed or the Mac ended the session. Over the frozen frame when there was one.
struct FailureView: View {
    let host: SessionHost
    let title: String
    let message: String
    let overFrame: Bool
    var onRetry: () -> Void
    var onClose: () -> Void

    var body: some View {
        ZStack {
            if !overFrame {
                Theme.backdrop
                Theme.glow(Theme.danger, radius: 240).offset(y: -110).allowsHitTesting(false)
            }
            VStack(spacing: 16) {
                ZStack(alignment: .bottomTrailing) {
                    Image(systemName: MacGlyph.symbol(forModel: host.model))
                        .font(.system(size: 58, weight: .thin))
                        .foregroundStyle(.white.opacity(0.85))
                    Image(systemName: "exclamationmark.circle.fill")
                        .font(.system(size: 24))
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, Theme.danger)
                        .background(Circle().fill(Theme.background).padding(2))
                        .offset(x: 10, y: 6)
                }
                .accessibilityHidden(true)
                VStack(spacing: 6) {
                    Text(title)
                        .font(.title3.weight(.semibold))
                    Text(message)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
                VStack(spacing: 10) {
                    Button(action: onRetry) {
                        Text("Try Again").frame(maxWidth: .infinity)
                    }
                    .controlSize(.large)
                    .prominentGlassButton()
                    Button(action: onClose) {
                        Text("Back to Macs").frame(maxWidth: .infinity)
                    }
                    .controlSize(.large)
                    .glassButton()
                }
                .padding(.top, 6)
            }
            .padding(overFrame ? 24 : 32)
            .frame(maxWidth: 360)
            .background {
                if overFrame {
                    RoundedRectangle(cornerRadius: 30, style: .continuous).fill(.clear)
                        .glassSurface(in: RoundedRectangle(cornerRadius: 30, style: .continuous))
                }
            }
            .padding(.horizontal, 20)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .contain)
        .onAppear { UIAccessibility.post(notification: .screenChanged, argument: title) }
    }
}
