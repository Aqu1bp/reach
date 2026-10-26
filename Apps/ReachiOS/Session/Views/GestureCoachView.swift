import SwiftUI

/// One-time guide shown the first time each input mode is used. Short and skimmable: a glyph, the
/// gesture, and what it does on the Mac.
struct GestureCoachView: View {
    let mode: InputMode
    var onDismiss: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var appeared = false

    private struct Tip: Identifiable {
        var symbol: String
        var gesture: String
        var result: String
        var id: String { gesture }
    }

    private var tips: [Tip] {
        switch mode {
        case .trackpad:
            return [
                Tip(symbol: "cursorarrow.motionlines", gesture: "Slide one finger", result: "Move the pointer"),
                Tip(symbol: "cursorarrow.click", gesture: "Tap", result: "Click · tap twice to double‑click"),
                Tip(symbol: "hand.tap", gesture: "Tap with two fingers", result: "Right‑click"),
                Tip(symbol: "hand.draw", gesture: "Touch and hold, then slide", result: "Drag"),
                Tip(symbol: "arrow.up.and.down.and.arrow.left.and.right", gesture: "Slide two fingers", result: "Scroll"),
                Tip(symbol: "hand.pinch", gesture: "Pinch", result: "Zoom · double‑tap with two fingers to fit"),
            ]
        case .touch:
            return [
                Tip(symbol: "hand.point.up.left", gesture: "Tap anywhere", result: "Click right there"),
                Tip(symbol: "hand.draw", gesture: "Slide one finger", result: "Scroll"),
                Tip(symbol: "hand.point.up.braille", gesture: "Touch and hold", result: "Right‑click · slide to drag"),
                Tip(symbol: "arrow.up.and.down.and.arrow.left.and.right", gesture: "Slide two fingers", result: "Move around the screen"),
                Tip(symbol: "hand.pinch", gesture: "Pinch", result: "Zoom · double‑tap with two fingers to fit"),
                Tip(symbol: "rectangle.3.group", gesture: "Swipe up with three fingers", result: "Mission Control"),
            ]
        }
    }

    var body: some View {
        ZStack {
            Color.black.opacity(0.55)
                .ignoresSafeArea()
                .onTapGesture(perform: onDismiss)
                .accessibilityHidden(true)

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    HStack(spacing: 12) {
                        Image(systemName: mode.symbol)
                            .font(.system(size: 22, weight: .medium))
                            .foregroundStyle(Theme.accent)
                            .frame(width: 44, height: 44)
                            .background(Circle().fill(Theme.accent.opacity(0.16)))
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(mode.title) Mode")
                                .font(.title3.weight(.semibold))
                            Text(mode == .trackpad ? "Your iPhone is the trackpad." : "Touch the Mac’s screen directly.")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .accessibilityElement(children: .combine)

                    VStack(alignment: .leading, spacing: 14) {
                        ForEach(Array(tips.enumerated()), id: \.element.id) { index, tip in
                            row(tip)
                                .opacity(appeared ? 1 : 0)
                                .offset(y: appeared || reduceMotion ? 0 : 8)
                                .animation(reduceMotion ? .none : .spring(response: 0.45, dampingFraction: 0.85).delay(0.05 * Double(index)),
                                           value: appeared)
                        }
                    }

                    Text("Switch modes any time from the dock.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)

                    Button(action: onDismiss) {
                        Text("Got It").frame(maxWidth: .infinity)
                    }
                    .controlSize(.large)
                    .prominentGlassButton()
                }
                .padding(22)
                .frame(maxWidth: 380)
                .glassSurface(in: RoundedRectangle(cornerRadius: 32, style: .continuous))
                .padding(20)
                .frame(maxWidth: .infinity)
            }
            .scrollBounceBehavior(.basedOnSize)
            // Centred when it fits; at large text sizes it starts at the top and scrolls.
            .defaultScrollAnchor(.center, for: .alignment)
            .defaultScrollAnchor(.top, for: .initialOffset)
        }
        .onAppear { appeared = true }
        .accessibilityAddTraits(.isModal)
    }

    private func row(_ tip: Tip) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 14) {
            Image(systemName: tip.symbol)
                .font(.system(size: 18, weight: .regular))
                .foregroundStyle(.white)
                .frame(width: 28)
                .alignmentGuide(.firstTextBaseline) { d in d[VerticalAlignment.center] + 6 }
            VStack(alignment: .leading, spacing: 1) {
                Text(tip.gesture)
                    .font(.callout.weight(.semibold))
                Text(tip.result)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }
}
