import SwiftUI

struct FooterBar: View {
    let model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button(action: model.showOnboarding) {
                Text("Setup Guide…")
            }
            .buttonStyle(.menuRow)
            Button(action: model.quit) {
                HStack {
                    Text("Quit Reach Host")
                    Spacer()
                    Text("⌘Q")
                        .foregroundStyle(.secondary)
                }
            }
            .buttonStyle(.menuRow)
            .keyboardShortcut("q")
            Text("Version \(model.hostInfo.appVersion) · Key fingerprint \(model.fingerprint)")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
                .textSelection(.enabled)
                .padding(.horizontal, 6)
                .padding(.top, 4)
                .help("Reach on your iPhone shows the same fingerprint in this Mac's details.")
        }
    }
}
