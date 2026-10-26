import UIKit

/// Built-in cursor artwork: the fallback arrow shown before the Mac sends its cursor image, and the
/// shapes the demo host sends.
enum CursorArt {
    struct Art {
        let image: CGImage
        /// In points.
        let hotspot: CGPoint
        let size: CGSize
    }

    /// The classic macOS arrow: black body, white outline, soft shadow.
    static func arrow(scale: CGFloat) -> Art {
        let size = CGSize(width: 18, height: 26)
        let tip = CGPoint(x: 3.5, y: 2.5)
        let image = render(size: size, scale: scale) { ctx in
            let path = UIBezierPath()
            let outline: [(CGFloat, CGFloat)] = [(0, 0), (0, 17), (4.1, 13.3), (6.7, 19.5), (9.5, 18.3), (7.0, 12.3), (12.4, 12.3)]
            let pts = outline.map { CGPoint(x: tip.x + $0.0, y: tip.y + $0.1) }
            path.move(to: pts[0])
            pts.dropFirst().forEach { path.addLine(to: $0) }
            path.close()
            path.lineJoinStyle = .round
            ctx.setShadow(offset: CGSize(width: 0, height: 1), blur: 2.2, color: UIColor.black.withAlphaComponent(0.4).cgColor)
            UIColor.white.setStroke()
            path.lineWidth = 2.4
            path.stroke()
            ctx.setShadow(offset: .zero, blur: 0, color: nil)
            UIColor.black.setFill()
            path.fill()
        }
        return Art(image: image, hotspot: tip, size: size)
    }

    /// Text I-beam.
    static func iBeam(scale: CGFloat) -> Art {
        let size = CGSize(width: 12, height: 22)
        let image = render(size: size, scale: scale) { _ in
            let path = UIBezierPath()
            path.move(to: CGPoint(x: 3, y: 2)); path.addQuadCurve(to: CGPoint(x: 6, y: 4), controlPoint: CGPoint(x: 5.4, y: 2))
            path.addQuadCurve(to: CGPoint(x: 9, y: 2), controlPoint: CGPoint(x: 6.6, y: 2))
            path.move(to: CGPoint(x: 6, y: 4)); path.addLine(to: CGPoint(x: 6, y: 18))
            path.move(to: CGPoint(x: 3, y: 20)); path.addQuadCurve(to: CGPoint(x: 6, y: 18), controlPoint: CGPoint(x: 5.4, y: 20))
            path.addQuadCurve(to: CGPoint(x: 9, y: 20), controlPoint: CGPoint(x: 6.6, y: 20))
            path.move(to: CGPoint(x: 4, y: 11)); path.addLine(to: CGPoint(x: 8, y: 11))
            path.lineCapStyle = .round
            UIColor.white.setStroke(); path.lineWidth = 3.2; path.stroke()
            UIColor.black.setStroke(); path.lineWidth = 1.3; path.stroke()
        }
        return Art(image: image, hotspot: CGPoint(x: 6, y: 11), size: size)
    }

    static func png(_ art: Art) -> Data {
        UIImage(cgImage: art.image).pngData() ?? Data()
    }

    private static func render(size: CGSize, scale: CGFloat, draw: (CGContext) -> Void) -> CGImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = scale
        format.opaque = false
        let image = UIGraphicsImageRenderer(size: size, format: format).image { draw($0.cgContext) }
        return image.cgImage!
    }
}
