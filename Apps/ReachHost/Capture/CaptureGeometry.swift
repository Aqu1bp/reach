import Foundation
import ReachProtocol

/// Decides the pixel size and frame rate ScreenCaptureKit should deliver.
enum CaptureGeometry {
    /// H.264 level 5.2 allows 36,864 macroblocks per frame, i.e. 4096×2304. The box applies in either
    /// orientation so a portrait display isn't squeezed into a landscape budget.
    static let maxLongSide = 4096
    static let maxShortSide = 2304

    /// Native size scaled down (never up) to fit the encoder box, aspect ratio kept, both sides even
    /// (4:2:0 chroma subsampling needs even dimensions).
    static func outputSize(nativeWidth: Int, nativeHeight: Int, downscale: Int = 1) -> (width: Int, height: Int) {
        outputSize(nativeWidth: nativeWidth, nativeHeight: nativeHeight, scale: 1 / Double(max(1, downscale)))
    }

    /// Native size × `scale` (≤ 1), then fitted to the encoder box like `outputSize(nativeWidth:nativeHeight:downscale:)`.
    static func outputSize(nativeWidth: Int, nativeHeight: Int, scale: Double) -> (width: Int, height: Int) {
        guard nativeWidth > 0, nativeHeight > 0 else { return (2, 2) }
        let s = min(1, max(0.1, scale))
        let width = Double(nativeWidth) * s
        let height = Double(nativeHeight) * s
        let scale = min(1, Double(maxLongSide) / max(width, height), Double(maxShortSide) / min(width, height))
        return (evenFloor(width * scale), evenFloor(height * scale))
    }

    /// The capture rate for a quality preference: the client's cap (10…120), at most 30 for Data
    /// Saver, and never above what the display can actually show.
    static func framesPerSecond(for quality: QualityPreference, displayRefreshRate: Double) -> Int {
        var fps = min(120, max(10, quality.maxFramesPerSecond))
        if quality.mode == .dataSaver { fps = min(fps, 30) }
        if displayRefreshRate >= 24 { fps = min(fps, Int(displayRefreshRate.rounded())) }
        return fps
    }

    /// Stream sizes on offer, as fractions of the display's native pixels. Few and far apart: every
    /// switch restarts the encoder with a keyframe.
    static let scaleTiers: [Double] = [0.5, 0.75, 1]

    /// The smallest tier that still gives the iPhone about one stream pixel per screen pixel it shows
    /// the Mac with. Zoomed out on a phone, a native Retina frame is mostly thrown away after costing
    /// bandwidth and encode/decode time, and at a given bitrate fewer pixels means fewer artifacts.
    /// Sharp oversamples for crisper text; Data Saver never goes above half.
    static func streamScale(nativeWidth: Int, nativeHeight: Int, viewport: ViewportHint?,
                            clientScreen: (width: Int, height: Int)?, mode: QualityMode) -> Double {
        guard nativeWidth > 0, nativeHeight > 0 else { return 1 }
        var shown: (Double, Double)?
        if let v = viewport, v.displayedPixelWidth > 0, v.displayedPixelHeight > 0 {
            shown = (Double(v.displayedPixelWidth), Double(v.displayedPixelHeight))
        } else if let screen = clientScreen, screen.width > 0, screen.height > 0 {
            // Not laid out yet: assume the display fitted to the phone held sideways (the larger case).
            let long = Double(max(screen.width, screen.height)), short = Double(min(screen.width, screen.height))
            let fit = min(long / Double(nativeWidth), short / Double(nativeHeight))
            shown = (Double(nativeWidth) * fit, Double(nativeHeight) * fit)
        }
        // Nothing known yet: start small. Growing takes effect at once when the iPhone reports its
        // viewport, and a small first keyframe gets the picture up sooner.
        guard let shown else { return scaleTiers[0] }
        let needed = max(shown.0 / Double(nativeWidth), shown.1 / Double(nativeHeight))
        // Sharp keeps a 10% margin so text stays crisp while a zoom is still in progress (the stream
        // grows as soon as the new viewport arrives). More than that costs encode time on every
        // frame (portrait would get ¾ for a 1290-px-wide view: ~6 ms more per frame) for detail the
        // screen can't show. Balanced/Smooth accept a little upscaling (invisible at phone density).
        let oversample: Double = mode == .sharp ? 1.1 : 0.9
        let tier = scaleTiers.first { $0 >= needed * oversample } ?? 1
        return mode == .dataSaver ? min(tier, 0.5) : tier
    }

    private static func evenFloor(_ value: Double) -> Int {
        // The epsilon absorbs FP error so e.g. 4096.0 × (2304/2304) doesn't land on 4095.
        max(2, Int((value + 0.001).rounded(.down)) & ~1)
    }
}

/// Caps the stream size by what the connection can carry, so a weak link (cellular, busy Wi-Fi)
/// gets a smaller stream that stays smooth and clean instead of a big one the encoder has to starve
/// (blocky text) or thin out (dropped frames). Fed WebRTC's bandwidth estimate every couple of
/// seconds; steps down after ~4 s below a tier's need and back up after ~6 s comfortably above it.
struct BandwidthTier {
    /// Rough bitrate each tier needs for clean 60 fps motion (≈0.06 bits per pixel per frame on a
    /// 3024×1964 display), as fractions of native pixels → bits per second per native megapixel.
    static let bitsPerNativePixelPerSecond = 3.6

    private(set) var cap: Double = 1
    private var recent: [Double] = []

    /// The largest tier `bps` supports for a display of `nativePixels`.
    static func supportedTier(bps: Double, nativePixels: Double, headroom: Double = 1) -> Double {
        for tier in CaptureGeometry.scaleTiers.reversed() {
            let needed = nativePixels * tier * tier * bitsPerNativePixelPerSecond * headroom
            if bps >= needed { return tier }
        }
        return CaptureGeometry.scaleTiers[0]
    }

    /// Returns true when `cap` changed.
    mutating func update(estimateBps: Double, nativePixels: Double) -> Bool {
        guard estimateBps > 0, nativePixels > 0 else { return false }
        recent.append(estimateBps)
        if recent.count > 3 { recent.removeFirst(recent.count - 3) }
        let old = cap
        // Down: the last two samples (≈4 s) both say the current tier is too big.
        if recent.count >= 2 {
            let best = recent.suffix(2).max()!
            let tier = Self.supportedTier(bps: best, nativePixels: nativePixels)
            if tier < cap { cap = tier }
        }
        // Up: the last three samples (≈6 s) all leave 20% headroom for a bigger tier.
        if recent.count >= 3, cap < 1 {
            let worst = recent.min()!
            let tier = Self.supportedTier(bps: worst, nativePixels: nativePixels, headroom: 1.2)
            if tier > cap { cap = tier }
        }
        return cap != old
    }
}
