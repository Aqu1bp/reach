import Foundation
import ReachProtocol

/// SF Symbol that best depicts a Mac, from its marketing model name ("MacBook Pro", "Mac mini", …).
enum MacGlyph {
    static func symbol(forModel model: String?) -> String {
        let m = (model ?? "").lowercased()
        if m.contains("macbook") { return "macbook" }
        if m.contains("imac") { return "desktopcomputer" }
        if m.contains("mini") { return "macmini" }
        if m.contains("studio") { return "macstudio" }
        if m.contains("mac pro") || m == "macpro" { return "macpro.gen3" }
        if m.contains("virtual") || m.contains("vm") { return "display" }
        return "macbook"
    }

    static func symbol(for info: HostInfo?) -> String { symbol(forModel: info?.model) }
}
