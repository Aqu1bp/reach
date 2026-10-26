import SwiftUI
import ReachProtocol

/// The full-screen session: the remote screen plus floating chrome (dock, keyboard bar, status, sheets).
struct SessionView: View {
    let controller: SessionController

    @AppStorage(SettingsKey.pointerSpeed) private var pointerSpeed = 1.0
    @AppStorage(SettingsKey.naturalScrolling) private var naturalScrolling = true
    @AppStorage(SettingsKey.showStats) private var showStats = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var dockCollapsed = LaunchOptions.dockCollapsed
    @State private var sheet: SessionSheet?
    @State private var showCompose = false
    @State private var coachMode: InputMode?
    @State private var didRunLaunchHooks = false

    enum SessionSheet: String, Identifiable {
        case shortcuts, apps, more
        var id: String { rawValue }
    }

    static let accessoryBarHeight: CGFloat = 60

    var body: some View {
        GeometryReader { geo in
            let landscape = geo.size.width > geo.size.height
            ZStack {
                RemoteCanvas(controller: controller,
                             config: GestureEngine.Config(mode: controller.inputMode, pointerSpeed: CGFloat(pointerSpeed),
                                                          naturalScrolling: naturalScrolling),
                             dimmed: isDimmed,
                             accessoryHeight: Self.accessoryBarHeight)
                    .ignoresSafeArea()

                if controller.hasFirstFrame || isLiveish {
                    liveChrome(landscape: landscape)
                }

                phaseOverlay
            }
        }
        .background(Color.black)
        .statusBarHidden(true)
        .persistentSystemOverlays(.hidden)
        .defersSystemGestures(on: .all)
        .preferredColorScheme(.dark)
        .sheet(item: $sheet, onDismiss: { controller.canvas?.reclaimFirstResponder() }) { which in
            switch which {
            case .shortcuts: ShortcutsSheet(controller: controller)
            case .apps: AppsSheet(controller: controller)
            case .more: MoreSheet(controller: controller, onShowGuide: showGuide)
            }
        }
        .sheet(isPresented: $showCompose, onDismiss: { controller.canvas?.reclaimFirstResponder() }) {
            ComposeSheet(controller: controller)
        }
        .onChange(of: controller.hasFirstFrame) { _, has in
            if has { firstFrameShown() }
        }
        .onChange(of: controller.inputMode) { _, mode in
            maybeShowCoach(for: mode)
        }
    }

    private var isLiveish: Bool {
        switch controller.phase {
        case .live, .reconnecting, .suspended: return true
        default: return false
        }
    }

    private var isDimmed: Bool {
        switch controller.phase {
        case .reconnecting, .suspended, .failed, .ended: return true
        default: return false
        }
    }

    // MARK: Chrome

    @ViewBuilder
    private func liveChrome(landscape: Bool) -> some View {
        // Top: status pill, stats, toasts.
        VStack(spacing: 8) {
            if controller.pillVisible || showStats || controller.statsExpanded {
                StatusPill(controller: controller)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
            if controller.statsExpanded {
                StatsPanel(controller: controller)
                    .dynamicTypeSize(...DynamicTypeSize.xxxLarge) // a dense table; larger sizes cover the screen
                    .transition(.scale(scale: 0.92, anchor: .top).combined(with: .opacity))
            }
            if let toast = controller.toast {
                ToastView(toast: toast)
                    .id(toast.id)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
            Spacer()
        }
        .padding(.top, landscape ? 10 : 4)
        // Heads-up chrome over the Mac's screen: grows with Dynamic Type, but stops at the first
        // accessibility size so it never covers most of the screen.
        .dynamicTypeSize(...DynamicTypeSize.accessibility1)
        .frame(maxWidth: .infinity, alignment: landscape ? .topLeading : .top)
        .padding(.leading, landscape ? 12 : 0)
        .animation(.reach(reduceMotion), value: controller.pillVisible)
        .animation(.reach(reduceMotion), value: controller.statsExpanded)
        .animation(.reach(reduceMotion), value: controller.toast)

        // Dock (hidden while typing: the keyboard bar takes over).
        if !controller.keyboardVisible, controller.phase == .live {
            DockView(controller: controller, collapsed: $dockCollapsed, vertical: landscape,
                     onShortcuts: { sheet = .shortcuts }, onApps: { sheet = .apps }, onMore: { sheet = .more })
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: landscape ? .trailing : .bottom)
                .padding(landscape ? .trailing : .bottom, landscape ? 10 : 6)
                .ignoresSafeArea(.keyboard)
                .transition(.opacity.combined(with: .scale(scale: 0.9)))
        }

        if controller.keyboardVisible {
            VStack {
                Spacer()
                KeyboardAccessoryBar(controller: controller, onCompose: { showCompose = true })
                    .frame(height: Self.accessoryBarHeight)
            }
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }

        if controller.log.isVisible {
            InputLogOverlay(log: controller.log)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: landscape ? .bottomLeading : .topLeading)
                .padding(landscape ? .leading : .top, landscape ? 12 : 64)
                .padding(.bottom, landscape ? 12 : 0)
                .allowsHitTesting(false)
        }

        if let mode = coachMode {
            GestureCoachView(mode: mode) {
                UserDefaults.standard.set(true, forKey: AppSettings.coachSeenKey(for: mode))
                withAnimation(.reach(reduceMotion)) { coachMode = nil }
            }
            .transition(.opacity)
        }
    }

    // MARK: Phases

    @ViewBuilder
    private var phaseOverlay: some View {
        switch controller.phase {
        case .connecting(let stage):
            ConnectingView(host: controller.host, stage: stage) { controller.disconnect() }
                .transition(.opacity)
        case .reconnecting, .suspended:
            if controller.hasFirstFrame {
                ReconnectingOverlay(onDisconnect: { controller.disconnect() })
                    .transition(.opacity)
            } else {
                ConnectingView(host: controller.host, stage: .finding) { controller.disconnect() }
            }
        case .failed(let message):
            FailureView(host: controller.host, title: "Couldn’t Connect", message: message, overFrame: controller.hasFirstFrame,
                        onRetry: { controller.reconnect() }, onClose: { controller.disconnect() })
                .transition(.opacity)
        case .ended(let reason):
            FailureView(host: controller.host, title: "Session Ended", message: reason, overFrame: controller.hasFirstFrame,
                        onRetry: { controller.reconnect() }, onClose: { controller.disconnect() })
                .transition(.opacity)
        case .live:
            EmptyView()
        }
    }

    // MARK: Launch hooks

    private func firstFrameShown() {
        maybeShowCoach(for: controller.inputMode)
        guard !didRunLaunchHooks else { return }
        didRunLaunchHooks = true
        guard let which = LaunchOptions.openSheet else { return }
        Task {
            try? await Task.sleep(for: .milliseconds(900))
            switch which {
            case "shortcuts": sheet = .shortcuts
            case "apps": sheet = .apps
            case "more": sheet = .more
            case "compose": showCompose = true
            case "stats": controller.statsExpanded = true
            case "keyboard": controller.keyboardVisible = true
            default: break
            }
        }
    }

    private func showGuide() {
        Task {
            // Let the sheet finish dismissing so the guide isn't covered by it.
            try? await Task.sleep(for: .milliseconds(450))
            withAnimation(.reach(reduceMotion)) { coachMode = controller.inputMode }
        }
    }

    private func maybeShowCoach(for mode: InputMode) {
        guard !LaunchOptions.skipCoach else { return }
        let seen = UserDefaults.standard.bool(forKey: AppSettings.coachSeenKey(for: mode))
        guard LaunchOptions.forceCoach || !seen, controller.hasFirstFrame else { return }
        withAnimation(.reach(reduceMotion)) { coachMode = mode }
    }
}
