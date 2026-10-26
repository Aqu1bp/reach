import Foundation
import CoreVideo

/// A scale-invariant binary code drawn into the luma plane of NV12 frames so a receiver can read
/// values (timestamps, input sequence numbers) back out of the decoded video and measure latency.
///
/// Each row is `bits` square blocks of width `frameWidth/48` (41 blocks fit in 85% of the width),
/// starting one block in from the left.
/// Row 0 sits at y = 2% of the height, row 1 one block lower, etc. White = 1, black = 0.
enum Barcode {
    static let bits = 40

    static func blockSize(width: Int) -> Int { max(4, width / 48) }

    static func draw(_ value: UInt64, row: Int, into buffer: CVPixelBuffer) {
        let w = CVPixelBufferGetWidthOfPlane(buffer, 0)
        let h = CVPixelBufferGetHeightOfPlane(buffer, 0)
        let bpr = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
        guard let base = CVPixelBufferGetBaseAddressOfPlane(buffer, 0)?.assumingMemoryBound(to: UInt8.self) else { return }
        let b = blockSize(width: w)
        let y0 = Int(Double(h) * 0.02) + row * (b + b / 2)
        for i in 0..<bits {
            let on = (value >> UInt64(bits - 1 - i)) & 1 == 1
            let x0 = b + i * b
            for y in y0..<min(h, y0 + b) {
                memset(base + y * bpr + x0, on ? 235 : 16, min(b, w - x0))
            }
        }
        // Chroma neutral under the code so colour bleed can't confuse the reader.
        if let uv = CVPixelBufferGetBaseAddressOfPlane(buffer, 1)?.assumingMemoryBound(to: UInt8.self) {
            let uvBpr = CVPixelBufferGetBytesPerRowOfPlane(buffer, 1)
            for y in (y0 / 2)..<min(h / 2, (y0 + b) / 2 + 1) {
                memset(uv + y * uvBpr + b, 128, min(bits * b, w - b))
            }
        }
    }

    static func read(row: Int, from buffer: CVPixelBuffer) -> UInt64? {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let w = CVPixelBufferGetWidthOfPlane(buffer, 0)
        let h = CVPixelBufferGetHeightOfPlane(buffer, 0)
        let bpr = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
        guard let base = CVPixelBufferGetBaseAddressOfPlane(buffer, 0)?.assumingMemoryBound(to: UInt8.self) else { return nil }
        let b = blockSize(width: w)
        let y0 = Int(Double(h) * 0.02) + row * (b + b / 2)
        let cy = y0 + b / 2
        guard cy < h else { return nil }
        var v: UInt64 = 0
        for i in 0..<bits {
            let cx = b + i * b + b / 2
            // Average a 5×5 grid over the middle half of the block, for robustness against compression.
            var sum = 0, n = 0
            for dy in -2...2 { for dx in -2...2 {
                let x = cx + dx * max(1, b / 8), y = cy + dy * max(1, b / 8)
                guard x >= 0, x < w, y >= 0, y < h else { continue }
                sum += Int(base[y * bpr + x]); n += 1
            } }
            let bit: UInt64 = (n > 0 && sum / n > 128) ? 1 : 0
            v = (v << 1) | bit
        }
        return v
    }
}

/// Monotonic milliseconds shared by all processes on this machine (mach absolute time), so a probe
/// host and probe client on the same Mac can compare timestamps directly.
func uptimeMs() -> UInt64 { DispatchTime.now().uptimeNanoseconds / 1_000_000 }
