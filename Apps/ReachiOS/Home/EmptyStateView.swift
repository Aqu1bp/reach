import SwiftUI

/// First launch: what Reach is, the three pairing steps, and the two ways to pair.
struct EmptyStateView: View {
    var onScan: () -> Void
    var onPaste: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var float = false

    var body: some View {
        ScrollView {
            VStack(spacing: 30) {
                hero
                    .padding(.top, 18)

                VStack(spacing: 8) {
                    Text("Your Mac, in your pocket")
                        .font(.title2.weight(.bold))
                        .multilineTextAlignment(.center)
                    Text("See and control your Mac from anywhere — over Wi‑Fi or the internet.")
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding(.horizontal, 12)

                VStack(alignment: .leading, spacing: 18) {
                    StepRow(number: 1, symbol: "arrow.down.circle", title: "Install Reach Host on your Mac",
                            detail: "It lives in the menu bar and keeps your Mac reachable.")
                    StepRow(number: 2, symbol: "menubar.rectangle", title: "Choose Pair iPhone",
                            detail: "Click the Reach icon in the menu bar. A code appears.")
                    StepRow(number: 3, symbol: "qrcode.viewfinder", title: "Scan the code",
                            detail: "Or copy it on the Mac and paste it here.")
                }
                .padding(20)
                .background(Theme.elevated, in: RoundedRectangle(cornerRadius: 26, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 26, style: .continuous).strokeBorder(.white.opacity(0.07), lineWidth: 1)
                }

                VStack(spacing: 12) {
                    Button(action: onScan) {
                        Label("Scan Code", systemImage: "qrcode.viewfinder")
                            .font(.body.weight(.semibold))
                            .frame(maxWidth: .infinity)
                    }
                    .controlSize(.large)
                    .prominentGlassButton()

                    Button(action: onPaste) {
                        Label("Paste Code", systemImage: "doc.on.clipboard")
                            .font(.body.weight(.medium))
                            .frame(maxWidth: .infinity)
                    }
                    .controlSize(.large)
                    .glassButton()
                }
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 32)
            .frame(maxWidth: 520)
            .frame(maxWidth: .infinity)
        }
        .scrollBounceBehavior(.basedOnSize)
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 3).repeatForever(autoreverses: true)) { float = true }
        }
    }

    /// iPhone reaching a Mac: a laptop with a glowing cursor and a phone overlapping its corner.
    private var hero: some View {
        ZStack {
            Theme.glow(radius: 170)
                .frame(width: 360, height: 360)
            Image(systemName: "macbook")
                .font(.system(size: 112, weight: .ultraLight))
                .foregroundStyle(.white.opacity(0.9))
            Image(systemName: "cursorarrow")
                .font(.system(size: 26, weight: .semibold))
                .foregroundStyle(Theme.accent)
                .shadow(color: Theme.accent.opacity(0.8), radius: 8)
                .offset(x: float ? 10 : -14, y: float ? -18 : -8)
            Image(systemName: "iphone")
                .font(.system(size: 54, weight: .light))
                .foregroundStyle(.white)
                .background(Circle().fill(Theme.background).frame(width: 64, height: 64).blur(radius: 6))
                .offset(x: 82, y: 38)
        }
        .frame(height: 190)
        .accessibilityHidden(true)
    }
}

private struct StepRow: View {
    var number: Int
    var symbol: String
    var title: String
    var detail: String

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Text("\(number)")
                .font(.subheadline.weight(.bold).monospacedDigit())
                .foregroundStyle(Theme.accent)
                .frame(width: 30, height: 30)
                .background(Circle().fill(Theme.accent.opacity(0.16)))
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.body.weight(.semibold))
                Text(detail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            Image(systemName: symbol)
                .font(.system(size: 18))
                .foregroundStyle(.secondary)
                .frame(width: 24)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Step \(number): \(title). \(detail)")
    }
}
