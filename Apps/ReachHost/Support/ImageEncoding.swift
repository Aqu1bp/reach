import AppKit
import ImageIO
import UniformTypeIdentifiers

/// PNG encoding and fixed-size rasterisation. Safe to call from any thread (each call uses its own
/// bitmap context; `NSGraphicsContext.current` is per-thread).
enum ImageEncoding {
    static func png(_ image: CGImage) -> Data? {
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil) else {
            return nil
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return output as Data
    }

    /// Draws `image` into a transparent sRGB bitmap of exactly `pixelWidth × pixelHeight`, letting
    /// AppKit pick the best representation for that size.
    static func rasterize(_ image: NSImage, pixelWidth: Int, pixelHeight: Int) -> CGImage? {
        guard pixelWidth > 0, pixelHeight > 0,
              let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: pixelWidth, height: pixelHeight, bitsPerComponent: 8,
                                      bytesPerRow: 0, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.interpolationQuality = .high
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        image.draw(in: NSRect(x: 0, y: 0, width: pixelWidth, height: pixelHeight),
                   from: .zero, operation: .copy, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()
        return context.makeImage()
    }

    /// PNG of `image` rendered at `points × scale` pixels.
    static func png(_ image: NSImage, points: CGSize, scale: CGFloat) -> Data? {
        let width = Int((points.width * scale).rounded())
        let height = Int((points.height * scale).rounded())
        return rasterize(image, pixelWidth: width, pixelHeight: height).flatMap(png)
    }
}
