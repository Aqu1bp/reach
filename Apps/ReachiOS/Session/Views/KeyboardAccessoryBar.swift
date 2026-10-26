import SwiftUI
import ReachProtocol

/// Glass key row above the system keyboard with the Mac keys a phone keyboard lacks:
/// esc, tab, sticky ⌃ ⌥ ⌘ ⇧, arrows, fn row (F1–F12), forward delete, compose and hide.
struct KeyboardAccessoryBar: View {
    let controller: SessionController
    var onCompose: () -> Void
    @State private var fnRow = false
    @State private var scroll = ScrollPosition(edge: .leading)

    var body: some View {
        HStack(spacing: 6) {
            ScrollView(.horizontal, showsIndicators: false) {
                // Spacing 1: neighbouring keys stay distinct instead of melting into one blob.
                GlassGroup(spacing: 1) {
                    HStack(spacing: 6) {
                        if fnRow { functionRow } else { mainRow }
                    }
                    .padding(.leading, 10)
                    .padding(.trailing, 4)
                    .padding(.vertical, 8)
                }
            }
            .scrollPosition($scroll)
            // Fade the trailing edge so it's obvious the row scrolls to more keys.
            .mask {
                HStack(spacing: 0) {
                    Rectangle()
                    LinearGradient(colors: [.black, .clear], startPoint: .leading, endPoint: .trailing)
                        .frame(width: 18)
                }
            }

            KeyCap(label: "Hide Keyboard", width: 44) {
                controller.keyboardVisible = false
            } content: {
                Image(systemName: "keyboard.chevron.compact.down")
            }
            .padding(.trailing, 10)
        }
        .animation(.snappy(duration: 0.22), value: fnRow)
        // Switching rows starts at the first key, so the "fn" key that switches back is always in view.
        .onChange(of: fnRow) { scroll.scrollTo(edge: .leading) }
    }

    /// Ordered by how often each key is needed, so the essentials fit without scrolling on most phones.
    @ViewBuilder
    private var mainRow: some View {
        KeyCap(label: "Escape", width: 38) { press(MacKey.escape) } content: { Text("esc") }
        KeyCap(label: "Tab", width: 38) { press(MacKey.tab) } content: { Image(systemName: "arrow.right.to.line") }
        ModifierKeys(modifiers: controller.modifiers)
        ArrowCluster { press($0) }
        KeyCap(label: "Function Keys", width: 38) { fnRow = true } content: { Text("fn") }
        KeyCap(label: "Forward Delete", width: 40, repeats: true) { press(MacKey.forwardDelete) } content: { Image(systemName: "delete.right") }
        KeyCap(label: "Compose Text", width: 40) { onCompose() } content: { Image(systemName: "square.and.pencil") }
    }

    @ViewBuilder
    private var functionRow: some View {
        KeyCap(label: "Back to Main Keys", width: 40, tint: Theme.accent) { fnRow = false } content: { Text("fn") }
        ForEach(0..<12, id: \.self) { i in
            KeyCap(label: "F\(i + 1)", width: 40) { press(MacKey.functionKeys[i]) } content: { Text("F\(i + 1)") }
        }
    }

    private func press(_ code: UInt16) {
        controller.input.keyPress(code)
    }
}

/// ⌃ ⌥ ⌘ ⇧ with three clear states: off, armed for the next key (filled), locked (filled + bar).
struct ModifierKeys: View {
    let modifiers: StickyModifiers

    var body: some View {
        HStack(spacing: 4) {
            ForEach(StickyModifiers.order, id: \.rawValue) { m in
                let state = modifiers.state(of: m)
                KeyCap(label: StickyModifiers.name(m), width: 34, tint: state == .off ? nil : Theme.accent.opacity(state == .locked ? 1 : 0.75),
                       value: state == .off ? "Off" : state == .once ? "On for next key" : "Locked",
                       hint: "Tap for the next key; tap twice to lock") {
                    modifiers.tap(m)
                    Haptics.shared.play(.detent)
                } content: {
                    VStack(spacing: 2) {
                        Text(StickyModifiers.glyph(m))
                            .font(.system(size: 17, weight: state == .off ? .regular : .semibold))
                        Capsule()
                            .fill(.white)
                            .frame(width: 12, height: 2.5)
                            .opacity(state == .locked ? 1 : 0)
                    }
                    .offset(y: 2)
                }
            }
        }
    }
}

/// Mac-style inverted-T arrows: full-height ◀ ▶ around half-height ▲ ▼. Compact enough that the
/// essentials (esc, tab, modifiers, arrows) fit on one screen width. All four auto-repeat.
struct ArrowCluster: View {
    var press: (UInt16) -> Void

    var body: some View {
        HStack(spacing: 3) {
            KeyCap(label: "Left Arrow", width: 32, fontSize: 11, repeats: true) { press(MacKey.leftArrow) } content: {
                Image(systemName: "arrowtriangle.left.fill")
            }
            VStack(spacing: 2) {
                KeyCap(label: "Up Arrow", width: 32, height: 19, fontSize: 9, repeats: true) { press(MacKey.upArrow) } content: {
                    Image(systemName: "arrowtriangle.up.fill")
                }
                KeyCap(label: "Down Arrow", width: 32, height: 19, fontSize: 9, repeats: true) { press(MacKey.downArrow) } content: {
                    Image(systemName: "arrowtriangle.down.fill")
                }
            }
            KeyCap(label: "Right Arrow", width: 32, fontSize: 11, repeats: true) { press(MacKey.rightArrow) } content: {
                Image(systemName: "arrowtriangle.right.fill")
            }
        }
    }
}

/// A glass key. Fires on tap; `repeats` keys auto-repeat while held (after a short delay), like a
/// hardware keyboard.
struct KeyCap<Content: View>: View {
    var label: String
    var width: CGFloat = 40
    var height: CGFloat = 40
    var fontSize: CGFloat = 15
    var repeats = false
    var tint: Color? = nil
    var value: String? = nil
    var hint: String? = nil
    var action: () -> Void
    @ViewBuilder var content: Content

    @State private var pressed = false
    @State private var repeatTask: Task<Void, Never>?

    var body: some View {
        content
            .font(.system(size: fontSize, weight: .medium, design: .rounded))
            .foregroundStyle(.white)
            .frame(minWidth: width, minHeight: height)
            .glassSurface(in: RoundedRectangle(cornerRadius: height < 30 ? 8 : 12, style: .continuous), tint: tint, interactive: true)
            .scaleEffect(pressed ? 0.92 : 1)
            .animation(.spring(response: 0.2, dampingFraction: 0.7), value: pressed)
            .contentShape(Rectangle())
            .onTapGesture {
                action()
                Haptics.shared.play(.key)
            }
            .onLongPressGesture(minimumDuration: repeats ? 0.4 : 30, maximumDistance: 16) {
                startRepeating()
            } onPressingChanged: { isPressing in
                pressed = isPressing
                if !isPressing { stopRepeating() }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(label)
            .accessibilityValue(value ?? "")
            .accessibilityHint(hint ?? "")
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { action() }
            .onDisappear { stopRepeating() }
    }

    private func startRepeating() {
        guard repeats else { return }
        stopRepeating()
        action()
        repeatTask = Task { @MainActor in
            var count = 0
            // Safety cap (~6 s) in case a release is never delivered.
            while !Task.isCancelled, count < 120 {
                try? await Task.sleep(for: .milliseconds(50))
                guard !Task.isCancelled else { return }
                action()
                count += 1
            }
        }
    }

    private func stopRepeating() {
        repeatTask?.cancel()
        repeatTask = nil
    }
}
