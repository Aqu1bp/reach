// Renders the Reach app icons with CoreGraphics.
//
//   swift Tools/make-icons.swift
//
// Writes:
//   Apps/ReachiOS/Assets.xcassets/AppIcon.appiconset/AppIcon-1024.png   (iOS: full-bleed, opaque; the OS applies the mask)
//   Apps/ReachHost/Assets.xcassets/AppIcon.appiconset/icon_*.png         (macOS: rounded-square body on a transparent
//                                                                         canvas with the standard margins and shadow)
// and updates both Contents.json files with the file names.
//
// The artwork: a Mac screen with a pointer on it, and an iPhone in front of its corner — the phone drives the
// pointer. White glyphs on a deep-blue → #4D95FF gradient (the app's accent).

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

// MARK: - Palette

func rgb(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: alpha)
}

let accent = rgb(0x4D95FF)
let midBlue = rgb(0x2463E0)
let deepBlue = rgb(0x0B1F5E)
let white = rgb(0xFFFFFF)

let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!

// MARK: - Geometry helpers (all drawing happens in a 1024-unit, y-down space)

func roundedRect(_ r: CGRect, _ radius: CGFloat) -> CGPath {
    CGPath(roundedRect: r, cornerWidth: radius, cornerHeight: radius, transform: nil)
}

/// Rounded rectangle with continuous ("squircle") corners like Apple's icon shapes: each corner eases into
/// the straight edge over ~1.53 × radius instead of meeting it at a tangent point.
func continuousRoundedRect(_ rect: CGRect, radius r: CGFloat) -> CGPath {
    let path = CGMutablePath()
    // One corner, described for the top-right in a y-down space, as offsets from the corner point:
    // (along the top edge, down the side) pairs.
    let segs: [(end: CGPoint, c1: CGPoint, c2: CGPoint)] = [
        (CGPoint(x: 0.63149196, y: 0.07491100), CGPoint(x: 1.08849299, y: 0), CGPoint(x: 0.86840701, y: 0)),
        (CGPoint(x: 0.07491100, y: 0.63149196), CGPoint(x: 0.37282198, y: 0.16905395), CGPoint(x: 0.16905395, y: 0.37282198)),
        (CGPoint(x: 0, y: 1.52866483), CGPoint(x: 0, y: 0.86840701), CGPoint(x: 0, y: 1.08849299)),
    ]
    let k: CGFloat = 1.52866483
    // Corners in drawing order with the unit vectors pointing back along the incoming edge (u) and
    // along the outgoing edge (v).
    let corners: [(corner: CGPoint, u: CGVector, v: CGVector)] = [
        (CGPoint(x: rect.maxX, y: rect.minY), CGVector(dx: -1, dy: 0), CGVector(dx: 0, dy: 1)),  // top-right
        (CGPoint(x: rect.maxX, y: rect.maxY), CGVector(dx: 0, dy: -1), CGVector(dx: -1, dy: 0)), // bottom-right
        (CGPoint(x: rect.minX, y: rect.maxY), CGVector(dx: 1, dy: 0), CGVector(dx: 0, dy: -1)),  // bottom-left
        (CGPoint(x: rect.minX, y: rect.minY), CGVector(dx: 0, dy: 1), CGVector(dx: 1, dy: 0)),   // top-left
    ]
    func pt(_ c: (corner: CGPoint, u: CGVector, v: CGVector), _ a: CGFloat, _ b: CGFloat) -> CGPoint {
        CGPoint(x: c.corner.x + (c.u.dx * a + c.v.dx * b) * r, y: c.corner.y + (c.u.dy * a + c.v.dy * b) * r)
    }
    for (i, c) in corners.enumerated() {
        let start = pt(c, k, 0)
        if i == 0 { path.move(to: start) } else { path.addLine(to: start) }
        for seg in segs {
            path.addCurve(to: pt(c, seg.end.x, seg.end.y), control1: pt(c, seg.c1.x, seg.c1.y), control2: pt(c, seg.c2.x, seg.c2.y))
        }
    }
    path.closeSubpath()
    return path
}

/// The macOS arrow pointer, tip at `tip`, `height` tall (tip to tail end).
func pointerPath(tip: CGPoint, height h: CGFloat) -> CGPath {
    // Proportions of the classic arrow: a tall triangle with a notch and a tail.
    let pts: [(CGFloat, CGFloat)] = [
        (0.00, 0.00),   // tip
        (0.00, 0.80),   // left edge bottom
        (0.19, 0.625),  // notch (left)
        (0.33, 0.96),   // tail bottom-left
        (0.46, 0.905),  // tail bottom-right
        (0.325, 0.585), // notch (right)
        (0.575, 0.585), // right wing
    ]
    let path = CGMutablePath()
    for (i, p) in pts.enumerated() {
        let point = CGPoint(x: tip.x + p.0 * h, y: tip.y + p.1 * h)
        if i == 0 { path.move(to: point) } else { path.addLine(to: point) }
    }
    path.closeSubpath()
    // Soften the corners slightly so it doesn't look like vector clip-art at large sizes.
    return path.copy(strokingWithWidth: h * 0.035, lineCap: .round, lineJoin: .round, miterLimit: 1)
        .union(path)
}

// MARK: - Artwork

/// Background gradient filling `shape` (deep blue at the bottom-right to the accent at the top-left).
func drawBackground(_ ctx: CGContext, clip shape: CGPath, in r: CGRect) {
    ctx.saveGState()
    ctx.addPath(shape)
    ctx.clip()
    let g = CGGradient(colorsSpace: colorSpace, colors: [accent, midBlue, deepBlue] as CFArray,
                       locations: [0, 0.48, 1])!
    ctx.drawLinearGradient(g, start: CGPoint(x: r.minX + r.width * 0.15, y: r.minY),
                           end: CGPoint(x: r.maxX - r.width * 0.1, y: r.maxY), options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    // A soft light from the top-left, like the glass in the app.
    let glow = CGGradient(colorsSpace: colorSpace, colors: [rgb(0xFFFFFF, 0.20), rgb(0xFFFFFF, 0)] as CFArray,
                          locations: [0, 1])!
    ctx.drawRadialGradient(glow, startCenter: CGPoint(x: r.minX + r.width * 0.28, y: r.minY + r.height * 0.18), startRadius: 0,
                           endCenter: CGPoint(x: r.minX + r.width * 0.28, y: r.minY + r.height * 0.18), endRadius: r.width * 0.7,
                           options: [])
    ctx.restoreGState()
}

/// At 16–32 px the full artwork turns to mush, so small sizes get a bolder, simpler glyph:
/// a thick screen outline with a large pointer (the phone is dropped).
func drawCompactGlyph(_ ctx: CGContext, in r: CGRect) {
    let s = r.width / 1024
    func rect(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> CGRect {
        CGRect(x: r.minX + x * s, y: r.minY + y * s, width: w * s, height: h * s)
    }
    ctx.setStrokeColor(white)
    ctx.setFillColor(white)
    ctx.setLineWidth(84 * s)
    ctx.addPath(roundedRect(rect(150, 210, 724, 520), 80 * s))
    ctx.strokePath()
    ctx.addPath(roundedRect(rect(352, 800, 320, 70), 35 * s)) // stand base
    ctx.fillPath()
    ctx.addPath(pointerPath(tip: CGPoint(x: r.minX + 330 * s, y: r.minY + 300 * s), height: 380 * s))
    ctx.fillPath()
}

/// The glyph, drawn into a transparent layer so the phone can knock a clean gap out of the screen outline.
/// `r` is the icon body; the glyph is laid out in that body's 1024-unit space.
func drawGlyph(_ ctx: CGContext, in r: CGRect) {
    let s = r.width / 1024
    func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: r.minX + x * s, y: r.minY + y * s) }
    func rect(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> CGRect {
        CGRect(x: r.minX + x * s, y: r.minY + y * s, width: w * s, height: h * s)
    }

    // Shadow under the whole glyph for depth.
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: 14 * s), blur: 36 * s, color: rgb(0x061235, 0.45))
    ctx.beginTransparencyLayer(auxiliaryInfo: nil)

    // Mac screen: outline + stand.
    let screen = rect(150, 244, 610, 400)
    ctx.setStrokeColor(white)
    ctx.setLineWidth(40 * s)
    ctx.addPath(roundedRect(screen, 54 * s))
    ctx.strokePath()
    ctx.setFillColor(white)
    ctx.addPath(roundedRect(rect(385, 684, 140, 32), 16 * s)) // stand base
    ctx.fillPath()
    ctx.fill(rect(436, 640, 38, 48))                           // stand neck

    // Pointer on the screen.
    ctx.addPath(pointerPath(tip: p(296, 328), height: 250 * s))
    ctx.fillPath()

    // iPhone in front of the screen's bottom-right corner: first clear a gap around it…
    let phone = rect(640, 430, 234, 430)
    let gap: CGFloat = 26 * s
    ctx.saveGState()
    ctx.setBlendMode(.clear)
    ctx.addPath(roundedRect(phone.insetBy(dx: -gap, dy: -gap), (58 + 26) * s))
    ctx.fillPath()
    ctx.restoreGState()

    // …then the phone: a softly lit screen, the outline and the Dynamic Island…
    let inner = phone.insetBy(dx: 15 * s, dy: 15 * s)
    ctx.setFillColor(rgb(0xFFFFFF, 0.14))
    ctx.addPath(roundedRect(inner, 44 * s))
    ctx.fillPath()
    ctx.setStrokeColor(white)
    ctx.setLineWidth(30 * s)
    ctx.addPath(roundedRect(inner, 44 * s))
    ctx.strokePath()
    ctx.setFillColor(white)
    ctx.addPath(roundedRect(rect(724, 466, 66, 20), 10 * s))
    ctx.fillPath()
    // …and a finger gliding up toward the pointer: a touch with a fading trail.
    let trail: [(x: CGFloat, y: CGFloat, r: CGFloat, a: CGFloat)] = [
        (683, 632, 11, 0.28), (715, 657, 17, 0.55), (757, 690, 30, 1.0),
    ]
    for t in trail {
        ctx.setFillColor(rgb(0xFFFFFF, t.a))
        let c = p(t.x, t.y)
        ctx.fillEllipse(in: CGRect(x: c.x - t.r * s, y: c.y - t.r * s, width: 2 * t.r * s, height: 2 * t.r * s))
    }

    ctx.endTransparencyLayer()
    ctx.restoreGState()
}

// MARK: - Rendering

func makeContext(_ px: Int) -> CGContext {
    let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0, space: colorSpace,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    // Work in a y-down space.
    ctx.translateBy(x: 0, y: CGFloat(px))
    ctx.scaleBy(x: 1, y: -1)
    ctx.interpolationQuality = .high
    ctx.setShouldAntialias(true)
    return ctx
}

/// iOS: full-bleed opaque square; the system applies the mask.
func renderIOS(px: Int) -> CGImage {
    let ctx = makeContext(px)
    let full = CGRect(x: 0, y: 0, width: px, height: px)
    drawBackground(ctx, clip: CGPath(rect: full, transform: nil), in: full)
    drawGlyph(ctx, in: full)
    return ctx.makeImage()!
}

/// macOS: the rounded-square body is 824/1024 of the canvas, centred slightly high, with a drop shadow.
func renderMac(px: Int) -> CGImage {
    let ctx = makeContext(px)
    let u = CGFloat(px) / 1024
    let body = CGRect(x: 100 * u, y: 92 * u, width: 824 * u, height: 824 * u)
    let shape = continuousRoundedRect(body, radius: 185.4 * u / 1.18)

    // Drop shadow (only meaningful at larger sizes).
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: 10 * u), blur: 28 * u, color: rgb(0x000000, 0.35))
    ctx.addPath(shape)
    ctx.setFillColor(deepBlue)
    ctx.fillPath()
    ctx.restoreGState()

    drawBackground(ctx, clip: shape, in: body)
    ctx.saveGState()
    ctx.addPath(shape)
    ctx.clip()
    if px <= 32 { drawCompactGlyph(ctx, in: body) } else { drawGlyph(ctx, in: body) }
    ctx.restoreGState()

    // Hairline edge highlight so the shape reads on dark backgrounds.
    ctx.saveGState()
    ctx.addPath(shape)
    ctx.setStrokeColor(rgb(0xFFFFFF, 0.18))
    ctx.setLineWidth(max(1, 2 * u))
    ctx.strokePath()
    ctx.restoreGState()
    return ctx.makeImage()!
}

/// Opaque copy (iOS icons must not have an alpha channel).
func opaque(_ image: CGImage) -> CGImage {
    let ctx = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0,
                        space: colorSpace, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    return ctx.makeImage()!
}

func writePNG(_ image: CGImage, to url: URL) {
    let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, image, nil)
    guard CGImageDestinationFinalize(dest) else { fatalError("Couldn't write \(url.path)") }
    print("wrote \(url.path) (\(image.width)×\(image.height))")
}

func writeJSON(_ object: Any, to url: URL) {
    let data = try! JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
    try! data.write(to: url)
    print("wrote \(url.path)")
}

// MARK: - Main

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let iosSet = root.appendingPathComponent("Apps/ReachiOS/Assets.xcassets/AppIcon.appiconset")
let macSet = root.appendingPathComponent("Apps/ReachHost/Assets.xcassets/AppIcon.appiconset")
guard FileManager.default.fileExists(atPath: iosSet.path), FileManager.default.fileExists(atPath: macSet.path) else {
    fatalError("Run from the repository root: swift Tools/make-icons.swift")
}

// iOS — single 1024 size.
writePNG(opaque(renderIOS(px: 1024)), to: iosSet.appendingPathComponent("AppIcon-1024.png"))
writeJSON([
    "images": [["filename": "AppIcon-1024.png", "idiom": "universal", "platform": "ios", "size": "1024x1024"]],
    "info": ["author": "xcode", "version": 1],
], to: iosSet.appendingPathComponent("Contents.json"))

// macOS — 16…512 at 1x and 2x.
var macImages: [[String: String]] = []
for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let px = points * scale
        let name = "icon_\(points)x\(points)\(scale == 2 ? "@2x" : "").png"
        writePNG(renderMac(px: px), to: macSet.appendingPathComponent(name))
        macImages.append(["filename": name, "idiom": "mac", "scale": "\(scale)x", "size": "\(points)x\(points)"])
    }
}
writeJSON(["images": macImages, "info": ["author": "xcode", "version": 1]],
          to: macSet.appendingPathComponent("Contents.json"))
