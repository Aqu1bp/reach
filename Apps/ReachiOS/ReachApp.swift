import SwiftUI
import ReachCore

@main
struct ReachApp: App {
    @State private var model = AppModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                .preferredColorScheme(.dark)
                .tint(Theme.accent)
                // `reach://pair?...` — scanning the Mac's code with the Camera app opens Reach here.
                .onOpenURL { model.handleOpenURL($0) }
        }
        .onChange(of: scenePhase) { _, phase in model.scenePhaseChanged(phase) }
    }
}

struct RootView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        HomeView()
            .fullScreenCover(item: $model.session) { session in
                SessionView(controller: session)
            }
            .alert(model.alert?.title ?? "",
                   isPresented: Binding(get: { model.alert != nil }, set: { if !$0 { model.alert = nil } }),
                   presenting: model.alert) { _ in
                Button("OK", role: .cancel) {}
            } message: { alert in
                Text(alert.message)
            }
            .task {
                if LaunchOptions.landscape, let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene {
                    scene.requestGeometryUpdate(.iOS(interfaceOrientations: .landscapeRight))
                }
                try? await Task.sleep(for: .milliseconds(300))
                model.autoConnectDemoIfRequested()
            }
    }
}
