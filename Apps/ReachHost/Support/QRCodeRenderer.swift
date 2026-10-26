import CoreImage
import CoreImage.CIFilterBuiltins

/// Renders QR codes as crisp, pixel-exact images.
enum QRCodeRenderer {
    /// One pixel per module plus the quiet zone the generator adds. Scaled up by the view with
    /// interpolation off, so every module stays a sharp square at any size.
    static func image(for text: String, correction: String = "M") -> CGImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        // M (15%) keeps the module count low for a long URL while tolerating glare on a screen.
        filter.correctionLevel = correction
        guard let output = filter.outputImage else { return nil }
        let context = CIContext(options: [.useSoftwareRenderer: false])
        return context.createCGImage(output, from: output.extent)
    }

    /// `image` enlarged by a whole factor with nearest-neighbour sampling. Done here rather than by
    /// the view so no renderer can smooth the modules.
    static func scaled(_ image: CGImage, by factor: Int) -> CGImage? {
        guard factor > 1 else { return image }
        let width = image.width * factor, height = image.height * factor
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else {
            return nil
        }
        context.interpolationQuality = .none
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }
}
