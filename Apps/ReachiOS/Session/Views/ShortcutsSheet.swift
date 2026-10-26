import SwiftUI
import ReachProtocol

/// Everyday Mac commands as big, labelled tiles. Editing and window commands dismiss the sheet so the
/// result is visible; media keys keep it open for repeated presses.
struct ShortcutsSheet: View {
    let controller: SessionController
    @Environment(\.dismiss) private var dismiss

    private struct Command: Identifiable {
        var title: String
        var symbol: String
        var key: UInt16
        var modifiers: KeyModifiers
        var id: String { title }
    }

    private static let editing: [Command] = [
        Command(title: "Copy", symbol: "doc.on.doc", key: MacKey.c, modifiers: .command),
        Command(title: "Paste", symbol: "doc.on.clipboard", key: MacKey.v, modifiers: .command),
        Command(title: "Cut", symbol: "scissors", key: MacKey.x, modifiers: .command),
        Command(title: "Undo", symbol: "arrow.uturn.backward", key: MacKey.z, modifiers: .command),
        Command(title: "Redo", symbol: "arrow.uturn.forward", key: MacKey.z, modifiers: [.command, .shift]),
        Command(title: "Select All", symbol: "square.dashed.inset.filled", key: MacKey.a, modifiers: .command),
        Command(title: "Find", symbol: "text.magnifyingglass", key: MacKey.f, modifiers: .command),
        Command(title: "Save", symbol: "square.and.arrow.down", key: MacKey.s, modifiers: .command),
        Command(title: "Print", symbol: "printer", key: MacKey.p, modifiers: .command),
    ]

    private static let windows: [Command] = [
        Command(title: "New", symbol: "plus.rectangle.on.rectangle", key: MacKey.n, modifiers: .command),
        Command(title: "New Tab", symbol: "plus.square.on.square", key: MacKey.t, modifiers: .command),
        Command(title: "Close", symbol: "xmark.rectangle", key: MacKey.w, modifiers: .command),
        Command(title: "Minimize", symbol: "minus.rectangle", key: MacKey.m, modifiers: .command),
        Command(title: "Full Screen", symbol: "arrow.up.left.and.arrow.down.right", key: MacKey.f, modifiers: [.command, .control]),
        Command(title: "Hide App", symbol: "eye.slash", key: MacKey.h, modifiers: .command),
        Command(title: "Next Window", symbol: "macwindow.on.rectangle", key: MacKey.grave, modifiers: .command),
        Command(title: "Settings", symbol: "gearshape", key: MacKey.comma, modifiers: .command),
        Command(title: "Quit App", symbol: "power", key: MacKey.q, modifiers: .command),
    ]

    private static let system: [SystemAction] = [
        .missionControl, .appExpose, .showDesktop, .spotlight, .appSwitcher, .launchpad,
        .notificationCenter, .previousSpace, .nextSpace, .screenshot, .lockScreen, .forceQuit,
    ]

    @Environment(\.dynamicTypeSize) private var typeSize

    /// Three tiles across on a phone; two at accessibility text sizes so labels have room.
    private var columns: [GridItem] {
        let minimum: CGFloat = typeSize.isAccessibilitySize ? 150 : 100
        return [GridItem(.adaptive(minimum: minimum, maximum: typeSize.isAccessibilitySize ? 260 : 160), spacing: 10)]
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    MediaControls(controller: controller)

                    section("Edit") {
                        ForEach(Self.editing) { c in commandTile(c) }
                    }
                    section("Windows & Apps") {
                        ForEach(Self.windows) { c in commandTile(c) }
                    }
                    section("System") {
                        ForEach(Self.system, id: \.self) { a in
                            Tile(title: a.title, symbol: a.symbol, caption: nil) {
                                controller.input.action(a)
                                finish()
                            }
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 24)
            }
            .navigationTitle("Shortcuts")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .presentationContentInteraction(.scrolls)
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
                .accessibilityAddTraits(.isHeader)
            LazyVGrid(columns: columns, spacing: 10, content: content)
        }
    }

    private func commandTile(_ c: Command) -> some View {
        Tile(title: c.title, symbol: c.symbol, caption: StickyModifiers.symbols(c.modifiers) + KeyNames.name(for: c.key)) {
            // Explicit shortcuts don't pick up armed sticky modifiers — they'd change their meaning.
            controller.input.send(.keyPress(code: c.key, modifiers: c.modifiers))
            finish()
        }
    }

    private func finish() {
        Haptics.shared.play(.click)
        dismiss()
    }
}

/// Transport, volume and brightness. Stays open for repeated presses.
private struct MediaControls: View {
    let controller: SessionController

    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                key(.previous); key(.playPause, large: true); key(.next)
            }
            HStack(spacing: 10) {
                key(.mute); key(.volumeDown); key(.volumeUp)
                Divider().frame(height: 28).overlay(.white.opacity(0.15))
                key(.brightnessDown); key(.brightnessUp)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity)
        .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .padding(.top, 6)
    }

    private func key(_ k: MediaKey, large: Bool = false) -> some View {
        Button {
            controller.input.media(k)
            Haptics.shared.play(.key)
        } label: {
            Image(systemName: k.symbol)
                .font(.system(size: large ? 22 : 16, weight: .semibold))
                .frame(maxWidth: .infinity, minHeight: large ? 48 : 40)
                .contentShape(Rectangle())
        }
        .buttonStyle(DockPressStyle())
        .foregroundStyle(.white)
        .accessibilityLabel(k.title)
    }
}

/// A labelled command tile.
struct Tile: View {
    var title: String
    var symbol: String
    var caption: String?
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: symbol)
                    .font(.system(size: 20, weight: .regular))
                    .frame(height: 24)
                    .foregroundStyle(Theme.accent)
                Text(title)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.white)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .minimumScaleFactor(0.85)
                if let caption {
                    Text(caption)
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 84)
            .padding(.horizontal, 6)
            .background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
        .buttonStyle(DockPressStyle())
        .accessibilityLabel(title)
        .accessibilityHint(caption.map { "Sends \($0)" } ?? "")
    }
}
