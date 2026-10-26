import UIKit

enum DeviceInfo {
    /// Hardware model identifier, e.g. "iPhone15,5". In the simulator, the simulated device's identifier.
    static let modelIdentifier: String = {
        if let sim = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"] { return sim }
        var info = utsname()
        uname(&info)
        let mirror = Mirror(reflecting: info.machine)
        let id = mirror.children.reduce(into: "") { result, element in
            guard let value = element.value as? Int8, value != 0 else { return }
            result.append(Character(UnicodeScalar(UInt8(value))))
        }
        return id.isEmpty ? "iPhone" : id
    }()

    static var appVersion: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = info?["CFBundleVersion"] as? String ?? "1"
        return "\(version) (\(build))"
    }

    /// Native pixel size of the screen the app is on, landscape-first (width ≥ height), so the Mac can
    /// choose a sensible stream size.
    @MainActor
    static var nativeScreenPixels: (width: Int, height: Int) {
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        let bounds = scene?.screen.nativeBounds ?? CGRect(x: 0, y: 0, width: 1290, height: 2796)
        let w = Int(max(bounds.width, bounds.height)), h = Int(min(bounds.width, bounds.height))
        return (w, h)
    }
}
