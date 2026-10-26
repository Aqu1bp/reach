import SwiftUI

/// First-run guide: Welcome → Screen Recording → Accessibility → Pair. Re-openable from the menu.
struct OnboardingView: View {
    enum Step: Int, CaseIterable {
        case welcome, screenRecording, accessibility, pair
    }

    let model: AppModel
    @State private var step: Step

    /// Content size; the window adds its (transparent) title bar above.
    static let size = CGSize(width: 600, height: 450)

    init(model: AppModel, initialStep: Step = .welcome) {
        self.model = model
        _step = State(initialValue: initialStep)
    }

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                content
                    .id(step)
                    .transition(.asymmetric(insertion: .opacity.combined(with: .offset(x: 24)),
                                            removal: .opacity.combined(with: .offset(x: -24))))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.horizontal, 40)
            .padding(.top, 10)

            footer
                .padding(.horizontal, 24)
                .padding(.vertical, 18)
        }
        .frame(width: Self.size.width, height: Self.size.height)
        .onAppear { model.pairing.setVisible(step == .pair, for: .onboarding) }
        .onChange(of: step) { _, newStep in
            model.pairing.setVisible(newStep == .pair, for: .onboarding)
        }
    }

    @ViewBuilder
    private var content: some View {
        switch step {
        case .welcome:
            WelcomeStep()
        case .screenRecording:
            PermissionStep(kind: .screenRecording, permissions: model.permissions, onRelaunch: model.relaunch)
        case .accessibility:
            PermissionStep(kind: .accessibility, permissions: model.permissions, onRelaunch: model.relaunch)
        case .pair:
            PairStep(model: model)
        }
    }

    private var footer: some View {
        HStack {
            PageDots(count: Step.allCases.count, current: step.rawValue)
            Spacer()
            if step != .welcome {
                Button("Back") { go(to: step.rawValue - 1) }
                    .controlSize(.large)
            }
            if isStepSatisfied {
                primaryButton
                    .keyboardShortcut(.defaultAction)
            } else {
                // The step's own action (e.g. "Allow…") is the prominent one; this just moves on.
                primaryButton
            }
        }
    }

    private var primaryButton: some View {
        Button(primaryTitle) {
            if step == .pair {
                model.completeOnboarding()
            } else {
                go(to: step.rawValue + 1)
            }
        }
        .controlSize(.large)
    }

    private var isStepSatisfied: Bool {
        switch step {
        case .welcome: return true
        case .screenRecording: return model.permissions.screenRecording
        case .accessibility: return model.permissions.accessibility
        case .pair:
            if case .paired = model.pairing.state { return true }
            return !model.pairedDevices.isEmpty
        }
    }

    private var primaryTitle: String {
        switch step {
        case .welcome:
            return "Get Started"
        case .screenRecording, .accessibility:
            return isStepSatisfied ? "Continue" : "Not Now"
        case .pair:
            return isStepSatisfied ? "Done" : "Pair Later"
        }
    }

    private func go(to index: Int) {
        guard let next = Step(rawValue: index) else { return }
        withAnimation(.smooth(duration: 0.3)) { step = next }
    }
}

private struct PageDots: View {
    let count: Int
    let current: Int

    var body: some View {
        HStack(spacing: 7) {
            ForEach(0..<count, id: \.self) { index in
                Capsule()
                    .fill(index == current ? Color.accentColor : Color.primary.opacity(0.18))
                    .frame(width: index == current ? 16 : 7, height: 7)
            }
        }
        .animation(.snappy(duration: 0.25), value: current)
        .accessibilityElement()
        .accessibilityLabel("Step \(current + 1) of \(count)")
    }
}
