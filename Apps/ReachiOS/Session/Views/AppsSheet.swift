import SwiftUI
import ReachProtocol

/// Running apps (tap to bring forward) and open windows (tap to focus and zoom to it).
struct AppsSheet: View {
    let controller: SessionController
    @Environment(\.dismiss) private var dismiss
    @State private var tab: Tab = LaunchOptions.openSheetTab == "windows" ? .windows : .apps

    enum Tab: String, CaseIterable, Identifiable {
        case apps = "Apps", windows = "Windows"
        var id: String { rawValue }
    }

    private let columns = [GridItem(.adaptive(minimum: 78, maximum: 110), spacing: 14)]

    var body: some View {
        NavigationStack {
            Group {
                switch tab {
                case .apps: appsGrid
                case .windows: windowsList
                }
            }
            .safeAreaInset(edge: .top, spacing: 0) {
                Picker("View", selection: $tab) {
                    ForEach(Tab.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 16)
                .padding(.bottom, 8)
            }
            .navigationTitle(tab == .apps ? "Apps" : "Windows")
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
        .onAppear { controller.requestApps() }
    }

    // MARK: Apps

    @ViewBuilder
    private var appsGrid: some View {
        if controller.apps.isEmpty {
            placeholder("No Apps Yet", symbol: "square.grid.2x2", message: "Running apps on your Mac will appear here.")
        } else {
            ScrollView {
                LazyVGrid(columns: columns, spacing: 18) {
                    ForEach(controller.apps) { app in
                        Button {
                            controller.activate(app)
                            dismiss()
                        } label: {
                            AppCell(app: app)
                        }
                        .buttonStyle(DockPressStyle())
                    }
                }
                .padding(16)
            }
        }
    }

    // MARK: Windows

    @ViewBuilder
    private var windowsList: some View {
        if controller.windows.isEmpty {
            placeholder("No Windows", symbol: "macwindow", message: "Open windows on your Mac will appear here.")
        } else {
            List {
                ForEach(groupedWindows, id: \.app) { group in
                    Section {
                        ForEach(group.windows) { w in
                            Button {
                                controller.focus(w)
                                dismiss()
                            } label: {
                                WindowRow(window: w, displayName: displayName(for: w))
                            }
                            .listRowBackground(Color.white.opacity(0.06))
                        }
                    } header: {
                        HStack(spacing: 8) {
                            AppIcon(data: icon(forPID: group.windows.first?.pid), size: 18)
                            Text(group.app)
                        }
                    }
                }
            }
            .scrollContentBackground(.hidden)
        }
    }

    private var groupedWindows: [(app: String, windows: [WindowInfo])] {
        var order: [String] = []
        var map: [String: [WindowInfo]] = [:]
        for w in controller.windows {
            if map[w.appName] == nil { order.append(w.appName) }
            map[w.appName, default: []].append(w)
        }
        return order.map { ($0, map[$0] ?? []) }
    }

    private func icon(forPID pid: Int32?) -> Data? {
        controller.apps.first { $0.pid == pid }?.icon
    }

    private func displayName(for w: WindowInfo) -> String? {
        guard controller.displays.count > 1 else { return nil }
        return controller.displays.first { $0.frame.contains(x: w.frame.midX, y: w.frame.midY) }?.name
    }

    private func placeholder(_ title: String, symbol: String, message: String) -> some View {
        ContentUnavailableView {
            Label(title, systemImage: symbol)
        } description: {
            Text(message)
        }
        .frame(maxHeight: .infinity)
    }
}

private struct AppCell: View {
    let app: AppInfo

    var body: some View {
        VStack(spacing: 6) {
            AppIcon(data: app.icon, size: 56)
                .opacity(app.isHidden ? 0.5 : 1)
            Text(app.name)
                .font(.caption.weight(.medium))
                .foregroundStyle(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
                .truncationMode(.middle)
            Circle()
                .fill(app.isActive ? Theme.accent : .white.opacity(0.35))
                .frame(width: 4, height: 4)
                .opacity(app.isActive || !app.isHidden ? 1 : 0)
        }
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(app.name)
        .accessibilityValue(app.isActive ? "Frontmost" : app.isHidden ? "Hidden" : "")
        .accessibilityAddTraits(.isButton)
        .accessibilityHint("Brings \(app.name) to the front")
    }
}

private struct WindowRow: View {
    let window: WindowInfo
    let displayName: String?

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: window.isOnScreen ? "macwindow" : "macwindow.badge.plus")
                .font(.system(size: 17))
                .foregroundStyle(window.isOnScreen ? Theme.accent : Color.white.opacity(0.45))
                .frame(width: 26)
            VStack(alignment: .leading, spacing: 2) {
                Text(window.title.isEmpty ? window.appName : window.title)
                    .font(.body)
                    .foregroundStyle(.white)
                    .lineLimit(1)
                let detail = [window.isOnScreen ? nil : "Minimized or on another Space", displayName].compactMap { $0 }
                if !detail.isEmpty {
                    // Explicit colours: inside a List button, hierarchical styles pick up the tint.
                    Text(detail.joined(separator: " · "))
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.55))
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
            Image(systemName: "arrow.up.left.and.arrow.down.right")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white.opacity(0.3))
                .accessibilityHidden(true)
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityHint("Focuses this window and zooms to it")
    }
}

/// A Mac app icon from host-provided PNG data, decoded once and cached.
struct AppIcon: View {
    let data: Data?
    var size: CGFloat

    var body: some View {
        Group {
            if let image = AppIconCache.image(for: data) {
                Image(uiImage: image)
                    .resizable()
                    .interpolation(.high)
            } else {
                RoundedRectangle(cornerRadius: size * 0.225, style: .continuous)
                    .fill(.white.opacity(0.1))
                    .overlay {
                        Image(systemName: "app.dashed")
                            .font(.system(size: size * 0.45))
                            .foregroundStyle(.secondary)
                    }
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

@MainActor
enum AppIconCache {
    private static let cache: NSCache<NSData, UIImage> = {
        let c = NSCache<NSData, UIImage>()
        c.countLimit = 128
        return c
    }()

    static func image(for data: Data?) -> UIImage? {
        guard let data, !data.isEmpty else { return nil }
        let key = data as NSData
        if let hit = cache.object(forKey: key) { return hit }
        guard let image = UIImage(data: data) else { return nil }
        cache.setObject(image, forKey: key)
        return image
    }
}
