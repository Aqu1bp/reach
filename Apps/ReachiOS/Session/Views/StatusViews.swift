import SwiftUI
import ReachCore

/// Small glass capsule at the top: connection route + round trip. Shown briefly after connecting, while
/// the connection is degraded, or always (Settings → Show Connection Stats). Tap for details.
struct StatusPill: View {
    let controller: SessionController

    var body: some View {
        Button {
            controller.statsExpanded.toggle()
            // The pill stays while the panel is open (see SessionView); linger briefly after closing it.
            if !controller.statsExpanded { controller.flashPill(seconds: 2) }
        } label: {
            HStack(spacing: 7) {
                Circle()
                    .fill(quality.color)
                    .frame(width: 7, height: 7)
                    .shadow(color: quality.color.opacity(0.8), radius: 3)
                Image(systemName: routeSymbol)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.75))
                Text(controller.isDegraded ? "Weak Connection" : routeLabel)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(controller.isDegraded ? Theme.busy : .white)
                Text(Formatting.milliseconds(controller.roundTripMs))
                    .font(.footnote.monospacedDigit())
                    .foregroundStyle(.white.opacity(0.65))
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.white.opacity(0.5))
                    .rotationEffect(.degrees(controller.statsExpanded ? 180 : 0))
            }
            .lineLimit(1)
            .padding(.horizontal, 12)
            .frame(minHeight: 30)
            .glassSurface(in: Capsule(), interactive: true)
            .contentShape(Capsule())
        }
        .buttonStyle(DockPressStyle())
        .accessibilityLabel("Connection: \(routeLabel), round trip \(Formatting.milliseconds(controller.roundTripMs))")
        .accessibilityHint(controller.statsExpanded ? "Hides connection details" : "Shows connection details")
    }

    private var route: ConnectionRoute { controller.stats?.route ?? .unknown }

    private var routeLabel: String {
        if controller.host.isDemo && route == .unknown { return "Demo" }
        return route.label
    }

    private var routeSymbol: String {
        switch route {
        case .local: return "wifi"
        case .direct: return "globe"
        case .relayed: return "arrow.triangle.branch"
        case .unknown: return "antenna.radiowaves.left.and.right"
        }
    }

    private var quality: (color: Color, word: String) {
        guard let rtt = controller.roundTripMs else { return (Theme.offline, "unknown") }
        if controller.isDegraded || rtt > 150 { return (Theme.busy, "poor") }
        return rtt > 70 ? (Color.yellow, "fair") : (Theme.online, "good")
    }
}

/// Expanded connection details under the pill.
struct StatsPanel: View {
    let controller: SessionController
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        let s = controller.stats
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Image(systemName: MacGlyph.symbol(forModel: controller.host.model))
                    .font(.system(size: 20, weight: .light))
                    .frame(width: 30)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 1) {
                    Text(controller.host.name)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                    if let d = controller.activeDisplay {
                        Text(d.name)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
            }
            Divider().overlay(.white.opacity(0.12))
            Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 6) {
                row("Route", value: s.map { routeText($0) } ?? "—")
                row("Round trip", value: Formatting.milliseconds(controller.roundTripMs))
                row("Video", value: "\(Formatting.resolution(s?.frameWidth, s?.frameHeight)) · \(frameRate(s?.framesPerSecond))")
                row("Bitrate", value: Formatting.bitrate(s?.bitrateKbps))
                row("Decode", value: Formatting.milliseconds(s?.averageDecodeMs))
                row("Jitter buffer", value: Formatting.milliseconds(s?.jitterBufferMs))
                row("Lost / dropped", value: "\(s?.packetsLost ?? 0) pkts · \(s?.framesDropped ?? 0) frames")
                row("Quality", value: controller.quality.mode.title + " · \(controller.quality.maxFramesPerSecond) fps max")
            }
        }
        .padding(14)
        .frame(width: typeSize > .large ? 340 : 300)
        .glassSurface(in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .accessibilityElement(children: .contain)
    }

    /// The Mac only sends frames when something changes, so a still screen legitimately reads ~0 fps.
    private func frameRate(_ fps: Double?) -> String {
        if let fps, fps < 0.5 { return "idle" }
        return Formatting.fps(fps)
    }

    private func routeText(_ s: ConnectionStats) -> String {
        let net = Formatting.networkType(s.networkType)
        let proto = s.transportProtocol?.uppercased()
        return [s.route.label, net == "—" ? nil : net, proto].compactMap { $0 }.joined(separator: " · ")
    }

    private func row(_ title: String, value: String) -> some View {
        GridRow {
            Text(title)
                .foregroundStyle(.white.opacity(0.6))
            Text(value)
                .monospacedDigit()
                .foregroundStyle(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .font(.footnote)
    }
}

/// Transient confirmation ("Copied from Mac", "Touch Mode", …).
struct ToastView: View {
    let toast: SessionController.Toast

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: toast.symbol)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Theme.accent)
            Text(toast.message)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.white)
                .lineLimit(2)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .glassSurface(in: Capsule())
        .padding(.horizontal, 24)
        .accessibilityElement(children: .combine)
        .onAppear {
            UIAccessibility.post(notification: .announcement, argument: toast.message)
        }
    }
}

/// Debug overlay listing the most recent input messages (launch with `-inputLog`, or More → Input Log).
struct InputLogOverlay: View {
    let log: InputLog

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            ForEach(log.entries.suffix(9)) { e in
                HStack(spacing: 4) {
                    Text(e.text)
                    if e.count > 1 {
                        Text("×\(e.count)").foregroundStyle(Theme.accent)
                    }
                }
                .foregroundStyle(e.isPointer ? .white.opacity(0.55) : .white)
            }
        }
        .font(.system(size: 9, weight: .medium, design: .monospaced))
        .lineLimit(1)
        .padding(7)
        .frame(maxWidth: 230, alignment: .leading)
        .background(.black.opacity(0.62), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .padding(.leading, 10)
        .accessibilityHidden(true)
    }
}
