import Foundation

// MARK: - Geometry

/// A rectangle in macOS global display coordinates (points, origin at the top-left of the main display,
/// y grows downward) — the same space `CGEvent` and `CGWindowListCopyWindowInfo` use.
public struct Rect: Codable, Hashable, Sendable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x; self.y = y; self.width = width; self.height = height
    }

    public var midX: Double { x + width / 2 }
    public var midY: Double { y + height / 2 }
    public var maxX: Double { x + width }
    public var maxY: Double { y + height }

    public func contains(x px: Double, y py: Double) -> Bool {
        px >= x && px < maxX && py >= y && py < maxY
    }

    public func intersection(_ other: Rect) -> Rect? {
        let nx = max(x, other.x), ny = max(y, other.y)
        let mx = min(maxX, other.maxX), my = min(maxY, other.maxY)
        guard mx > nx, my > ny else { return nil }
        return Rect(x: nx, y: ny, width: mx - nx, height: my - ny)
    }
}

// MARK: - Host description

public typealias DisplayID = UInt32

public struct DisplayInfo: Codable, Hashable, Sendable, Identifiable {
    public var id: DisplayID
    public var name: String
    /// Frame in global points.
    public var frame: Rect
    public var pixelWidth: Int
    public var pixelHeight: Int
    public var isMain: Bool
    public var refreshRate: Double

    public init(id: DisplayID, name: String, frame: Rect, pixelWidth: Int, pixelHeight: Int, isMain: Bool, refreshRate: Double) {
        self.id = id; self.name = name; self.frame = frame
        self.pixelWidth = pixelWidth; self.pixelHeight = pixelHeight
        self.isMain = isMain; self.refreshRate = refreshRate
    }

    public var scale: Double { frame.width > 0 ? Double(pixelWidth) / frame.width : 1 }
}

public struct HostInfo: Codable, Hashable, Sendable {
    public var name: String
    /// Marketing model name, e.g. "MacBook Pro".
    public var model: String
    public var modelIdentifier: String
    public var osVersion: String
    public var appVersion: String

    public init(name: String, model: String, modelIdentifier: String, osVersion: String, appVersion: String) {
        self.name = name; self.model = model; self.modelIdentifier = modelIdentifier
        self.osVersion = osVersion; self.appVersion = appVersion
    }
}

public struct HostPermissions: Codable, Hashable, Sendable {
    public var screenRecording: Bool
    public var accessibility: Bool
    public init(screenRecording: Bool, accessibility: Bool) {
        self.screenRecording = screenRecording; self.accessibility = accessibility
    }
}

public struct HostHello: Codable, Hashable, Sendable {
    public var info: HostInfo
    public var displays: [DisplayInfo]
    public var activeDisplayID: DisplayID
    public var permissions: HostPermissions
    public var protocolVersion: Int

    public init(info: HostInfo, displays: [DisplayInfo], activeDisplayID: DisplayID, permissions: HostPermissions,
                protocolVersion: Int = ReachProtocolVersion.current) {
        self.info = info; self.displays = displays; self.activeDisplayID = activeDisplayID
        self.permissions = permissions; self.protocolVersion = protocolVersion
    }
}

/// Describes the video stream currently being sent. Sent whenever the capture is (re)configured.
public struct StreamInfo: Codable, Hashable, Sendable {
    public var displayID: DisplayID
    /// Encoded frame size in pixels.
    public var width: Int
    public var height: Int
    public var maxFramesPerSecond: Int

    public init(displayID: DisplayID, width: Int, height: Int, maxFramesPerSecond: Int) {
        self.displayID = displayID; self.width = width; self.height = height
        self.maxFramesPerSecond = maxFramesPerSecond
    }
}

// MARK: - Cursor

public struct CursorImage: Codable, Hashable, Sendable {
    /// Stable content hash; clients cache images by id.
    public var id: UInt64
    /// PNG at the host's backing scale.
    public var png: Data
    /// Hot spot in points from the image's top-left.
    public var hotspotX: Double
    public var hotspotY: Double
    /// Size in points.
    public var width: Double
    public var height: Double

    public init(id: UInt64, png: Data, hotspotX: Double, hotspotY: Double, width: Double, height: Double) {
        self.id = id; self.png = png; self.hotspotX = hotspotX; self.hotspotY = hotspotY
        self.width = width; self.height = height
    }
}

// MARK: - Apps & windows

public struct AppInfo: Codable, Hashable, Sendable, Identifiable {
    public var pid: Int32
    public var bundleID: String?
    public var name: String
    /// 64x64 pt PNG icon (rendered @2x). Omitted when unchanged since the last list.
    public var icon: Data?
    public var isActive: Bool
    public var isHidden: Bool

    public var id: Int32 { pid }

    public init(pid: Int32, bundleID: String?, name: String, icon: Data?, isActive: Bool, isHidden: Bool) {
        self.pid = pid; self.bundleID = bundleID; self.name = name; self.icon = icon
        self.isActive = isActive; self.isHidden = isHidden
    }
}

public struct WindowInfo: Codable, Hashable, Sendable, Identifiable {
    public var id: UInt32
    public var pid: Int32
    public var appName: String
    public var title: String
    /// Frame in global points.
    public var frame: Rect
    public var isOnScreen: Bool

    public init(id: UInt32, pid: Int32, appName: String, title: String, frame: Rect, isOnScreen: Bool) {
        self.id = id; self.pid = pid; self.appName = appName; self.title = title
        self.frame = frame; self.isOnScreen = isOnScreen
    }
}

// MARK: - Clipboard

public struct ClipboardContent: Codable, Hashable, Sendable {
    public var text: String?
    public var imagePNG: Data?

    public init(text: String? = nil, imagePNG: Data? = nil) {
        self.text = text; self.imagePNG = imagePNG
    }
}

// MARK: - Input

public struct KeyModifiers: OptionSet, Codable, Hashable, Sendable {
    public let rawValue: UInt8
    public init(rawValue: UInt8) { self.rawValue = rawValue }

    public static let shift = KeyModifiers(rawValue: 1 << 0)
    public static let control = KeyModifiers(rawValue: 1 << 1)
    public static let option = KeyModifiers(rawValue: 1 << 2)
    public static let command = KeyModifiers(rawValue: 1 << 3)
    public static let function = KeyModifiers(rawValue: 1 << 4)
    public static let capsLock = KeyModifiers(rawValue: 1 << 5)
}

public enum MouseButton: String, Codable, Hashable, Sendable {
    case left, right, middle
}

public struct MouseButtonEvent: Codable, Hashable, Sendable {
    /// Shares the pointer sequence space so the host can discard stale unreliable moves.
    public var seq: UInt32
    public var button: MouseButton
    public var isDown: Bool
    /// Normalized position (0...1) within the active display.
    public var x: Double
    public var y: Double
    /// 1 for single click, 2 for the second click of a double-click, etc.
    public var clickCount: Int
    public var modifiers: KeyModifiers

    public init(seq: UInt32, button: MouseButton, isDown: Bool, x: Double, y: Double, clickCount: Int = 1, modifiers: KeyModifiers = []) {
        self.seq = seq; self.button = button; self.isDown = isDown; self.x = x; self.y = y
        self.clickCount = clickCount; self.modifiers = modifiers
    }
}

public enum ScrollPhase: String, Codable, Hashable, Sendable {
    /// Fingers touched down and started moving.
    case began
    case changed
    /// Fingers lifted. `velocityX/Y` drive host-side momentum.
    case ended
    case cancelled
    /// Discrete wheel-style scroll with no gesture phase (e.g. accessory buttons).
    case discrete
}

public struct ScrollEvent: Codable, Hashable, Sendable {
    /// Content movement in host points. Positive `dy` moves content down (reveals what is above),
    /// matching a finger dragging down on a touchscreen.
    public var dx: Double
    public var dy: Double
    public var phase: ScrollPhase
    /// Release velocity in host points/second (only meaningful for `.ended`).
    public var velocityX: Double
    public var velocityY: Double

    public init(dx: Double, dy: Double, phase: ScrollPhase, velocityX: Double = 0, velocityY: Double = 0) {
        self.dx = dx; self.dy = dy; self.phase = phase
        self.velocityX = velocityX; self.velocityY = velocityY
    }
}

public struct KeyEvent: Codable, Hashable, Sendable {
    /// macOS virtual key code (`kVK_*`), see `MacKey`.
    public var code: UInt16
    public var isDown: Bool
    public var modifiers: KeyModifiers

    public init(code: UInt16, isDown: Bool, modifiers: KeyModifiers) {
        self.code = code; self.isDown = isDown; self.modifiers = modifiers
    }
}

public struct TextInput: Codable, Hashable, Sendable {
    public var text: String
    /// When non-empty the host maps each character to a key code on its current layout and presses it
    /// with these modifiers held (e.g. sticky ⌘ + "s" → Save).
    public var modifiers: KeyModifiers

    public init(text: String, modifiers: KeyModifiers = []) {
        self.text = text; self.modifiers = modifiers
    }
}

/// Higher-level Mac actions that are awkward to express as raw keys on a phone.
public enum SystemAction: String, Codable, Hashable, Sendable, CaseIterable {
    case missionControl
    case appExpose
    case showDesktop
    case launchpad
    case spotlight
    case notificationCenter
    case previousSpace
    case nextSpace
    case appSwitcher
    case lockScreen
    case screenshot
    case forceQuit
    case wakeDisplay
}

public enum MediaKey: String, Codable, Hashable, Sendable, CaseIterable {
    case volumeUp, volumeDown, mute
    case playPause, next, previous
    case brightnessUp, brightnessDown
}

public enum QualityMode: String, Codable, Hashable, Sendable, CaseIterable {
    /// Full resolution; frame rate yields first under congestion. Best for text.
    case sharp
    /// Balanced resolution/frame-rate adaptation.
    case balanced
    /// Frame rate yields last; resolution adapts. Best for video and animation.
    case smooth
    /// Half resolution, capped bitrate — for metered connections.
    case dataSaver
}

public struct QualityPreference: Codable, Hashable, Sendable {
    public var mode: QualityMode
    public var maxFramesPerSecond: Int

    public init(mode: QualityMode = .balanced, maxFramesPerSecond: Int = 60) {
        self.mode = mode; self.maxFramesPerSecond = maxFramesPerSecond
    }
}

public struct ClientHello: Codable, Hashable, Sendable {
    public var name: String
    public var deviceModel: String
    public var appVersion: String
    /// Native screen size in pixels, so the host can pick a sensible stream size.
    public var screenPixelWidth: Int
    public var screenPixelHeight: Int
    public var quality: QualityPreference
    public var protocolVersion: Int
    /// The viewport at connect time, if the canvas is already laid out.
    public var viewport: ViewportHint?

    public init(name: String, deviceModel: String, appVersion: String, screenPixelWidth: Int, screenPixelHeight: Int,
                quality: QualityPreference, protocolVersion: Int = ReachProtocolVersion.current, viewport: ViewportHint? = nil) {
        self.name = name; self.deviceModel = deviceModel; self.appVersion = appVersion
        self.screenPixelWidth = screenPixelWidth; self.screenPixelHeight = screenPixelHeight
        self.quality = quality; self.protocolVersion = protocolVersion; self.viewport = viewport
    }
}

/// How many of the iPhone's physical pixels the whole Mac display spans right now (zoom × screen
/// scale). The Mac streams at a resolution that matches instead of always at native size: zoomed out,
/// most of a Retina frame would be thrown away on the phone while still costing bandwidth, encode and
/// decode time.
public struct ViewportHint: Codable, Hashable, Sendable {
    public var displayedPixelWidth: Int
    public var displayedPixelHeight: Int

    public init(displayedPixelWidth: Int, displayedPixelHeight: Int) {
        self.displayedPixelWidth = displayedPixelWidth
        self.displayedPixelHeight = displayedPixelHeight
    }
}

public struct Notice: Codable, Hashable, Sendable {
    public enum Level: String, Codable, Sendable { case info, warning, error }
    public var level: Level
    public var message: String
    public init(level: Level, message: String) { self.level = level; self.message = message }
}
