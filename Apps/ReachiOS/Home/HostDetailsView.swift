import SwiftUI
import ReachCore
import ReachProtocol

/// Everything known about a paired Mac, including both key fingerprints so the pairing can be checked
/// against what the Mac shows.
struct HostDetailsView: View {
    let entry: AppModel.HostEntry

    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var confirmForget = false

    var body: some View {
        let availability = model.availability(of: entry)
        let info: HostInfo? = {
            if case .online(let i, _) = availability { return i }
            return entry.host.info
        }()
        NavigationStack {
            List {
                Section {
                    HStack(spacing: 16) {
                        MacTile(symbol: MacGlyph.symbol(forModel: info?.model), lit: availability.isOnline, size: 72)
                        VStack(alignment: .leading, spacing: 6) {
                            Text(entry.host.name)
                                .font(.title3.weight(.semibold))
                            StatusLabel(availability: availability)
                        }
                    }
                    .padding(.vertical, 6)
                    .listRowBackground(Color.clear)
                }

                Section("Mac") {
                    LabeledContent("Model", value: info?.model ?? "—")
                    if let ident = info?.modelIdentifier { LabeledContent("Identifier", value: ident) }
                    LabeledContent("macOS", value: info?.osVersion ?? "—")
                    LabeledContent("Reach Host", value: info?.appVersion ?? "—")
                    // Set up in Reach Host's settings; only used when no direct connection works.
                    if let relay = entry.host.iceServers.first(where: \.isRelay) {
                        LabeledContent("Relay server", value: relay.urls.first.flatMap(TurnURL.init)?.host ?? "On")
                    }
                }

                Section {
                    LabeledContent("Mac’s key") {
                        Text(entry.host.fingerprint).monospaced()
                    }
                    LabeledContent("This iPhone’s key") {
                        Text(model.thisDeviceFingerprint).monospaced()
                    }
                } header: {
                    Text("Security")
                } footer: {
                    Text("These match the fingerprints shown in Reach Host on your Mac. Every connection is end‑to‑end encrypted and verified with these keys.")
                }

                Section("History") {
                    LabeledContent("Paired", value: entry.host.pairedAt.formatted(date: .abbreviated, time: .shortened))
                    LabeledContent("Last used", value: entry.host.lastConnectedAt?.formatted(.relative(presentation: .named)) ?? "Never")
                }

                Section {
                    Button(role: .destructive) {
                        confirmForget = true
                    } label: {
                        Label("Forget This Mac", systemImage: "trash")
                            .foregroundStyle(Theme.danger)
                    }
                }
            }
            .navigationTitle("Details")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.large])
        .confirmationDialog("Forget \(entry.host.name)?", isPresented: $confirmForget, titleVisibility: .visible) {
            Button("Forget Mac", role: .destructive) {
                dismiss()
                model.forget(entry)
            }
        } message: {
            Text("You’ll need to scan a new pairing code on the Mac to connect again.")
        }
    }
}
