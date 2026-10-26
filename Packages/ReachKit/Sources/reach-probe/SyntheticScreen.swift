import Foundation
import AppKit
import CoreVideo
import VideoToolbox
import ReachProtocol

/// A fake Mac desktop rendered with CoreGraphics and converted to NV12 (video range, BT.709) —
/// the same format the real host captures. It reacts to input so an end-to-end test can *see* that
/// input arrived: clicks leave markers exactly where they landed, typed text appears in an editor
/// window, scrolling moves a list. Frames also carry two barcodes: a capture timestamp (row 0) and
/// the latest input sequence number (row 1).
final class SyntheticScreen {
    let pixelWidth: Int
    let pixelHeight: Int
    let scale: Double
    var pointWidth: Double { Double(pixelWidth) / scale }
    var pointHeight: Double { Double(pixelHeight) / scale }

    private let lock = NSLock()
    private var base: CVPixelBuffer?
    private var dirty = true
    private var pool: CVPixelBufferPool?
    private var transfer: VTPixelTransferSession?

    // Interactive state (points)
    private(set) var typed = "Type on your iPhone — it appears here."
    private var userTyped = false
    private var scrollOffset: Double = 0
    private var clicks: [(x: Double, y: Double, right: Bool, at: Date)] = []
    private var dragTrail: [(x: Double, y: Double)] = []
    var inputSeq: UInt32 = 0

    let windows: [(id: UInt32, title: String, app: String, frame: Rect)]

    init(width: Int, height: Int, scale: Double = 2) {
        pixelWidth = width & ~1
        pixelHeight = height & ~1
        self.scale = scale
        let pw = Double(width) / scale, ph = Double(height) / scale
        windows = [
            (101, "Notes — Reach Test", "Notes", Rect(x: pw * 0.06, y: ph * 0.10, width: pw * 0.46, height: ph * 0.62)),
            (102, "Activity", "Finder", Rect(x: pw * 0.56, y: ph * 0.16, width: pw * 0.38, height: ph * 0.66)),
        ]
        let attrs: [String: Any] = [kCVPixelBufferIOSurfacePropertiesKey as String: [:],
                                    kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                                    kCVPixelBufferWidthKey as String: pixelWidth,
                                    kCVPixelBufferHeightKey as String: pixelHeight]
        CVPixelBufferPoolCreate(nil, [kCVPixelBufferPoolMinimumBufferCountKey: 6] as CFDictionary, attrs as CFDictionary, &pool)
        VTPixelTransferSessionCreate(allocator: nil, pixelTransferSessionOut: &transfer)
    }

    // MARK: Input

    func click(x: Double, y: Double, right: Bool) {
        lock.withLock {
            clicks.append((x, y, right, Date()))
            if clicks.count > 30 { clicks.removeFirst() }
            dirty = true
        }
    }

    func drag(x: Double, y: Double) {
        lock.withLock {
            dragTrail.append((x, y))
            if dragTrail.count > 400 { dragTrail.removeFirst(100) }
            dirty = true
        }
    }

    func type(_ s: String) {
        lock.withLock {
            if !userTyped { typed = ""; userTyped = true }
            typed += s
            if typed.count > 600 { typed = String(typed.suffix(600)) }
            dirty = true
        }
    }

    func backspace() {
        lock.withLock {
            if !typed.isEmpty { typed.removeLast() }
            dirty = true
        }
    }

    func scroll(dy: Double) {
        lock.withLock {
            scrollOffset = max(0, min(4000, scrollOffset - dy))
            dirty = true
        }
    }

    // MARK: Frames

    /// Produce the next frame. Returns nil only if buffer allocation fails.
    func nextFrame() -> CVPixelBuffer? {
        let (needsRender, snapshot) = lock.withLock { () -> (Bool, (String, Double, [(Double, Double, Bool, Date)], [(Double, Double)])) in
            let n = dirty || base == nil
            dirty = false
            clicks.removeAll { Date().timeIntervalSince($0.at) > 8 }
            return (n, (typed, scrollOffset, clicks.map { ($0.x, $0.y, $0.right, $0.at) }, dragTrail.map { ($0.x, $0.y) }))
        }
        if needsRender { renderBase(typed: snapshot.0, scroll: snapshot.1, clicks: snapshot.2, trail: snapshot.3) }
        guard let pool, let base else { return nil }
        var out: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &out)
        guard let out else { return nil }
        CVPixelBufferLockBaseAddress(base, .readOnly)
        CVPixelBufferLockBaseAddress(out, [])
        for plane in 0..<2 {
            let src = CVPixelBufferGetBaseAddressOfPlane(base, plane)!
            let dst = CVPixelBufferGetBaseAddressOfPlane(out, plane)!
            let sb = CVPixelBufferGetBytesPerRowOfPlane(base, plane), db = CVPixelBufferGetBytesPerRowOfPlane(out, plane)
            let rows = CVPixelBufferGetHeightOfPlane(base, plane)
            if sb == db { memcpy(dst, src, sb * rows) } else {
                for r in 0..<rows { memcpy(dst + r * db, src + r * sb, min(sb, db)) }
            }
        }
        Barcode.draw(uptimeMs() & 0xFF_FFFF_FFFF, row: 0, into: out)
        Barcode.draw(UInt64(inputSeq), row: 1, into: out)
        CVPixelBufferUnlockBaseAddress(out, [])
        CVPixelBufferUnlockBaseAddress(base, .readOnly)
        CVBufferSetAttachment(out, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_709_2, .shouldPropagate)
        CVBufferSetAttachment(out, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_709_2, .shouldPropagate)
        CVBufferSetAttachment(out, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_ITU_R_709_2, .shouldPropagate)
        return out
    }

    private func renderBase(typed: String, scroll: Double, clicks: [(Double, Double, Bool, Date)], trail: [(Double, Double)]) {
        let w = pixelWidth, h = pixelHeight
        var bgra: CVPixelBuffer?
        CVPixelBufferCreate(nil, w, h, kCVPixelFormatType_32BGRA,
                            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &bgra)
        guard let bgra else { return }
        CVPixelBufferLockBaseAddress(bgra, [])
        let ctx = CGContext(data: CVPixelBufferGetBaseAddress(bgra), width: w, height: h, bitsPerComponent: 8,
                            bytesPerRow: CVPixelBufferGetBytesPerRow(bgra), space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
        // Top-left origin in points.
        ctx.translateBy(x: 0, y: CGFloat(h))
        ctx.scaleBy(x: CGFloat(scale), y: -CGFloat(scale))
        let gctx = NSGraphicsContext(cgContext: ctx, flipped: true)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = gctx
        drawDesktop(ctx, typed: typed, scroll: scroll, clicks: clicks, trail: trail)
        NSGraphicsContext.restoreGraphicsState()
        CVPixelBufferUnlockBaseAddress(bgra, [])

        var nv12: CVPixelBuffer?
        CVPixelBufferCreate(nil, w, h, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &nv12)
        guard let nv12, let transfer else { return }
        VTSessionSetProperty(transfer, key: kVTPixelTransferPropertyKey_DestinationYCbCrMatrix, value: kCVImageBufferYCbCrMatrix_ITU_R_709_2)
        VTPixelTransferSessionTransferImage(transfer, from: bgra, to: nv12)
        lock.withLock { base = nv12 }
    }

    private func drawDesktop(_ ctx: CGContext, typed: String, scroll: Double, clicks: [(Double, Double, Bool, Date)], trail: [(Double, Double)]) {
        let pw = pointWidth, ph = pointHeight
        // Wallpaper
        let grad = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: [
            NSColor(red: 0.16, green: 0.22, blue: 0.45, alpha: 1).cgColor,
            NSColor(red: 0.47, green: 0.27, blue: 0.56, alpha: 1).cgColor,
            NSColor(red: 0.93, green: 0.52, blue: 0.42, alpha: 1).cgColor] as CFArray, locations: [0, 0.6, 1])!
        ctx.drawLinearGradient(grad, start: .zero, end: CGPoint(x: pw, y: ph), options: [])

        // Menu bar
        ctx.setFillColor(NSColor(white: 1, alpha: 0.82).cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: pw, height: 24))
        text("  Reach Probe    File    Edit    View    Window    Help", at: CGPoint(x: 8, y: 4), size: 13, weight: .medium, color: .black)
        text("Synthetic host · \(pixelWidth)×\(pixelHeight)", at: CGPoint(x: pw - 260, y: 4), size: 13, weight: .regular, color: .black)

        // Windows
        for (i, win) in windows.enumerated() {
            let r = CGRect(x: win.frame.x, y: win.frame.y, width: win.frame.width, height: win.frame.height)
            ctx.saveGState()
            ctx.setShadow(offset: CGSize(width: 0, height: 10), blur: 30, color: NSColor(white: 0, alpha: 0.35).cgColor)
            ctx.setFillColor(NSColor(white: 0.98, alpha: 1).cgColor)
            ctx.addPath(CGPath(roundedRect: r, cornerWidth: 12, cornerHeight: 12, transform: nil))
            ctx.fillPath()
            ctx.restoreGState()
            // Title bar
            ctx.setFillColor(NSColor(white: 0.93, alpha: 1).cgColor)
            ctx.addPath(CGPath(roundedRect: CGRect(x: r.minX, y: r.minY, width: r.width, height: 30), cornerWidth: 12, cornerHeight: 12, transform: nil))
            ctx.fillPath()
            for (j, c) in [NSColor.systemRed, .systemYellow, .systemGreen].enumerated() {
                ctx.setFillColor(c.cgColor)
                ctx.fillEllipse(in: CGRect(x: r.minX + 12 + CGFloat(j) * 20, y: r.minY + 9, width: 12, height: 12))
            }
            text(win.title, at: CGPoint(x: r.midX - 70, y: r.minY + 7), size: 13, weight: .semibold, color: NSColor(white: 0.25, alpha: 1))
            ctx.saveGState()
            ctx.clip(to: CGRect(x: r.minX, y: r.minY + 30, width: r.width, height: r.height - 30))
            if i == 0 {
                text("Notes", at: CGPoint(x: r.minX + 24, y: r.minY + 46), size: 26, weight: .bold, color: .black)
                let para = NSMutableParagraphStyle(); para.lineSpacing = 4
                let body = NSAttributedString(string: typed + "▍", attributes: [
                    .font: NSFont.systemFont(ofSize: 15), .foregroundColor: NSColor.black, .paragraphStyle: para])
                body.draw(in: CGRect(x: r.minX + 24, y: r.minY + 90, width: r.width - 48, height: r.height - 110))
            } else {
                for row in 0..<60 {
                    let y = r.minY + 40 + CGFloat(row) * 28 - CGFloat(scroll)
                    guard y > r.minY + 20, y < r.maxY else { continue }
                    if row % 2 == 0 {
                        ctx.setFillColor(NSColor(white: 0.95, alpha: 1).cgColor)
                        ctx.fill(CGRect(x: r.minX + 8, y: y - 4, width: r.width - 16, height: 28))
                    }
                    text("Row \(row + 1)  ·  scroll me with two fingers", at: CGPoint(x: r.minX + 20, y: y), size: 14, weight: .regular, color: NSColor(white: 0.15, alpha: 1))
                }
            }
            ctx.restoreGState()
        }

        // Dock
        let dockW = min(pw * 0.5, 620.0), dockRect = CGRect(x: (pw - dockW) / 2, y: ph - 74, width: dockW, height: 64)
        ctx.setFillColor(NSColor(white: 1, alpha: 0.35).cgColor)
        ctx.addPath(CGPath(roundedRect: dockRect, cornerWidth: 18, cornerHeight: 18, transform: nil))
        ctx.fillPath()
        let colors: [NSColor] = [.systemBlue, .systemGreen, .systemOrange, .systemPink, .systemPurple, .systemTeal, .systemYellow, .systemRed]
        for (k, c) in colors.enumerated() {
            ctx.setFillColor(c.cgColor)
            ctx.addPath(CGPath(roundedRect: CGRect(x: dockRect.minX + 16 + CGFloat(k) * 74, y: dockRect.minY + 8, width: 48, height: 48), cornerWidth: 11, cornerHeight: 11, transform: nil))
            ctx.fillPath()
        }

        // Drag trail and click markers (so tests can see exactly where input landed)
        if trail.count > 1 {
            ctx.setStrokeColor(NSColor.systemYellow.cgColor)
            ctx.setLineWidth(3)
            ctx.addLines(between: trail.map { CGPoint(x: $0.0, y: $0.1) })
            ctx.strokePath()
        }
        for c in clicks {
            ctx.setStrokeColor((c.2 ? NSColor.systemOrange : NSColor.systemRed).cgColor)
            ctx.setLineWidth(2.5)
            ctx.strokeEllipse(in: CGRect(x: c.0 - 9, y: c.1 - 9, width: 18, height: 18))
            ctx.setFillColor((c.2 ? NSColor.systemOrange : NSColor.systemRed).cgColor)
            ctx.fillEllipse(in: CGRect(x: c.0 - 2.5, y: c.1 - 2.5, width: 5, height: 5))
        }
    }

    private func text(_ s: String, at p: CGPoint, size: CGFloat, weight: NSFont.Weight, color: NSColor) {
        NSAttributedString(string: s, attributes: [.font: NSFont.systemFont(ofSize: size, weight: weight),
                                                   .foregroundColor: color]).draw(at: p)
    }

    /// A classic arrow cursor as PNG @2x.
    static func arrowCursorPNG() -> Data {
        let size = NSSize(width: 17, height: 24)
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 34, pixelsHigh: 48, bitsPerSample: 8,
                                   samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                   bytesPerRow: 0, bitsPerPixel: 0)!
        rep.size = size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        let path = NSBezierPath()
        path.move(to: NSPoint(x: 1, y: 23)); path.line(to: NSPoint(x: 1, y: 4)); path.line(to: NSPoint(x: 5.5, y: 8.5))
        path.line(to: NSPoint(x: 9, y: 1.5)); path.line(to: NSPoint(x: 11.5, y: 2.7)); path.line(to: NSPoint(x: 8, y: 9.5))
        path.line(to: NSPoint(x: 14, y: 9.5)); path.close()
        NSColor.black.setFill(); path.fill()
        NSColor.white.setStroke(); path.lineWidth = 1.2; path.stroke()
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .png, properties: [:]) ?? Data()
    }
}
