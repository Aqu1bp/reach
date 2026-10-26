import SwiftUI
import ReachCore

/// One paired Mac: model glyph, name, live status and when it was last used. Tap to connect.
struct HostCard: View {
    let entry: AppModel.HostEntry
    let availability: AppModel.Availability
    var onTap: () -> Void

    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        Button(action: onTap) {
            Group {
                // At accessibility text sizes the text gets the full card width, with the tile above it.
                if typeSize.isAccessibilitySize {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            tile
                            Spacer(minLength: 8)
                            chevron
                        }
                        details
                    }
                } else {
                    HStack(spacing: 16) {
                        tile
                        details
                        Spacer(minLength: 8)
                        chevron
                    }
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                RoundedRectangle(cornerRadius: 26, style: .continuous)
                    .fill(Theme.elevated)
                    .overlay {
                        RoundedRectangle(cornerRadius: 26, style: .continuous)
                            .strokeBorder(.white.opacity(0.07), lineWidth: 1)
                    }
            }
            .contentShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
        }
        .buttonStyle(CardPressStyle())
        .accessibilityElement(children: .combine)
        .accessibilityHint("Connects to this Mac")
    }

    private var tile: some View {
        MacTile(symbol: MacGlyph.symbol(forModel: model), lit: availability.isOnline)
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(entry.host.name)
                .font(.headline)
                .foregroundStyle(.white)
                .lineLimit(typeSize.isAccessibilitySize ? 4 : 2)
            StatusLabel(availability: availability)
            Text(Formatting.lastUsed(entry.host.lastConnectedAt))
                .font(.footnote)
                .foregroundStyle(.secondary)
                .lineLimit(typeSize.isAccessibilitySize ? 3 : 1)
        }
    }

    private var chevron: some View {
        Image(systemName: "chevron.right")
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(.tertiary)
            .accessibilityHidden(true)
    }

    private var model: String? {
        if case .online(let info, _) = availability { return info.model }
        return entry.model
    }
}

/// The Mac glyph on a softly lit tile (brighter while the Mac is reachable).
struct MacTile: View {
    var symbol: String
    var lit: Bool
    var size: CGFloat = 64

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
            .fill(LinearGradient(colors: lit ? [Theme.accent.opacity(0.38), Theme.accentDeep.opacity(0.55)]
                                             : [Color.white.opacity(0.10), Color.white.opacity(0.04)],
                                 startPoint: .topLeading, endPoint: .bottomTrailing))
            .overlay {
                RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
                    .strokeBorder(.white.opacity(lit ? 0.18 : 0.08), lineWidth: 1)
            }
            .overlay {
                Image(systemName: symbol)
                    .font(.system(size: size * 0.44, weight: .light))
                    .foregroundStyle(.white.opacity(lit ? 1 : 0.6))
            }
            .frame(width: size, height: size)
            .animation(.easeInOut(duration: 0.3), value: lit)
            .accessibilityHidden(true)
    }
}

/// "● Online" / "● In use by Sara's iPad" / "● Offline" / "Checking…".
struct StatusLabel: View {
    let availability: AppModel.Availability
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        HStack(spacing: 6) {
            switch availability {
            case .checking, .unknown:
                ProgressView()
                    .controlSize(.mini)
                    .tint(.secondary)
            default:
                Circle()
                    .fill(color)
                    .frame(width: 7, height: 7)
                    .shadow(color: color.opacity(availability.isOnline ? 0.8 : 0), radius: 3)
            }
            Text(text)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(availability.isOnline ? .white : .secondary)
                .lineLimit(typeSize.isAccessibilitySize ? 3 : 1)
        }
        .animation(.easeInOut(duration: 0.25), value: availability)
    }

    private var text: String {
        switch availability {
        case .unknown, .checking: return "Checking…"
        case .online(_, let user?): return "In use by \(user)"
        case .online: return "Online"
        case .offline: return "Offline"
        }
    }

    private var color: Color {
        switch availability {
        case .online(_, let user): return user == nil ? Theme.online : Theme.busy
        case .offline: return Theme.offline
        default: return Theme.offline
        }
    }
}

struct CardPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.975 : 1)
            .brightness(configuration.isPressed ? 0.04 : 0)
            .animation(.spring(response: 0.25, dampingFraction: 0.75), value: configuration.isPressed)
    }
}
