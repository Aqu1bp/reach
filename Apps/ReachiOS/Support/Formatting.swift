import Foundation

enum Formatting {
    private static let relative: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .full
        return f
    }()

    /// "Last used 2 hours ago" / "Never connected".
    static func lastUsed(_ date: Date?, now: Date = Date()) -> String {
        guard let date else { return "Not connected yet" }
        if now.timeIntervalSince(date) < 60 { return "Last used just now" }
        return "Last used " + relative.localizedString(for: date, relativeTo: now)
    }

    static func milliseconds(_ v: Double?) -> String {
        guard let v, v.isFinite else { return "—" }
        // Same-network round trips can come back as 0 (below the stats' resolution); "0.0 ms" reads as broken.
        if v < 0.5 { return "<1 ms" }
        return v < 10 ? String(format: "%.1f ms", v) : String(format: "%.0f ms", v)
    }

    static func bitrate(_ kbps: Double?) -> String {
        guard let kbps, kbps.isFinite else { return "—" }
        return kbps >= 1000 ? String(format: "%.1f Mbps", kbps / 1000) : String(format: "%.0f kbps", kbps)
    }

    static func fps(_ v: Double?) -> String {
        guard let v, v.isFinite else { return "—" }
        return String(format: "%.0f fps", v)
    }

    static func resolution(_ w: Int?, _ h: Int?) -> String {
        guard let w, let h, w > 0, h > 0 else { return "—" }
        return "\(w) × \(h)"
    }

    static func networkType(_ t: String?) -> String {
        switch t?.lowercased() {
        case "wifi": return "Wi‑Fi"
        case "cellular": return "Cellular"
        case "ethernet": return "Ethernet"
        case "vpn": return "VPN"
        case nil, "": return "—"
        default: return t!.capitalized
        }
    }
}
