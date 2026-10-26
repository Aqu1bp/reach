import Foundation

/// 64-bit FNV-1a. Used for content ids (cursor images) that must be stable across launches, which
/// rules out Swift's per-process-seeded `Hasher`.
struct ContentHash {
    private(set) var value: UInt64 = 0xcbf2_9ce4_8422_2325
    private static let prime: UInt64 = 0x0000_0100_0000_01b3

    mutating func add(_ bytes: UnsafeRawBufferPointer) {
        var h = value
        for byte in bytes {
            h = (h ^ UInt64(byte)) &* Self.prime
        }
        value = h
    }

    mutating func add(_ data: Data) {
        data.withUnsafeBytes { add($0) }
    }

    mutating func add<T: FixedWidthInteger>(_ integer: T) {
        withUnsafeBytes(of: integer.littleEndian) { add($0) }
    }

    mutating func add(_ number: Double) {
        add(number.bitPattern)
    }
}
