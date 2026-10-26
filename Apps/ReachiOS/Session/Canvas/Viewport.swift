import UIKit

/// Where the Mac's screen sits inside the canvas view. Pure value math; no UIKit state.
///
/// Spaces:
/// * **content** — Mac points of the active display (origin top-left, y down).
/// * **normalized** — content / contentSize, what the wire protocol uses (0…1).
/// * **view** — canvas points.
///
/// `zoom` is view points per Mac point, so `zoom == 1` is "1:1": Mac UI at its native point size,
/// exactly as legible as iOS text of the same size.
struct Viewport: Equatable {
    var contentSize = CGSize(width: 1512, height: 982)
    var bounds = CGSize(width: 390, height: 844)
    /// Parts of the view covered by the keyboard and its accessory bar.
    var insets = UIEdgeInsets.zero
    var zoom: CGFloat = 0.25
    /// View position of the content's top-left corner.
    var offset = CGPoint.zero

    static let maxZoomAbsolute: CGFloat = 4

    var visibleArea: CGRect { CGRect(origin: .zero, size: bounds).inset(by: insets) }

    /// Fit the whole display in the full view (not the keyboard-reduced area — zoom shouldn't jump
    /// when the keyboard appears; the visible area pans instead).
    var fitZoom: CGFloat {
        guard contentSize.width > 0, contentSize.height > 0, bounds.width > 0, bounds.height > 0 else { return 1 }
        return min(bounds.width / contentSize.width, bounds.height / contentSize.height)
    }

    var minZoom: CGFloat { fitZoom }
    var maxZoom: CGFloat { max(Self.maxZoomAbsolute, fitZoom * 1.5) }

    var contentFrame: CGRect {
        CGRect(x: offset.x, y: offset.y, width: contentSize.width * zoom, height: contentSize.height * zoom)
    }

    var isAtFit: Bool { abs(zoom - fitZoom) / fitZoom < 0.01 }

    /// True when some of the display is out of view (minimap and cursor-follow only matter then).
    var isZoomedIn: Bool {
        let f = contentFrame, v = visibleArea
        return f.width > v.width + 0.5 || f.height > v.height + 0.5
    }

    // MARK: Conversions

    func viewPoint(forContent p: CGPoint) -> CGPoint {
        CGPoint(x: offset.x + p.x * zoom, y: offset.y + p.y * zoom)
    }

    func contentPoint(forView p: CGPoint) -> CGPoint {
        CGPoint(x: (p.x - offset.x) / zoom, y: (p.y - offset.y) / zoom)
    }

    func normalized(forView p: CGPoint) -> CGPoint {
        let c = contentPoint(forView: p)
        return CGPoint(x: min(max(c.x / contentSize.width, 0), 1), y: min(max(c.y / contentSize.height, 0), 1))
    }

    func viewPoint(forNormalized n: CGPoint) -> CGPoint {
        viewPoint(forContent: CGPoint(x: n.x * contentSize.width, y: n.y * contentSize.height))
    }

    /// The part of the display currently visible, in normalized coordinates (for the minimap).
    var visibleNormalizedRect: CGRect {
        let v = visibleArea
        let a = contentPoint(forView: v.origin), b = contentPoint(forView: CGPoint(x: v.maxX, y: v.maxY))
        let r = CGRect(x: a.x / contentSize.width, y: a.y / contentSize.height,
                       width: (b.x - a.x) / contentSize.width, height: (b.y - a.y) / contentSize.height)
        return r.intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
    }

    // MARK: Limits

    /// Allowed range for `offset` at `zoom`. When the content is smaller than the visible area along an
    /// axis it is centred there (min == max).
    func offsetRange(zoom z: CGFloat) -> (x: ClosedRange<CGFloat>, y: ClosedRange<CGFloat>) {
        let v = visibleArea
        let w = contentSize.width * z, h = contentSize.height * z
        let xr: ClosedRange<CGFloat> = w <= v.width
            ? (v.midX - w / 2)...(v.midX - w / 2)
            : (v.maxX - w)...v.minX
        // When the keyboard is up but the content still fits the full view vertically, centre it in the
        // area above the keyboard rather than the whole view.
        let yr: ClosedRange<CGFloat> = h <= v.height
            ? (v.midY - h / 2)...(v.midY - h / 2)
            : (v.maxY - h)...v.minY
        return (xr, yr)
    }

    func clampedOffset(_ o: CGPoint, zoom z: CGFloat) -> CGPoint {
        let r = offsetRange(zoom: z)
        return CGPoint(x: o.x.clamped(to: r.x), y: o.y.clamped(to: r.y))
    }

    /// UIScrollView-style resistance past the edges while a finger is down.
    func rubberBandedOffset(_ o: CGPoint, zoom z: CGFloat) -> CGPoint {
        let r = offsetRange(zoom: z)
        return CGPoint(x: Self.rubberBand(o.x, range: r.x, dimension: bounds.width),
                       y: Self.rubberBand(o.y, range: r.y, dimension: bounds.height))
    }

    func rubberBandedZoom(_ z: CGFloat) -> CGFloat {
        if z > maxZoom { return maxZoom * pow(z / maxZoom, 0.3) }
        if z < minZoom { return minZoom * pow(z / minZoom, 0.3) }
        return z
    }

    func clampedZoom(_ z: CGFloat) -> CGFloat { z.clamped(to: minZoom...maxZoom) }

    static func rubberBand(_ x: CGFloat, range: ClosedRange<CGFloat>, dimension d: CGFloat) -> CGFloat {
        let c: CGFloat = 0.55
        func band(_ over: CGFloat) -> CGFloat { (1 - 1 / (over * c / max(d, 1) + 1)) * d }
        if x < range.lowerBound { return range.lowerBound - band(range.lowerBound - x) }
        if x > range.upperBound { return range.upperBound + band(x - range.upperBound) }
        return x
    }

    // MARK: Targets

    /// Offset that keeps `content` under `view` at zoom `z`.
    func offset(keeping content: CGPoint, at view: CGPoint, zoom z: CGFloat) -> CGPoint {
        CGPoint(x: view.x - content.x * z, y: view.y - content.y * z)
    }

    mutating func fit() {
        zoom = fitZoom
        offset = clampedOffset(.zero, zoom: zoom)
    }

    /// Zoom and offset that frame `rect` (content space) inside the visible area with a small margin.
    func framing(_ rect: CGRect, margin: CGFloat = 12) -> (zoom: CGFloat, offset: CGPoint) {
        let v = visibleArea.insetBy(dx: margin, dy: margin)
        guard rect.width > 0, rect.height > 0, v.width > 0, v.height > 0 else { return (zoom, offset) }
        let z = clampedZoom(min(v.width / rect.width, v.height / rect.height))
        let o = CGPoint(x: v.midX - rect.midX * z, y: v.midY - rect.midY * z)
        return (z, clampedOffset(o, zoom: z))
    }
}

extension Comparable {
    func clamped(to r: ClosedRange<Self>) -> Self { min(max(self, r.lowerBound), r.upperBound) }
}

extension CGPoint {
    static func + (a: CGPoint, b: CGPoint) -> CGPoint { CGPoint(x: a.x + b.x, y: a.y + b.y) }
    static func - (a: CGPoint, b: CGPoint) -> CGPoint { CGPoint(x: a.x - b.x, y: a.y - b.y) }
    func distance(to p: CGPoint) -> CGFloat { hypot(x - p.x, y - p.y) }
    var length: CGFloat { hypot(x, y) }
}
