import Foundation
import AppKit
import CoreVideo
import VideoToolbox

/// Bench content: a tall page of dense multi-column text (black on white, like a code editor),
/// rendered ONCE with CoreGraphics into an NV12 buffer several frames tall. Each frame is a window
/// of it copied row by row, so producing a frame costs about a millisecond while every pixel changes
/// from one frame to the next — the worst case for an encoder, and what scrolling text looks like.
final class ScrollingDocument {
    let pixelWidth: Int
    let pixelHeight: Int
    let scale: Double
    let documentHeight: Int
    private let document: CVPixelBuffer
    private let pool: CVPixelBufferPool
    private var offset = 0
    private var direction = 1
    private var rng: UInt64 = 0x2545_F491_4F6C_DD1D

    init?(width: Int, height: Int, scale: Double = 2, pages: Int = 4) {
        let w = width & ~1, h = height & ~1
        let docHeight = min(16_000, h * max(2, pages)) & ~1
        guard w > 0, h > 0, docHeight > h else { return nil }
        let attrs: [String: Any] = [kCVPixelBufferIOSurfacePropertiesKey as String: [:],
                                    kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                                    kCVPixelBufferWidthKey as String: w,
                                    kCVPixelBufferHeightKey as String: h]
        var p: CVPixelBufferPool?
        CVPixelBufferPoolCreate(nil, [kCVPixelBufferPoolMinimumBufferCountKey: 6] as CFDictionary, attrs as CFDictionary, &p)
        guard let p, let doc = ScrollingDocument.render(width: w, height: docHeight, scale: scale) else { return nil }
        pixelWidth = w
        pixelHeight = h
        self.scale = scale
        documentHeight = docHeight
        pool = p
        document = doc
    }

    /// Move the window by `points` (at the screen scale), bouncing at both ends of the page.
    func scroll(points: Double) {
        let step = max(2, Int((abs(points) * scale).rounded()) & ~1)
        let maxOffset = documentHeight - pixelHeight
        var next = offset + step * direction
        if next > maxOffset || next < 0 {
            direction = -direction
            next = offset + step * direction
        }
        offset = min(max(0, next), maxOffset) & ~1
    }

    /// `--content video`: show a randomly chosen window of the page (a jump cut every frame), so
    /// the encoder can't predict a frame from the previous one and every frame is intra-heavy.
    func jump() {
        let maxOffset = documentHeight - pixelHeight
        rng = rng &* 6364136223846793005 &+ 1442695040888963407
        var next = Int(truncatingIfNeeded: rng >> 33) % (maxOffset + 1)
        // At least a fifth of a frame away from the current window.
        if abs(next - offset) < pixelHeight / 5 { next = (next + maxOffset / 2) % (maxOffset + 1) }
        offset = next & ~1
    }

    func nextFrame() -> CVPixelBuffer? {
        var out: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &out)
        guard let out else { return nil }
        CVPixelBufferLockBaseAddress(document, .readOnly)
        CVPixelBufferLockBaseAddress(out, [])
        for plane in 0..<2 {
            guard let src = CVPixelBufferGetBaseAddressOfPlane(document, plane),
                  let dst = CVPixelBufferGetBaseAddressOfPlane(out, plane) else { continue }
            let sb = CVPixelBufferGetBytesPerRowOfPlane(document, plane)
            let db = CVPixelBufferGetBytesPerRowOfPlane(out, plane)
            let rows = CVPixelBufferGetHeightOfPlane(out, plane)
            let srcRows = CVPixelBufferGetHeightOfPlane(document, plane)
            let first = plane == 0 ? offset : offset / 2
            let n = min(sb, db)
            for r in 0..<rows where first + r < srcRows {
                memcpy(dst + r * db, src + (first + r) * sb, n)
            }
        }
        // The timestamp twice, so the bench can tell a misread (rows disagree) and recover from one.
        let ts = uptimeMs() & 0xFF_FFFF_FFFF
        Barcode.draw(ts, row: 0, into: out)
        Barcode.draw(ts, row: 1, into: out)
        CVPixelBufferUnlockBaseAddress(out, [])
        CVPixelBufferUnlockBaseAddress(document, .readOnly)
        CVBufferSetAttachment(out, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_709_2, .shouldPropagate)
        CVBufferSetAttachment(out, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_709_2, .shouldPropagate)
        CVBufferSetAttachment(out, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_ITU_R_709_2, .shouldPropagate)
        return out
    }

    // MARK: Rendering (once)

    private static func render(width w: Int, height h: Int, scale: Double) -> CVPixelBuffer? {
        var bgra: CVPixelBuffer?
        CVPixelBufferCreate(nil, w, h, kCVPixelFormatType_32BGRA, [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &bgra)
        guard let bgra else { return nil }
        CVPixelBufferLockBaseAddress(bgra, [])
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: CVPixelBufferGetBaseAddress(bgra), width: w, height: h, bitsPerComponent: 8,
                                  bytesPerRow: CVPixelBufferGetBytesPerRow(bgra), space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) else {
            CVPixelBufferUnlockBaseAddress(bgra, [])
            return nil
        }
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        // Top-left origin in points.
        ctx.translateBy(x: 0, y: CGFloat(h))
        ctx.scaleBy(x: CGFloat(scale), y: -CGFloat(scale))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
        drawText(width: Double(w) / scale, height: Double(h) / scale)
        NSGraphicsContext.restoreGraphicsState()
        CVPixelBufferUnlockBaseAddress(bgra, [])

        var nv12: CVPixelBuffer?
        CVPixelBufferCreate(nil, w, h, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &nv12)
        var transfer: VTPixelTransferSession?
        VTPixelTransferSessionCreate(allocator: nil, pixelTransferSessionOut: &transfer)
        guard let nv12, let transfer else { return nil }
        VTSessionSetProperty(transfer, key: kVTPixelTransferPropertyKey_DestinationYCbCrMatrix, value: kCVImageBufferYCbCrMatrix_ITU_R_709_2)
        let status = VTPixelTransferSessionTransferImage(transfer, from: bgra, to: nv12)
        VTPixelTransferSessionInvalidate(transfer)
        return status == noErr ? nv12 : nil
    }

    private static func drawText(width pw: Double, height ph: Double) {
        let margin = 16.0, gutter = 18.0, lineHeight = 11.0
        let columns = max(1, Int((pw - 2 * margin) / 240))
        let columnWidth = (pw - 2 * margin - gutter * Double(columns - 1)) / Double(columns)
        let font = NSFont.monospacedSystemFont(ofSize: 9, weight: .regular)
        let para = NSMutableParagraphStyle()
        para.minimumLineHeight = lineHeight
        para.maximumLineHeight = lineHeight
        para.lineBreakMode = .byClipping
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.black, .paragraphStyle: para]
        let linesPerColumn = Int(ph / lineHeight) + 2
        var rng: UInt64 = 0x9E37_79B9_7F4A_7C15
        for c in 0..<columns {
            var text = ""
            for l in 0..<linesPerColumn {
                text += line(number: c * linesPerColumn + l + 1, rng: &rng)
                text += "\n"
            }
            let rect = CGRect(x: margin + Double(c) * (columnWidth + gutter), y: 8, width: columnWidth, height: ph - 8)
            NSAttributedString(string: text, attributes: attrs).draw(in: rect)
        }
    }

    private static let words = ["let", "var", "func", "return", "guard", "else", "if", "for", "in", "self", "frame",
                                "buffer", "offset", "count", "encoder", "session", "packet", "width", "height", "rate",
                                "stats", "queue", "async", "value", "index", "result", "error", "nil", "true", "false",
                                "{", "}", "(", ")", "=", "+", "-", "*", "==", "->", "//", "0", "1", "42", "1024", "0.5"]

    /// One deterministic line of code-like text: line number, indentation, ~25–45 characters.
    private static func line(number: Int, rng: inout UInt64) -> String {
        func next() -> Int {
            rng = rng &* 6364136223846793005 &+ 1442695040888963407
            return Int(truncatingIfNeeded: rng >> 33)
        }
        var s = String(format: "%4ld  ", number)
        s += String(repeating: " ", count: (next() % 4) * 2)
        let target = 25 + next() % 21
        while s.count < target {
            s += words[next() % words.count]
            s += " "
        }
        return s
    }
}
