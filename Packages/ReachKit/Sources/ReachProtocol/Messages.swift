import Foundation

public enum ReachProtocolVersion {
    public static let current = 1
}

/// Messages sent from the iPhone to the Mac over the reliable, ordered control channel.
public enum ClientMessage: Codable, Hashable, Sendable {
    case hello(ClientHello)
    case selectDisplay(id: DisplayID)
    case setQuality(QualityPreference)
    /// The iPhone's zoom changed how many of its pixels the Mac's display covers.
    case viewport(ViewportHint)

    case mouseButton(MouseButtonEvent)
    case scroll(ScrollEvent)
    case key(KeyEvent)
    /// Press and release a key with modifiers held (shortcut buttons, sticky modifiers).
    case keyPress(code: UInt16, modifiers: KeyModifiers)
    case text(TextInput)
    case action(SystemAction)
    case media(MediaKey)

    case activateApp(pid: Int32)
    case focusWindow(id: UInt32)
    case requestApps
    case requestWindows
    case setClipboard(ClipboardContent)

    case ping(id: UInt32, sentAt: Double)
}

/// Messages sent from the Mac to the iPhone over the reliable, ordered control channel.
public enum HostMessage: Codable, Hashable, Sendable {
    case hello(HostHello)
    case displays([DisplayInfo], activeDisplayID: DisplayID)
    case stream(StreamInfo)
    case cursorImage(CursorImage)
    case cursorShape(id: UInt64)
    case clipboard(ClipboardContent)
    case apps([AppInfo])
    case windows([WindowInfo])
    case frontmostApp(pid: Int32, name: String)
    case permissions(HostPermissions)
    case notice(Notice)
    case pong(id: UInt32, sentAt: Double)
}

public enum WireCodec {
    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dataEncodingStrategy = .base64
        return e
    }()

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dataDecodingStrategy = .base64
        return d
    }()

    public static func encode<T: Encodable>(_ value: T) throws -> Data {
        try encoder.encode(value)
    }

    public static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        try decoder.decode(type, from: data)
    }
}
