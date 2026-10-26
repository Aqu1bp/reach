import SwiftUI

/// Floating glass capsule: Keyboard · Mode · Shortcuts · Apps · More, collapsible to a small handle.
///
/// Portrait puts it under the screen (in the letterbox); landscape stands it up along the trailing edge,
/// where a 16:10 Mac screen leaves a natural side gutter — so at fit zoom the dock never covers the
/// Mac's own Dock or menu bar.
struct DockView: View {
    let controller: SessionController
    @Binding var collapsed: Bool
    var vertical: Bool
    var onShortcuts: () -> Void
    var onApps: () -> Void
    var onMore: () -> Void

    @Namespace private var glass
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GlassGroup(spacing: 16) {
            if collapsed {
                handle
            } else {
                expanded
            }
        }
        .animation(.reach(reduceMotion), value: collapsed)
        .animation(.reach(reduceMotion), value: vertical)
    }

    private var expanded: some View {
        stack {
            DockButton(symbol: "keyboard", label: "Keyboard", isActive: controller.keyboardVisible) {
                controller.keyboardVisible.toggle()
            }
            DockButton(symbol: controller.inputMode.symbol, label: "\(controller.inputMode.title) Mode",
                       hint: "Switches between trackpad and touch input") {
                toggleMode()
            }
            DockButton(symbol: "command", label: "Shortcuts", action: onShortcuts)
            DockButton(symbol: "square.grid.2x2", label: "Apps and Windows", action: onApps)
            DockButton(symbol: "ellipsis", label: "More", action: onMore)
            separator
            DockButton(symbol: vertical ? "chevron.compact.right" : "chevron.compact.down", label: "Hide Dock", compact: true) {
                collapsed = true
            }
        }
        .padding(vertical ? .vertical : .horizontal, 6)
        .padding(vertical ? .horizontal : .vertical, 5)
        .glassSurface(in: Capsule())
        .glassID("dock", in: glass)
        .gesture(swipeToCollapse)
    }

    private var handle: some View {
        Button {
            collapsed = false
        } label: {
            Capsule()
                .fill(.white.opacity(0.85))
                .frame(width: vertical ? 5 : 40, height: vertical ? 40 : 5)
                .frame(width: vertical ? 22 : 64, height: vertical ? 64 : 22)
                .glassSurface(in: Capsule(), interactive: true)
                .glassID("dock", in: glass)
                .frame(width: 64, height: 64)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Show Dock")
        .gesture(DragGesture(minimumDistance: 8).onEnded { value in
            let t = vertical ? -value.translation.width : -value.translation.height
            if t > 12 { collapsed = false }
        })
    }

    private var separator: some View {
        Rectangle()
            .fill(.white.opacity(0.18))
            .frame(width: vertical ? 22 : 1, height: vertical ? 1 : 22)
            .padding(vertical ? .vertical : .horizontal, 2)
            .accessibilityHidden(true)
    }

    private var swipeToCollapse: some Gesture {
        DragGesture(minimumDistance: 14).onEnded { value in
            let t = vertical ? value.translation.width : value.translation.height
            if t > 24 { collapsed = true }
        }
    }

    @ViewBuilder
    private func stack<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        if vertical {
            VStack(spacing: 2, content: content)
        } else {
            HStack(spacing: 2, content: content)
        }
    }

    private func toggleMode() {
        controller.inputMode = controller.inputMode.toggled
        Haptics.shared.play(.modeSwitch)
        controller.showToast(symbol: controller.inputMode.symbol, "\(controller.inputMode.title) Mode")
    }
}

struct DockButton: View {
    var symbol: String
    var label: String
    var hint: String? = nil
    var isActive = false
    var compact = false
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: compact ? 15 : 19, weight: .medium))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(isActive ? Theme.accent : .white)
                .contentTransition(.symbolEffect(.replace))
                .frame(width: compact ? 34 : 46, height: compact ? 34 : 46)
                .background {
                    if isActive {
                        Circle().fill(Theme.accent.opacity(0.22))
                    }
                }
                .contentShape(Circle())
        }
        .buttonStyle(DockPressStyle())
        .accessibilityLabel(label)
        .accessibilityHint(hint ?? "")
        .accessibilityAddTraits(isActive ? .isSelected : [])
    }
}

/// Subtle press feedback for glyph buttons on glass.
struct DockPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.88 : 1)
            .opacity(configuration.isPressed ? 0.75 : 1)
            .animation(.spring(response: 0.22, dampingFraction: 0.7), value: configuration.isPressed)
    }
}
