import SwiftUI

// Liquid Glass on iOS 26+, with a material-based look on iOS 18–25 so the layout is identical.

extension View {
    /// Glass background in `shape`. `tint` colours the glass (e.g. an active toggle).
    @ViewBuilder
    func glassSurface<S: Shape>(in shape: S, tint: Color? = nil, interactive: Bool = false) -> some View {
        if #available(iOS 26.0, *) {
            self.glassEffect(Glass.regular.tint(tint).interactive(interactive), in: shape)
        } else {
            self
                .background {
                    ZStack {
                        shape.fill(.ultraThinMaterial)
                        if let tint { shape.fill(tint.opacity(0.55)) }
                        shape.stroke(.white.opacity(0.14), lineWidth: 0.5)
                    }
                }
        }
    }

    /// Ties a glass shape to an identity so it morphs between layouts inside a `GlassGroup`.
    @ViewBuilder
    func glassID<ID: Hashable & Sendable>(_ id: ID, in namespace: Namespace.ID) -> some View {
        if #available(iOS 26.0, *) {
            self.glassEffectID(id, in: namespace)
        } else {
            self
        }
    }

    /// Prominent glass button style on iOS 26, bordered-prominent before.
    @ViewBuilder
    func prominentGlassButton() -> some View {
        if #available(iOS 26.0, *) {
            self.buttonStyle(.glassProminent)
        } else {
            self.buttonStyle(.borderedProminent)
        }
    }

    @ViewBuilder
    func glassButton() -> some View {
        if #available(iOS 26.0, *) {
            self.buttonStyle(.glass)
        } else {
            self.buttonStyle(.bordered)
        }
    }
}

/// Groups glass shapes so they blend and morph together (iOS 26), or a plain container before.
struct GlassGroup<Content: View>: View {
    var spacing: CGFloat? = nil
    @ViewBuilder var content: Content

    var body: some View {
        if #available(iOS 26.0, *) {
            GlassEffectContainer(spacing: spacing) { content }
        } else {
            content
        }
    }
}
