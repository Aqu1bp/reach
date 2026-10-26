import ReachProtocol

/// Splits an app list whose icons won't fit in one control message.
///
/// `HostEngine` doesn't chunk control messages and SCTP drops very large ones (it warns above
/// 200 KB), while 30 apps with 64 pt @2x icons easily exceed that once base64-encoded. Every batch
/// carries the *full* list — the iPhone replaces its list with each `.apps` and keeps icons it
/// already has — with icons for only some of the apps.
enum AppListBatcher {
    /// Base64-encoded icon bytes allowed per message, leaving room for the list itself.
    static let iconBudget = 150_000

    static func batches(_ apps: [AppInfo], iconBudget: Int = iconBudget) -> [[AppInfo]] {
        var groups: [Set<Int>] = []
        var current: Set<Int> = []
        var used = 0
        for (index, app) in apps.enumerated() {
            guard let icon = app.icon else { continue }
            let cost = (icon.count + 2) / 3 * 4
            if !current.isEmpty && used + cost > iconBudget {
                groups.append(current)
                current = []
                used = 0
            }
            current.insert(index)
            used += cost
        }
        if !current.isEmpty { groups.append(current) }
        guard groups.count > 1 else { return [apps] }
        return groups.map { group in
            apps.enumerated().map { index, app in
                var app = app
                if !group.contains(index) { app.icon = nil }
                return app
            }
        }
    }
}
