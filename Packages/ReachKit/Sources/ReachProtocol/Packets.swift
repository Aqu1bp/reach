import Foundation

/// High-rate state that travels on the unreliable, unordered data channel. Only the newest value
/// matters, so packets carry a sequence number and receivers drop anything older than what they have.
/// Little-endian, fixed size.

/// iPhone → Mac: absolute pointer position.
public struct PointerPacket: Equatable, Sendable {
    public static let tag: UInt8 = 0x50 // "P"
    public static let size = 1 + 4 + 4 + 4

    public var seq: UInt32
    /// Normalized position (0...1) within the active display.
    public var x: Float
    public var y: Float

    public init(seq: UInt32, x: Float, y: Float) {
        self.seq = seq; self.x = x; self.y = y
    }

    public func encoded() -> Data {
        var w = PacketWriter(capacity: Self.size)
        w.u8(Self.tag); w.u32(seq); w.f32(x); w.f32(y)
        return w.data
    }

    public init?(_ data: Data) {
        guard data.count == Self.size else { return nil }
        var r = PacketReader(data)
        guard r.u8() == Self.tag else { return nil }
        seq = r.u32(); x = r.f32(); y = r.f32()
    }
}

/// Mac → iPhone: where the real cursor is, and whether it is visible.
public struct CursorPacket: Equatable, Sendable {
    public static let tag: UInt8 = 0x43 // "C"
    public static let size = 1 + 4 + 4 + 4 + 1

    public var seq: UInt32
    /// Normalized position within the active display. May be outside 0...1 when the cursor is
    /// on another display.
    public var x: Float
    public var y: Float
    public var visible: Bool

    public init(seq: UInt32, x: Float, y: Float, visible: Bool) {
        self.seq = seq; self.x = x; self.y = y; self.visible = visible
    }

    public func encoded() -> Data {
        var w = PacketWriter(capacity: Self.size)
        w.u8(Self.tag); w.u32(seq); w.f32(x); w.f32(y); w.u8(visible ? 1 : 0)
        return w.data
    }

    public init?(_ data: Data) {
        guard data.count == Self.size else { return nil }
        var r = PacketReader(data)
        guard r.u8() == Self.tag else { return nil }
        seq = r.u32(); x = r.f32(); y = r.f32(); visible = r.u8() != 0
    }
}

/// Wrap-around aware "a is newer than b" for 32-bit sequence numbers.
@inlinable
public func seqIsNewer(_ a: UInt32, than b: UInt32) -> Bool {
    a != b && (a &- b) < 0x8000_0000
}

struct PacketWriter {
    var data: Data
    init(capacity: Int) { data = Data(capacity: capacity) }
    mutating func u8(_ v: UInt8) { data.append(v) }
    mutating func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
    mutating func f32(_ v: Float) { u32(v.bitPattern) }
}

struct PacketReader {
    let bytes: [UInt8]
    var offset = 0
    init(_ data: Data) { bytes = [UInt8](data) }
    mutating func u8() -> UInt8 { defer { offset += 1 }; return bytes[offset] }
    mutating func u32() -> UInt32 {
        defer { offset += 4 }
        return UInt32(bytes[offset]) | UInt32(bytes[offset + 1]) << 8 | UInt32(bytes[offset + 2]) << 16 | UInt32(bytes[offset + 3]) << 24
    }
    mutating func f32() -> Float { Float(bitPattern: u32()) }
}
