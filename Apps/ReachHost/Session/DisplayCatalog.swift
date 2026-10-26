import AppKit
import ReachCore
import ReachProtocol

/// The Mac's displays, kept current across resolution changes and displays coming and going.
@MainActor
final class DisplayCatalog {
    /// Called (debounced) after the display arrangement or a display mode changes.
    var onChange: (() -> Void)?

    private(set) var displays: [DisplayInfo] = []
    private var pendingChange: DispatchWorkItem?
    private var registered = false

    init() {
        displays = Self.enumerate()
    }

    func startObserving() {
        guard !registered else { return }
        let context = Unmanaged.passUnretained(self).toOpaque()
        let result = CGDisplayRegisterReconfigurationCallback({ _, flags, context in
            // Each change is reported twice: once before (`beginConfigurationFlag`) and once after.
            guard !flags.contains(.beginConfigurationFlag), let context else { return }
            let catalog = Unmanaged<DisplayCatalog>.fromOpaque(context).takeUnretainedValue()
            onMain { catalog.scheduleRefresh() }
        }, context)
        registered = result == .success
        if !registered { ReachLog.error("host", "display reconfiguration callback failed: \(result.rawValue)") }
    }

    func display(id: DisplayID) -> DisplayInfo? {
        displays.first { $0.id == id }
    }

    var mainDisplay: DisplayInfo? {
        displays.first(where: \.isMain) ?? displays.first
    }

    func refresh() {
        displays = Self.enumerate()
    }

    /// A reconfiguration arrives as a burst of callbacks (one per display, plus mode changes); act
    /// once things settle.
    private func scheduleRefresh() {
        pendingChange?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let previous = self.displays
            self.refresh()
            if self.displays != previous {
                ReachLog.info("host", "displays changed: \(self.displays.map { "\($0.name) \($0.pixelWidth)×\($0.pixelHeight)" })")
                self.onChange?()
            }
        }
        pendingChange = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
    }

    // MARK: - Enumeration

    static func enumerate() -> [DisplayInfo] {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else { return [] }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &ids, &count) == .success else { return [] }
        let screens = Dictionary(NSScreen.screens.compactMap { screen -> (CGDirectDisplayID, NSScreen)? in
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return nil }
            return (CGDirectDisplayID(number.uint32Value), screen)
        }, uniquingKeysWith: { first, _ in first })
        let mainID = CGMainDisplayID()

        let infos = ids.prefix(Int(count)).compactMap { id -> DisplayInfo? in
            // A mirror shows another display's content; offer only the source.
            guard CGDisplayMirrorsDisplay(id) == kCGNullDirectDisplay else { return nil }
            let bounds = CGDisplayBounds(id)
            let mode = CGDisplayCopyDisplayMode(id)
            let screen = screens[id]
            let refresh = screen.map { Double($0.maximumFramesPerSecond) } ?? mode?.refreshRate ?? 60
            return DisplayInfo(
                id: id,
                name: screen?.localizedName ?? (CGDisplayIsBuiltin(id) != 0 ? "Built-in Display" : "Display"),
                frame: Rect(x: bounds.minX, y: bounds.minY, width: bounds.width, height: bounds.height),
                pixelWidth: mode?.pixelWidth ?? Int(bounds.width),
                pixelHeight: mode?.pixelHeight ?? Int(bounds.height),
                isMain: id == mainID,
                refreshRate: refresh > 0 ? refresh : 60)
        }
        // Main display first, then left to right.
        return infos.sorted { lhs, rhs in
            if lhs.isMain != rhs.isMain { return lhs.isMain }
            return lhs.frame.x < rhs.frame.x
        }
    }
}

extension DisplayInfo {
    var cgFrame: CGRect { CGRect(x: frame.x, y: frame.y, width: frame.width, height: frame.height) }
}
