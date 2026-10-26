import AppKit
import ReachCore
import ReachProtocol

/// Streams the Mac's cursor to the iPhone, which draws it locally on top of the video.
///
/// * Position: sampled at 120 Hz while it moves (30 Hz once still for half a second) on a private
///   queue, normalized to the active display, sent only when it changes plus a 1 Hz keepalive.
///   Reading the location is ~0.1 µs (shared memory), so this costs next to nothing.
/// * Shape: `NSCursor.currentSystem` sampled at 25 Hz on the main thread (AppKit), compared
///   byte-for-byte with the previous sample on a utility queue; a new shape is PNG-encoded at 2x and
///   sent once per session as `.cursorImage`, and as `.cursorShape(id:)` on later reuse.
/// * Visibility is always reported as visible: there is no non-deprecated way to ask whether the
///   system cursor is hidden, and guessing wrong would make the iPhone lose the pointer.
final class CursorMonitor: @unchecked Sendable {
    struct Output {
        var position: (CursorPacket) -> Void
        var message: (HostMessage) -> Void
    }

    static let fastInterval: TimeInterval = 1.0 / 120
    static let slowInterval: TimeInterval = 1.0 / 30
    static let shapeInterval: TimeInterval = 1.0 / 25
    static let keepaliveInterval: TimeInterval = 1

    private let geometry: DisplayGeometry
    private let output: Output
    private let positionQueue = DispatchQueue(label: "reach.host.cursor.position", qos: .userInteractive)
    private let shapeQueue = DispatchQueue(label: "reach.host.cursor.shape", qos: .utility)

    // `positionQueue` state.
    private var positionTimer: DispatchSourceTimer?
    private var sequence: UInt32 = 0
    private var lastSent: (x: Float, y: Float)?
    private var lastSentAt: TimeInterval = 0
    private var lastMovedAt: TimeInterval = 0
    private var fastSampling = true

    // Main-thread state.
    private var shapeTimer: Timer?

    // `shapeQueue` state.
    private var lastSample: CursorSample?
    private var currentShapeID: UInt64?
    private var sentShapeIDs: Set<UInt64> = []
    private var encodedShapes: [UInt64: CursorImage] = [:]

    init(geometry: DisplayGeometry, output: Output) {
        self.geometry = geometry
        self.output = output
    }

    @MainActor
    func start() {
        shapeQueue.async {
            self.lastSample = nil
            self.currentShapeID = nil
            self.sentShapeIDs = []
        }
        positionQueue.async {
            self.lastSent = nil
            self.startPositionTimer(interval: Self.fastInterval)
        }
        shapeTimer?.invalidate()
        let timer = Timer(timeInterval: Self.shapeInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.sampleShape() }
        }
        timer.tolerance = 0.01
        // `.common` keeps sampling while menus are tracking on the main thread.
        RunLoop.main.add(timer, forMode: .common)
        shapeTimer = timer
        sampleShape()
    }

    @MainActor
    func stop() {
        shapeTimer?.invalidate()
        shapeTimer = nil
        positionQueue.async {
            self.positionTimer?.cancel()
            self.positionTimer = nil
        }
    }

    /// Re-sends position and shape now (e.g. after switching displays).
    @MainActor
    func refresh() {
        positionQueue.async { self.lastSent = nil }
        shapeQueue.async {
            self.lastSample = nil
            self.currentShapeID = nil
        }
    }

    // MARK: - Position (positionQueue)

    private func startPositionTimer(interval: TimeInterval) {
        positionTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: positionQueue)
        timer.schedule(deadline: .now(), repeating: interval, leeway: .microseconds(Int(interval * 100_000)))
        timer.setEventHandler { [weak self] in self?.samplePosition() }
        positionTimer = timer
        timer.resume()
    }

    private func samplePosition() {
        guard let location = CGEvent(source: nil)?.location else { return }
        let normalized = PointerMapper.normalized(location, in: geometry.frame)
        let sample = (x: Float(normalized.x), y: Float(normalized.y))
        let now = uptimeSeconds()
        let moved = lastSent.map { $0.x != sample.x || $0.y != sample.y } ?? true
        if moved { lastMovedAt = now }
        if moved || now - lastSentAt >= Self.keepaliveInterval {
            sequence &+= 1
            output.position(CursorPacket(seq: sequence, x: sample.x, y: sample.y, visible: true))
            lastSent = sample
            lastSentAt = now
        }
        let wantFast = now - lastMovedAt < 0.5
        if wantFast != fastSampling {
            fastSampling = wantFast
            startPositionTimer(interval: wantFast ? Self.fastInterval : Self.slowInterval)
        }
    }

    // MARK: - Shape

    @MainActor
    private func sampleShape() {
        // `currentSystem` is the only API for another app's cursor; its header warns it "will always
        // be nil in a future version of macOS", so fall back to the arrow rather than show nothing.
        guard let sample = CursorSample(cursor: NSCursor.currentSystem ?? NSCursor.arrow) else { return }
        shapeQueue.async { self.process(sample) }
    }

    private func process(_ sample: CursorSample) {
        guard sample != lastSample else { return }
        lastSample = sample
        let id = sample.contentID
        guard id != currentShapeID else { return }
        currentShapeID = id
        if sentShapeIDs.contains(id) {
            output.message(.cursorShape(id: id))
            return
        }
        guard let image = encodedShapes[id] ?? sample.encoded(id: id) else { return }
        if encodedShapes.count > 64 { encodedShapes.removeAll() }
        encodedShapes[id] = image
        sentShapeIDs.insert(id)
        output.message(.cursorImage(image))
    }
}

/// One snapshot of the system cursor, cheap to compare.
struct CursorSample: Equatable {
    let pixels: Data
    let pixelWidth: Int
    let pixelHeight: Int
    /// Points, from the top-left (NSCursor's hot spot is in flipped image coordinates).
    let hotSpot: CGPoint
    /// Points.
    let size: CGSize
    let image: CGImage

    /// Prefers the image's 2x bitmap (Retina cursors ship one) so nothing needs re-rendering.
    init?(cursor: NSCursor) {
        let nsImage = cursor.image
        let size = nsImage.size
        guard size.width > 0, size.height > 0 else { return nil }
        let targetWidth = Int((size.width * 2).rounded())
        let bitmaps = nsImage.representations.compactMap { $0 as? NSBitmapImageRep }
        let cgImage = bitmaps.first(where: { $0.pixelsWide == targetWidth })?.cgImage
            ?? ImageEncoding.rasterize(nsImage, pixelWidth: targetWidth, pixelHeight: Int((size.height * 2).rounded()))
        guard let cgImage, let data = cgImage.dataProvider?.data else { return nil }
        self.pixels = data as Data
        self.pixelWidth = cgImage.width
        self.pixelHeight = cgImage.height
        self.hotSpot = cursor.hotSpot
        self.size = size
        self.image = cgImage
    }

    /// Stable across launches, so the iPhone can keep its cache.
    var contentID: UInt64 {
        var hash = ContentHash()
        hash.add(pixelWidth)
        hash.add(pixelHeight)
        hash.add(Double(hotSpot.x))
        hash.add(Double(hotSpot.y))
        hash.add(pixels)
        return hash.value
    }

    func encoded(id: UInt64) -> CursorImage? {
        guard let png = ImageEncoding.png(image) else { return nil }
        return CursorImage(id: id, png: png, hotspotX: hotSpot.x, hotspotY: hotSpot.y,
                           width: size.width, height: size.height)
    }

    static func == (lhs: CursorSample, rhs: CursorSample) -> Bool {
        lhs.hotSpot == rhs.hotSpot && lhs.pixelWidth == rhs.pixelWidth && lhs.pixelHeight == rhs.pixelHeight
            && lhs.pixels == rhs.pixels
    }
}
