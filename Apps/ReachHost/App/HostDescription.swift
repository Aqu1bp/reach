import Foundation
import IOKit
import ReachProtocol
import SystemConfiguration

/// What this Mac tells paired iPhones about itself.
enum HostDescription {
    static func current() -> HostInfo {
        let model = MacModel.current
        return HostInfo(name: computerName(), model: model.family, modelIdentifier: model.identifier,
                        osVersion: osVersion(), appVersion: appVersion())
    }

    /// The name from System Settings → General → Sharing (e.g. "Alex's MacBook Pro").
    static func computerName() -> String {
        if let name = SCDynamicStoreCopyComputerName(nil, nil) as String?, !name.isEmpty { return name }
        return Host.current().localizedName ?? "Mac"
    }

    static func osVersion() -> String {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        let patch = version.patchVersion > 0 ? ".\(version.patchVersion)" : ""
        return "macOS \(version.majorVersion).\(version.minorVersion)\(patch)"
    }

    static func appVersion() -> String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
    }
}

/// The Mac's hardware model.
struct MacModel: Equatable {
    /// e.g. "Mac14,6" or "MacBookPro18,3".
    let identifier: String
    /// e.g. "MacBook Pro (14-inch, M5)", when the system provides it.
    let productName: String?
    /// Marketing family, e.g. "MacBook Pro".
    let family: String

    static let current: MacModel = {
        let identifier = sysctlString("hw.model") ?? "Mac"
        let productName = deviceTreeProductName()
        return MacModel(identifier: identifier, productName: productName,
                        family: productName.map(family(fromProductName:)) ?? family(forIdentifier: identifier))
    }()

    /// SF Symbol for the family.
    var symbolName: String { Self.symbolName(forFamily: family) }

    static func symbolName(forFamily family: String) -> String {
        switch family {
        case "MacBook Pro", "MacBook Air", "MacBook": return "laptopcomputer"
        case "Mac mini": return "macmini"
        case "Mac Studio": return "macstudio"
        case "Mac Pro": return "macpro.gen3"
        default: return "desktopcomputer"
        }
    }

    /// "MacBook Pro (14-inch, M5)" → "MacBook Pro".
    static func family(fromProductName name: String) -> String {
        let base = name.split(separator: "(", maxSplits: 1).first.map(String.init) ?? name
        let trimmed = base.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? "Mac" : trimmed
    }

    /// Fallback when the device tree has no product name (Intel Macs, older systems).
    static func family(forIdentifier identifier: String) -> String {
        // Legacy identifiers name the family; check longer prefixes first ("MacBookPro" before "MacBook").
        let prefixes: [(String, String)] = [
            ("MacBookPro", "MacBook Pro"), ("MacBookAir", "MacBook Air"), ("MacBook", "MacBook"),
            ("iMacPro", "iMac Pro"), ("iMac", "iMac"), ("Macmini", "Mac mini"), ("MacPro", "Mac Pro"),
        ]
        if let match = prefixes.first(where: { identifier.hasPrefix($0.0) }) { return match.1 }
        // Apple silicon identifiers ("MacNN,M") don't, so they need a table (Apple's published list).
        let appleSilicon: [String: String] = [
            "Mac13,1": "Mac Studio", "Mac13,2": "Mac Studio",
            "Mac14,2": "MacBook Air", "Mac14,15": "MacBook Air", "Mac14,3": "Mac mini", "Mac14,12": "Mac mini",
            "Mac14,5": "MacBook Pro", "Mac14,6": "MacBook Pro", "Mac14,7": "MacBook Pro", "Mac14,9": "MacBook Pro",
            "Mac14,10": "MacBook Pro", "Mac14,8": "Mac Pro", "Mac14,13": "Mac Studio", "Mac14,14": "Mac Studio",
            "Mac15,3": "MacBook Pro", "Mac15,4": "iMac", "Mac15,5": "iMac", "Mac15,6": "MacBook Pro",
            "Mac15,7": "MacBook Pro", "Mac15,8": "MacBook Pro", "Mac15,9": "MacBook Pro", "Mac15,10": "MacBook Pro",
            "Mac15,11": "MacBook Pro", "Mac15,12": "MacBook Air", "Mac15,13": "MacBook Air", "Mac15,14": "Mac Studio",
            "Mac16,1": "MacBook Pro", "Mac16,2": "iMac", "Mac16,3": "iMac", "Mac16,5": "MacBook Pro",
            "Mac16,6": "MacBook Pro", "Mac16,7": "MacBook Pro", "Mac16,8": "MacBook Pro", "Mac16,9": "Mac Studio",
            "Mac16,10": "Mac mini", "Mac16,11": "Mac mini", "Mac16,12": "MacBook Air", "Mac16,13": "MacBook Air",
            "Mac17,2": "MacBook Pro",
        ]
        return appleSilicon[identifier] ?? "Mac"
    }

    private static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        return String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    /// Apple silicon Macs publish their marketing name in the device tree (`/product`, "product-name").
    private static func deviceTreeProductName() -> String? {
        let entry = IORegistryEntryFromPath(kIOMainPortDefault, "IODeviceTree:/product")
        guard entry != MACH_PORT_NULL else { return nil }
        defer { IOObjectRelease(entry) }
        guard let value = IORegistryEntryCreateCFProperty(entry, "product-name" as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? Data else { return nil }
        let name = String(decoding: value.prefix { $0 != 0 }, as: UTF8.self).trimmingCharacters(in: .whitespaces)
        return name.isEmpty ? nil : name
    }
}
