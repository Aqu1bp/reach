import Accelerate
import CoreVideo

/// BGRA bitmap → IOSurface-backed NV12 ('420v', BT.709 video range) pixel buffers — the same format the
/// Mac's ScreenCaptureKit → H.264 → VideoToolbox pipeline delivers, so the demo exercises the real
/// renderer path including the video-range matrix.
final class NV12Converter {
    let width: Int
    let height: Int
    private var info = vImage_ARGBToYpCbCr()
    private var pool: CVPixelBufferPool?

    init?(width: Int, height: Int) {
        self.width = width
        self.height = height
        var range = vImage_YpCbCrPixelRange(Yp_bias: 16, CbCr_bias: 128, YpRangeMax: 235, CbCrRangeMax: 240,
                                            YpMax: 235, YpMin: 16, CbCrMax: 240, CbCrMin: 16)
        let err = vImageConvert_ARGBToYpCbCr_GenerateConversion(kvImage_ARGBToYpCbCrMatrix_ITU_R_709_2, &range, &info,
                                                                kvImageARGB8888, kvImage420Yp8_CbCr8, vImage_Flags(kvImageNoFlags))
        guard err == kvImageNoError else { return nil }
        let attrs: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
            kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
            kCVPixelBufferMetalCompatibilityKey as String: true,
        ]
        CVPixelBufferPoolCreate(kCFAllocatorDefault, [kCVPixelBufferPoolMinimumBufferCountKey as String: 3] as CFDictionary,
                                attrs as CFDictionary, &pool)
        guard pool != nil else { return nil }
    }

    /// `bgra` must be `width × height`, premultiplied BGRA (CGImage little-endian 32-bit).
    func convert(bgra: UnsafeMutableRawPointer, rowBytes: Int) -> CVPixelBuffer? {
        guard let pool else { return nil }
        var out: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &out) == kCVReturnSuccess, let pb = out else { return nil }
        CVBufferSetAttachment(pb, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_709_2, .shouldPropagate)
        CVBufferSetAttachment(pb, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_709_2, .shouldPropagate)
        CVBufferSetAttachment(pb, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_ITU_R_709_2, .shouldPropagate)

        CVPixelBufferLockBaseAddress(pb, [])
        defer { CVPixelBufferUnlockBaseAddress(pb, []) }
        guard let y = CVPixelBufferGetBaseAddressOfPlane(pb, 0), let c = CVPixelBufferGetBaseAddressOfPlane(pb, 1) else { return nil }
        var src = vImage_Buffer(data: bgra, height: vImagePixelCount(height), width: vImagePixelCount(width), rowBytes: rowBytes)
        var yBuf = vImage_Buffer(data: y, height: vImagePixelCount(height), width: vImagePixelCount(width),
                                 rowBytes: CVPixelBufferGetBytesPerRowOfPlane(pb, 0))
        var cBuf = vImage_Buffer(data: c, height: vImagePixelCount(height / 2), width: vImagePixelCount(width / 2),
                                 rowBytes: CVPixelBufferGetBytesPerRowOfPlane(pb, 1))
        // Memory order is B,G,R,A; vImage wants A,R,G,B.
        let permute: [UInt8] = [3, 2, 1, 0]
        let err = vImageConvert_ARGB8888To420Yp8_CbCr8(&src, &yBuf, &cBuf, &info, permute, vImage_Flags(kvImageNoFlags))
        return err == kvImageNoError ? pb : nil
    }
}
