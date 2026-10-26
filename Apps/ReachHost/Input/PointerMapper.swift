import CoreGraphics

/// Converts between the iPhone's normalized display coordinates (0…1 within the active display) and
/// macOS global display points (origin at the top-left of the main display, y down — the space
/// `CGEvent` uses).
enum PointerMapper {
    /// How far inside the right and bottom edges a clamped point is kept. A global coordinate of
    /// exactly `maxX`/`maxY` already belongs to a neighbouring display, so the last position on this
    /// one is half a point inside — which is still the last physical pixel on a Retina panel, so hot
    /// corners and Dock reveal keep working.
    static let farEdgeInset: CGFloat = 0.5

    /// The global point for a normalized position, clamped to `frame`. `nil` for non-finite input
    /// or an empty frame (never move the pointer somewhere arbitrary).
    static func globalPoint(normalizedX x: Double, y: Double, in frame: CGRect) -> CGPoint? {
        guard x.isFinite, y.isFinite, frame.width > 0, frame.height > 0 else { return nil }
        let point = CGPoint(x: frame.minX + CGFloat(x) * frame.width,
                            y: frame.minY + CGFloat(y) * frame.height)
        return clamp(point, to: frame)
    }

    static func clamp(_ point: CGPoint, to frame: CGRect) -> CGPoint {
        CGPoint(x: min(max(point.x, frame.minX), frame.maxX - farEdgeInset),
                y: min(max(point.y, frame.minY), frame.maxY - farEdgeInset))
    }

    /// Normalized position of a global point. Deliberately unclamped: the protocol lets the cursor be
    /// reported outside 0…1 when it is on another display.
    static func normalized(_ point: CGPoint, in frame: CGRect) -> (x: Double, y: Double) {
        guard frame.width > 0, frame.height > 0 else { return (0, 0) }
        return (Double((point.x - frame.minX) / frame.width), Double((point.y - frame.minY) / frame.height))
    }
}
