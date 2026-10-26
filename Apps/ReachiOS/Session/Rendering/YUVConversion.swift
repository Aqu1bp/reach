import CoreVideo
import simd

/// Builds the Y'CbCr → R'G'B' matrix for a decoded frame.
///
/// The Mac captures in BT.709 video range ('420v'), but the matrix is chosen per pixel buffer: the
/// range from the pixel format ('420v' vs '420f') and the coefficients from the buffer's
/// `YCbCrMatrix` attachment when present (BT.601 / BT.2020), defaulting to BT.709.
enum YUVConversion {
    struct Uniforms {
        var r: SIMD4<Float>
        var g: SIMD4<Float>
        var b: SIMD4<Float>
        var offset: SIMD4<Float>
    }

    enum Matrix { case bt601, bt709, bt2020 }

    static func matrix(of buffer: CVPixelBuffer) -> Matrix {
        guard let value = CVBufferCopyAttachment(buffer, kCVImageBufferYCbCrMatrixKey, nil) as? String else { return .bt709 }
        if value == (kCVImageBufferYCbCrMatrix_ITU_R_601_4 as String) || value == (kCVImageBufferYCbCrMatrix_SMPTE_240M_1995 as String) {
            return .bt601
        }
        if value == (kCVImageBufferYCbCrMatrix_ITU_R_2020 as String) { return .bt2020 }
        return .bt709
    }

    static func uniforms(matrix: Matrix, fullRange: Bool) -> Uniforms {
        let (kr, kb): (Float, Float)
        switch matrix {
        case .bt601: (kr, kb) = (0.299, 0.114)
        case .bt709: (kr, kb) = (0.2126, 0.0722)
        case .bt2020: (kr, kb) = (0.2627, 0.0593)
        }
        let kg = 1 - kr - kb
        let crToR = 2 * (1 - kr)                 // 1.5748 for BT.709
        let cbToB = 2 * (1 - kb)                 // 1.8556
        let cbToG = -2 * kb * (1 - kb) / kg      // -0.1873
        let crToG = -2 * kr * (1 - kr) / kg      // -0.4681

        // Video range: Y' 16…235, CbCr 16…240 (8-bit). Full range: Y' 0…255.
        let ys: Float = fullRange ? 1 : 255.0 / 219.0
        let cs: Float = fullRange ? 1 : 255.0 / 224.0
        let yOffset: Float = fullRange ? 0 : 16.0 / 255.0
        let cOffset: Float = 128.0 / 255.0

        return Uniforms(
            r: SIMD4(ys, 0, crToR * cs, 0),
            g: SIMD4(ys, cbToG * cs, crToG * cs, 0),
            b: SIMD4(ys, cbToB * cs, 0, 0),
            offset: SIMD4(yOffset, cOffset, cOffset, 0)
        )
    }
}
