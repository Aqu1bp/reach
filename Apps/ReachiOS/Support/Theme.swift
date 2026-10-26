import SwiftUI

/// Shared visual language. The app is dark-only: the remote screen is the hero, chrome stays quiet.
enum Theme {
    /// Electric blue accent (#4D95FF), also the icon's highlight.
    static let accent = Color(red: 0.302, green: 0.584, blue: 1.0)
    static let accentDeep = Color(red: 0.07, green: 0.20, blue: 0.55)
    static let background = Color(red: 0.035, green: 0.04, blue: 0.055)
    static let elevated = Color(red: 0.085, green: 0.09, blue: 0.11)
    static let online = Color(red: 0.25, green: 0.84, blue: 0.47)
    static let busy = Color(red: 1.0, green: 0.68, blue: 0.22)
    static let offline = Color(white: 0.45)
    static let danger = Color(red: 1.0, green: 0.36, blue: 0.36)

    /// Soft accent glow used behind hero content (empty state, connecting, pairing success).
    static func glow(_ color: Color = accent, radius: CGFloat = 260) -> some View {
        RadialGradient(colors: [color.opacity(0.28), color.opacity(0.0)], center: .center, startRadius: 0, endRadius: radius)
    }

    static var backdrop: some View {
        ZStack {
            background
            LinearGradient(colors: [Color(red: 0.06, green: 0.08, blue: 0.14), background],
                           startPoint: .top, endPoint: .center)
        }
        .ignoresSafeArea()
    }
}

extension Animation {
    /// Snappy spring used for chrome transitions; collapses to a fade-speed change under Reduce Motion.
    static func reach(_ reduceMotion: Bool) -> Animation {
        reduceMotion ? .easeInOut(duration: 0.18) : .spring(response: 0.38, dampingFraction: 0.82)
    }
}
