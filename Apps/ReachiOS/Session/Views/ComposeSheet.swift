import SwiftUI
import ReachProtocol

/// Write longer text with the full iOS editor (autocorrect, dictation, paste) and send it in one go.
struct ComposeSheet: View {
    let controller: SessionController

    @Environment(\.dismiss) private var dismiss
    @AppStorage("compose.pressReturn") private var pressReturn = false
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                TextEditor(text: $text)
                    .focused($focused)
                    .font(.body)
                    .scrollContentBackground(.hidden)
                    .padding(12)
                    .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .overlay(alignment: .topLeading) {
                        if text.isEmpty {
                            Text("Type or dictate, then send it to your Mac…")
                                .foregroundStyle(.tertiary)
                                .padding(.horizontal, 17)
                                .padding(.vertical, 20)
                                .allowsHitTesting(false)
                                .accessibilityHidden(true)
                        }
                    }
                    .accessibilityLabel("Text to send")
                    .padding(.horizontal, 16)
                    .padding(.top, 8)

                Toggle("Press Return after sending", isOn: $pressReturn)
                    .font(.subheadline)
                    .tint(Theme.accent)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 12)
            }
            .navigationTitle("Compose")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Send", action: send)
                        .fontWeight(.semibold)
                        .disabled(text.isEmpty)
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .onAppear { focused = true }
    }

    private func send() {
        controller.input.plainText(text)
        if pressReturn { controller.input.send(.keyPress(code: MacKey.returnKey, modifiers: [])) }
        Haptics.shared.play(.click)
        dismiss()
    }
}
