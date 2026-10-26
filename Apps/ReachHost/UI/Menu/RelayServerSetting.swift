import SwiftUI

/// The optional relay (TURN) server: one row in settings that opens an inline editor (inline, like
/// removing a device, because sheets and alerts detach awkwardly from a menu bar panel).
struct RelayServerSetting: View {
    let model: AppModel
    @State private var isEditing: Bool

    init(model: AppModel, isEditing: Bool = false) {
        self.model = model
        _isEditing = State(initialValue: isEditing)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if isEditing {
                RelayServerEditor(server: model.turnServer,
                                  onSave: { try model.setTurnServer($0) },
                                  onDone: { isEditing = false })
                    .transition(.opacity)
            } else {
                row
            }
        }
        .animation(.snappy(duration: 0.2), value: isEditing)
    }

    private var row: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text("Relay server (TURN)")
                    .font(.system(size: 13))
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Button(model.turnServer == nil ? "Set Up…" : "Edit…") { isEditing = true }
                .controlSize(.small)
        }
        .padding(.horizontal, 6)
    }

    private var subtitle: String {
        guard let server = model.turnServer else { return "Only if your iPhone can't connect directly." }
        return "On · \(server.displayHost)"
    }
}

private struct RelayServerEditor: View {
    let server: TurnServer?
    let onSave: (TurnServer?) throws -> Void
    let onDone: () -> Void

    @State private var urls: String
    @State private var username: String
    @State private var credential: String
    @State private var problem: String?

    init(server: TurnServer?, onSave: @escaping (TurnServer?) throws -> Void, onDone: @escaping () -> Void) {
        self.server = server
        self.onSave = onSave
        self.onDone = onDone
        _urls = State(initialValue: server?.urls.joined(separator: ", ") ?? "")
        _username = State(initialValue: server?.username ?? "")
        _credential = State(initialValue: server?.credential ?? "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Relay server (TURN)")
                    .font(.system(size: 12, weight: .semibold))
                Text("Only needed if your iPhone can't connect directly, like on very restrictive networks. "
                     + "Your screen then goes through this server, still end-to-end encrypted.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            VStack(spacing: 6) {
                TextField("Server", text: $urls, prompt: Text("turn:relay.example.com:3478"))
                    .help("One or more turn: or turns: addresses for the same server, separated by commas.")
                TextField("Username", text: $username, prompt: Text("Username"))
                SecureField("Password", text: $credential, prompt: Text("Password"))
            }
            .textFieldStyle(.roundedBorder)
            .labelsHidden()
            .autocorrectionDisabled()
            if let problem {
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text(problem)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .font(.system(size: 11))
            }
            HStack {
                if server != nil {
                    Button("Remove", role: .destructive) { save(nil) }
                }
                Spacer()
                Button("Cancel", action: onDone)
                    .keyboardShortcut(.cancelAction)
                Button("Save", action: submit)
                    .keyboardShortcut(.defaultAction)
            }
            .controlSize(.small)
        }
        .card()
    }

    private func submit() {
        switch TurnServer.parse(urls: urls, username: username, credential: credential) {
        case .success(let parsed): save(parsed)
        case .failure(let failure): problem = failure.message
        }
    }

    private func save(_ server: TurnServer?) {
        do {
            try onSave(server)
            onDone()
        } catch {
            problem = "Couldn't save the password in the keychain."
        }
    }
}
