import SwiftUI

/// A System Settings–style rounded tile with a white glyph on a tinted gradient.
struct IconTile: View {
    let systemName: String
    var tint: Color = .accentColor
    var size: CGFloat = 28

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.27, style: .continuous)
            .fill(tint.gradient)
            .overlay {
                Image(systemName: systemName)
                    .font(.system(size: size * 0.5, weight: .semibold))
                    .foregroundStyle(.white)
                    .symbolRenderingMode(.hierarchical)
            }
            .overlay {
                RoundedRectangle(cornerRadius: size * 0.27, style: .continuous)
                    .strokeBorder(.white.opacity(0.18), lineWidth: 0.5)
            }
            .frame(width: size, height: size)
            .shadow(color: .black.opacity(0.12), radius: 0.5, y: 0.5)
            .accessibilityHidden(true)
    }
}

/// A small status light with a soft halo.
struct StatusDot: View {
    let color: Color
    var size: CGFloat = 8

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: size, height: size)
            .background(Circle().fill(color.opacity(0.25)).frame(width: size + 6, height: size + 6))
            .accessibilityHidden(true)
    }
}

struct SectionHeader: View {
    let title: String

    var body: some View {
        Text(title)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 6)
            .accessibilityAddTraits(.isHeader)
    }
}

/// A full-width row that highlights on hover, like a menu item.
struct MenuRowButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        MenuRow(configuration: configuration)
    }

    private struct MenuRow: View {
        let configuration: ButtonStyleConfiguration
        @State private var isHovered = false
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            configuration.label
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 6)
                .padding(.vertical, 5)
                .contentShape(Rectangle())
                .background {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color.primary.opacity(configuration.isPressed ? 0.14 : (isHovered && isEnabled ? 0.08 : 0)))
                }
                .opacity(isEnabled ? 1 : 0.45)
                .onHover { isHovered = $0 }
        }
    }
}

extension ButtonStyle where Self == MenuRowButtonStyle {
    static var menuRow: MenuRowButtonStyle { MenuRowButtonStyle() }
}

/// A grouped "card" surface used inside the popover and windows.
struct CardBackground: ViewModifier {
    var padding: CGFloat = 10

    func body(content: Content) -> some View {
        content
            .padding(padding)
            .background {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.primary.opacity(0.045))
            }
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.07), lineWidth: 0.5)
            }
    }
}

extension View {
    func card(padding: CGFloat = 10) -> some View {
        modifier(CardBackground(padding: padding))
    }
}

/// A capsule label such as "Allowed" or "Not allowed".
struct StatusPill: View {
    let title: String
    let systemImage: String
    let tint: Color

    var body: some View {
        Label(title, systemImage: systemImage)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(tint)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Capsule().fill(tint.opacity(0.14)))
    }
}
