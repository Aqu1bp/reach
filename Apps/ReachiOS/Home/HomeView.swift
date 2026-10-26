import SwiftUI
import ReachCore

/// Paired Macs as cards with live status; tap to connect. Empty state walks through pairing.
struct HomeView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase

    @State private var details: AppModel.HostEntry?
    @State private var forgetting: AppModel.HostEntry?
    @State private var takingOver: AppModel.HostEntry?

    var body: some View {
        @Bindable var model = model
        NavigationStack {
            ZStack {
                Theme.backdrop
                if model.hosts.isEmpty {
                    EmptyStateView(onScan: { model.beginPairing(.scan) }, onPaste: { model.beginPairing(.paste) })
                        .transition(.opacity)
                } else {
                    hostList
                }
            }
            .navigationTitle("Reach")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button { model.beginPairing(.scan) } label: { Label("Scan Pairing Code", systemImage: "qrcode.viewfinder") }
                        Button { model.beginPairing(.paste) } label: { Label("Paste Pairing Code", systemImage: "doc.on.clipboard") }
                    } label: {
                        Image(systemName: "plus")
                    }
                    .accessibilityLabel("Add a Mac")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { model.showSettings = true } label: { Image(systemName: "gearshape") }
                        .accessibilityLabel("Settings")
                }
            }
            .animation(.reach(reduceMotion), value: model.hosts.map(\.id))
        }
        .fullScreenCover(item: $model.pairing) { request in
            PairingView(request: request)
        }
        .sheet(isPresented: $model.showSettings) {
            SettingsView()
        }
        .sheet(item: $details) { entry in
            HostDetailsView(entry: entry)
        }
        .confirmationDialog(forgetting.map { "Forget \($0.host.name)?" } ?? "",
                            isPresented: Binding(get: { forgetting != nil }, set: { if !$0 { forgetting = nil } }),
                            titleVisibility: .visible, presenting: forgetting) { entry in
            Button("Forget Mac", role: .destructive) {
                withAnimation(.reach(reduceMotion)) { model.forget(entry) }
                details = nil
            }
        } message: { _ in
            Text("You’ll need to scan a new pairing code on the Mac to connect again.")
        }
        .confirmationDialog(takeOverTitle, isPresented: Binding(get: { takingOver != nil }, set: { if !$0 { takingOver = nil } }),
                            titleVisibility: .visible, presenting: takingOver) { entry in
            Button("Connect") { model.connect(entry) }
        } message: { _ in
            Text("Connecting will end the other device’s session.")
        }
        .task { await model.refreshAvailability() }
        .onAppear(perform: openLaunchPanel)
    }

    // MARK: List

    private var hostList: some View {
        ScrollView {
            LazyVStack(spacing: 14) {
                if !model.relaysReachable {
                    RelayBanner()
                }
                ForEach(model.hosts) { entry in
                    HostCard(entry: entry, availability: model.availability(of: entry)) {
                        tap(entry)
                    }
                    .contextMenu {
                        Button { model.connect(entry) } label: { Label("Connect", systemImage: "play.fill") }
                        Button { details = entry } label: { Label("Details", systemImage: "info.circle") }
                        Divider()
                        Button(role: .destructive) { forgetting = entry } label: { Label("Forget This Mac", systemImage: "trash") }
                    }
                    .transition(.asymmetric(insertion: .scale(scale: 0.96).combined(with: .opacity), removal: .opacity))
                }
                AddMacCard { model.beginPairing(.scan) }
                    .padding(.top, 4)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .frame(maxWidth: 640)
            .frame(maxWidth: .infinity)
        }
        .refreshable { await model.refreshAvailability() }
    }

    private var takeOverTitle: String {
        guard let entry = takingOver, case .online(_, let user?) = model.availability(of: entry) else { return "" }
        return "\(user) is using \(entry.host.name)"
    }

    private func tap(_ entry: AppModel.HostEntry) {
        if case .online(_, let user) = model.availability(of: entry), user != nil {
            takingOver = entry
        } else {
            model.connect(entry)
        }
    }

    private func openLaunchPanel() {
        switch LaunchOptions.openHome {
        case "settings": model.showSettings = true
        case "details": details = model.hosts.first
        default: break
        }
    }
}

/// Shown when the relays can't be reached (no internet) — local Macs may still work.
private struct RelayBanner: View {
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "wifi.exclamationmark")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(Theme.busy)
            VStack(alignment: .leading, spacing: 2) {
                Text("No Internet Connection")
                    .font(.subheadline.weight(.semibold))
                Text("Macs on this network may still connect. Others will once you’re back online.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .background(Theme.busy.opacity(0.12), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}

/// Dashed "add" card at the end of the list.
private struct AddMacCard: View {
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: "plus.circle.fill")
                    .font(.system(size: 20))
                    .foregroundStyle(Theme.accent)
                Text("Add a Mac")
                    .font(.body.weight(.medium))
                    .foregroundStyle(.white)
            }
            .frame(maxWidth: .infinity, minHeight: 60)
            .background {
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .strokeBorder(.white.opacity(0.16), style: StrokeStyle(lineWidth: 1.2, dash: [6, 5]))
            }
            .contentShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        }
        .buttonStyle(DockPressStyle())
        .accessibilityHint("Scan the pairing code shown on your Mac")
    }
}
