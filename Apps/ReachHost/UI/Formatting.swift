import Foundation
import ReachCore

/// Human-facing strings derived from model values. Pure, so they can be self-tested.
enum Formatting {
    /// "18 ms"; sub-millisecond rounds up so a LAN never reads "0 ms".
    static func roundTrip(_ milliseconds: Double) -> String {
        guard milliseconds.isFinite, milliseconds >= 0 else { return "–" }
        return "\(max(1, Int(milliseconds.rounded()))) ms"
    }

    /// "Local network · 4 ms", "Relayed · 82 ms", or just the route while RTT is unknown.
    static func link(route: ConnectionRoute?, roundTripMs: Double?) -> String {
        var parts: [String] = []
        parts.append(route?.label ?? "Connecting")
        if let roundTripMs { parts.append(roundTrip(roundTripMs)) }
        return parts.joined(separator: " · ")
    }

    /// "Just now", "5 min", "2 hr 10 min" — compact elapsed time for a session.
    static func duration(_ interval: TimeInterval) -> String {
        guard interval >= 60 else { return "Just now" }
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = interval >= 3600 ? [.hour, .minute] : [.minute]
        formatter.unitsStyle = .short
        formatter.maximumUnitCount = 2
        return formatter.string(from: interval) ?? "Just now"
    }

    /// "Last used 2 hours ago" or "Paired yesterday".
    static func lastSeen(pairedAt: Date, lastConnectedAt: Date?, now: Date = Date()) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        formatter.dateTimeStyle = .named
        if let lastConnectedAt {
            return "Last used " + relative(lastConnectedAt, now: now, formatter: formatter)
        }
        return "Paired " + relative(pairedAt, now: now, formatter: formatter)
    }

    /// "9:41" for a countdown.
    static func countdown(_ remaining: TimeInterval) -> String {
        let seconds = max(0, Int(remaining.rounded(.up)))
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }

    private static func relative(_ date: Date, now: Date, formatter: RelativeDateTimeFormatter) -> String {
        // Clock skew or very recent events would otherwise read "in 2 seconds".
        if now.timeIntervalSince(date) < 60 { return "just now" }
        return formatter.localizedString(for: date, relativeTo: now)
    }
}
