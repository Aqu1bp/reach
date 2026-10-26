import Metal
import QuartzCore
import CoreVideo
import UIKit
import os
import ReachCore
import ReachProtocol

/// Draws the Mac's screen, cursor and minimap into a `CAMetalLayer`.
///
/// Threads:
/// * `submit(_:)` — WebRTC's decode thread. Stores the newest frame and asks for a redraw.
/// * `update(_:)`, `attach(_:)`, cursor image calls — main (or any) thread.
/// * Rendering — a dedicated render thread driven by a `CAMetalDisplayLink`: at most one draw per
///   display refresh, and the link pauses after a second of nothing changing. Drawing on every input
///   instead (a video frame *and* each cursor move) queues several presents per refresh, and each
///   queued present adds a frame of lag. Within a refresh, a video frame is drawn the moment it
///   arrives (see "Frame timing").
///
/// Each new video frame is converted once (NV12 → RGB) into a mipmapped intermediate texture; viewport
/// changes only re-run the cheap display pass, so pan/zoom never wait for the network.
final class RemoteRenderer: @unchecked Sendable {
    struct Scene: Equatable {
        /// Canvas size in points and its screen scale.
        var viewSize: CGSize = .zero
        var scale: CGFloat = 3
        /// Where the whole display is drawn, in view points.
        var contentFrame: CGRect = .zero
        var cursor: CursorDraw?
        var minimap: MinimapDraw?
        /// 0 = normal, 1 = frozen/dimmed (reconnecting).
        var dim: Float = 0
    }

    struct CursorDraw: Equatable {
        /// Hotspot position, normalized within the display. Resolved against `contentFrame` at draw
        /// time, so cursor packets from the network thread never need the main-thread viewport.
        var position: CGPoint
        /// View points per cursor point.
        var scale: CGFloat
        /// A mouse button is held: draw a halo.
        var held: Bool
        var visible: Bool
    }

    struct MinimapDraw: Equatable {
        var frame: CGRect
        var visible: CGRect
        var cursor: CGPoint?
        var alpha: Float
    }

    /// Render queue. Called once per (re)connection, when the first frame has been converted.
    var onFirstFrame: (() -> Void)? {
        get { lock.withLock { _onFirstFrame } }
        set { lock.withLock { _onFirstFrame = newValue } }
    }

    let device: MTLDevice

    private let commandQueue: MTLCommandQueue
    private let renderThread = RenderThread()
    /// Render thread only.
    private var displayLink: CAMetalDisplayLink?
    private var linkDelegate: DisplayLinkDelegate?
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "reach", category: "render")
    private var textureCache: CVMetalTextureCache?
    private let nv12Pipeline: MTLRenderPipelineState
    private let bgraPipeline: MTLRenderPipelineState
    private let displayPipeline: MTLRenderPipelineState
    private let spritePipeline: MTLRenderPipelineState
    private let ringPipeline: MTLRenderPipelineState
    private let minimapPipeline: MTLRenderPipelineState

    // Shared state, guarded by `lock`.
    private let lock = NSLock()
    private var pendingFrame: CVPixelBuffer?
    /// When `pendingFrame` arrived from the decoder (CACurrentMediaTime).
    private var pendingFrameAt: CFTimeInterval = 0
    private var scene = Scene()
    /// Something changed since the last draw.
    private var dirty = false
    private var layer: CAMetalLayer?
    private var isActive = true
    private var pendingCursorImages: [CursorImage] = []
    private var activeCursorID: UInt64?
    private var firstFrameReported = false
    private var _onFirstFrame: (() -> Void)?

    // Render-queue state.
    private var rgbTexture: MTLTexture?
    private var mipsValid = false
    private var sprites: [UInt64: Sprite] = [:]
    private var defaultSprite: Sprite?
    private var loggedUnsupportedFormat = false
    private var observers: [NSObjectProtocol] = []
    private let timing = RenderTiming()

    private struct Sprite {
        var texture: MTLTexture
        /// In cursor points.
        var hotspot: CGPoint
        var size: CGSize
    }

    init?() {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue(),
              let library = ShaderLibrary.library(for: device) else { return nil }
        self.device = device
        self.commandQueue = queue
        renderThread.startAndWait()
        CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &textureCache)

        func pipeline(_ fragment: String, blended: Bool) -> MTLRenderPipelineState? {
            let d = MTLRenderPipelineDescriptor()
            d.vertexFunction = library.makeFunction(name: "quad_vertex")
            d.fragmentFunction = library.makeFunction(name: fragment)
            d.colorAttachments[0].pixelFormat = .bgra8Unorm
            if blended {
                let c = d.colorAttachments[0]!
                c.isBlendingEnabled = true
                c.rgbBlendOperation = .add
                c.alphaBlendOperation = .add
                c.sourceRGBBlendFactor = .one
                c.sourceAlphaBlendFactor = .one
                c.destinationRGBBlendFactor = .oneMinusSourceAlpha
                c.destinationAlphaBlendFactor = .oneMinusSourceAlpha
            }
            return try? device.makeRenderPipelineState(descriptor: d)
        }
        guard let nv12 = pipeline("nv12_fragment", blended: false),
              let bgra = pipeline("bgra_fragment", blended: false),
              let display = pipeline("display_fragment", blended: false),
              let sprite = pipeline("sprite_fragment", blended: true),
              let ring = pipeline("ring_fragment", blended: true),
              let minimap = pipeline("minimap_fragment", blended: true) else { return nil }
        nv12Pipeline = nv12
        bgraPipeline = bgra
        displayPipeline = display
        spritePipeline = sprite
        ringPipeline = ring
        minimapPipeline = minimap

        // The GPU may not be used in the background; pause rendering (frames are still accepted).
        let nc = NotificationCenter.default
        observers.append(nc.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: nil) { [weak self] _ in
            self?.setActive(false)
        })
        observers.append(nc.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: nil) { [weak self] _ in
            self?.setActive(true)
        })
    }

    deinit {
        observers.forEach(NotificationCenter.default.removeObserver)
        let link = displayLink, timer = deadlineTimer
        renderThread.perform {
            link?.invalidate()
            if let timer { CFRunLoopTimerInvalidate(timer) }
        }
        renderThread.cancel()
    }

    // MARK: Inputs (any thread)

    func attach(_ layer: CAMetalLayer?) {
        layer?.device = device
        layer?.pixelFormat = .bgra8Unorm
        layer?.framebufferOnly = true
        layer?.maximumDrawableCount = 3
        layer?.isOpaque = true
        // Screen content is sRGB-ish (BT.709 primaries); let Core Animation colour-match it to the
        // P3 display instead of showing oversaturated colours.
        layer?.colorspace = CGColorSpace(name: CGColorSpace.sRGB)
        lock.withLock { self.layer = layer }
        renderThread.perform { [weak self] in self?.installDisplayLink(for: layer) }
        scheduleRender()
    }

    /// Render thread.
    private func installDisplayLink(for layer: CAMetalLayer?) {
        displayLink?.invalidate()
        displayLink = nil
        held = nil
        guard let layer else { return }
        let link = CAMetalDisplayLink(metalLayer: layer)
        let delegate = DisplayLinkDelegate { [weak self] link, update in self?.displayLinkFired(link, update) }
        link.delegate = delegate
        link.preferredFrameLatency = 1
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 120, preferred: 120)
        link.isPaused = !lock.withLock { dirty && isActive }
        link.add(to: .current, forMode: .default)
        displayLink = link
        linkDelegate = delegate
    }

    func submit(_ buffer: CVPixelBuffer) {
        lock.withLock {
            if pendingFrame != nil { timing.coalesced() }
            pendingFrame = buffer
            pendingFrameAt = CACurrentMediaTime()
        }
        scheduleRender()
        renderThread.perform { [weak self] in self?.frameArrived() }
    }

    func update(_ mutate: (inout Scene) -> Void) {
        let changed = lock.withLock { () -> Bool in
            let old = scene
            mutate(&scene)
            return old != scene
        }
        if changed { scheduleRender() }
    }

    var currentScene: Scene { lock.withLock { scene } }

    func addCursorImage(_ image: CursorImage) {
        lock.withLock {
            pendingCursorImages.append(image)
            activeCursorID = image.id
        }
        scheduleRender()
    }

    func setCursorShape(_ id: UInt64) {
        lock.withLock { activeCursorID = id }
        scheduleRender()
    }

    /// Next converted frame triggers `onFirstFrame` again (after a reconnect).
    func resetFirstFrame() {
        lock.withLock { firstFrameReported = false }
    }

    func setActive(_ active: Bool) {
        lock.withLock {
            isActive = active
            // Redraw on the first refresh back. Set here rather than through `scheduleRender`, which
            // only wakes the link when the scene wasn't already dirty: a change that arrived just
            // before going to the background leaves it dirty and would keep the link paused.
            if active { dirty = true }
        }
        renderThread.perform { [weak self] in
            guard let self else { return }
            if !active { self.held = nil }
            self.idleRefreshes = 0
            self.displayLink?.isPaused = !active
        }
    }

    func setNeedsRender() { scheduleRender() }

    /// Marks the scene dirty and wakes the display link if it's paused.
    private func scheduleRender() {
        let wake = lock.withLock { () -> Bool in
            guard isActive, !dirty else { return false }
            dirty = true
            return true
        }
        guard wake else { return }
        renderThread.perform { [weak self] in
            guard let link = self?.displayLink, link.isPaused else { return }
            link.isPaused = false
        }
    }

    // MARK: Frame timing (render thread)
    //
    // Each display link callback hands out the drawable for one refresh: whatever is drawn into it
    // before about `targetTimestamp` (the next refresh) appears at `targetPresentationTimestamp`, two
    // refreshes after the callback. Drawing at the callback, the usual pattern, makes a video frame
    // that lands just after it wait for the next callback and so the next slot — a whole extra
    // refresh, ~40 ms from decode to glass on a 60 Hz iPhone. So the drawable is held until its
    // deadline instead: a video frame arriving meanwhile is drawn into it at once, and anything else
    // that changed (the cursor, the viewport) is drawn at the deadline.
    //
    // A frame that missed its slot (network jitter) is shown a refresh late rather than dropped. If
    // frames keep missing, the stream's phase has settled just after the callbacks and each frame is
    // only late because the one before took its drawable; dropping one frame then lets every
    // following frame make its own slot again.

    private struct HeldDrawable {
        let drawable: CAMetalDrawable
        let deadline: CFTimeInterval
        let presentation: CFTimeInterval
    }

    private var held: HeldDrawable?
    /// The previous slot's deadline: a frame that arrived before it missed that slot.
    private var previousDeadline: CFTimeInterval = 0
    private var deadlineTimer: CFRunLoopTimer?
    private var drewThisRefresh = false
    /// Consecutive callbacks that found a frame which had missed its slot.
    private var lateStreak = 0
    /// Half a second at 60 Hz.
    private static let lateStreakBeforeResync = 30
    private var idleRefreshes = 0
    /// About a second at 60 Hz. Waking a paused link takes a refresh or two before its first
    /// callback, so it keeps running for a moment after the last draw; idle callbacks cost nothing.
    private static let idleRefreshesBeforePause = 60
    /// Time left before `targetTimestamp` for the GPU to finish a draw.
    private static let drawMargin: CFTimeInterval = 0.004

    private func displayLinkFired(_ link: CAMetalDisplayLink, _ update: CAMetalDisplayLink.Update) {
        idleRefreshes = drewThisRefresh ? 0 : idleRefreshes + 1
        drewThisRefresh = false
        held = nil
        if idleRefreshes >= Self.idleRefreshesBeforePause || !lock.withLock({ isActive }) {
            link.isPaused = true
            idleRefreshes = 0
            return
        }
        let slotStart = previousDeadline
        let deadline = update.targetTimestamp - Self.drawMargin
        previousDeadline = deadline
        held = HeldDrawable(drawable: update.drawable, deadline: deadline, presentation: update.targetPresentationTimestamp)
        guard let arrived = lock.withLock({ pendingFrame != nil ? pendingFrameAt : nil }) else {
            lateStreak = 0
            return armDeadlineTimer(deadline)
        }
        // Arrived after the last slot closed: this is its slot.
        if arrived >= slotStart {
            lateStreak = 0
            return drawHeld()
        }
        lateStreak += 1
        if lateStreak < Self.lateStreakBeforeResync { return drawHeld() }
        // Resync: a newer frame arriving before the deadline replaces this one.
        lateStreak = 0
        armDeadlineTimer(deadline)
    }

    /// A video frame was decoded.
    private func frameArrived() {
        guard let held, CACurrentMediaTime() < held.deadline, lock.withLock({ pendingFrame != nil }) else { return }
        drawHeld()
    }

    private func drawHeld() {
        guard let h = held else { return }
        held = nil
        let draw = lock.withLock { () -> Bool in
            let d = dirty && isActive
            dirty = false
            return d
        }
        guard draw else { return }
        drewThisRefresh = true
        render(into: h.drawable, drawStart: CACurrentMediaTime(), target: h.presentation)
    }

    private func armDeadlineTimer(_ deadline: CFTimeInterval) {
        let fireDate = CFAbsoluteTimeGetCurrent() + (deadline - CACurrentMediaTime())
        if let deadlineTimer {
            CFRunLoopTimerSetNextFireDate(deadlineTimer, fireDate)
            return
        }
        // Repeating with a huge interval so it stays valid; each callback moves its fire date.
        let timer = CFRunLoopTimerCreateWithHandler(nil, fireDate, 86_400, 0, 0) { [weak self] _ in self?.drawHeld() }
        CFRunLoopAddTimer(CFRunLoopGetCurrent(), timer, .defaultMode)
        deadlineTimer = timer
    }

    // MARK: Rendering (render thread)

    /// `drawStart` and `target` (the display link's intended presentation time) only feed the timing log.
    private func render(into drawable: CAMetalDrawable, drawStart: CFTimeInterval, target: CFTimeInterval?) {
        let (frame, frameAt, scene, newCursors, cursorID, active) = lock.withLock {
            let f = isActive ? pendingFrame : nil
            if isActive { pendingFrame = nil }
            let c = pendingCursorImages
            pendingCursorImages.removeAll()
            return (f, pendingFrameAt, self.scene, c, activeCursorID, isActive)
        }
        guard active else { return }
        autoreleasepool {
            for image in newCursors { makeSprite(image) }
            guard let commandBuffer = commandQueue.makeCommandBuffer() else { return }
            var keepAlive: [CVMetalTexture] = []
            if let frame, convert(frame, commandBuffer: commandBuffer, keepAlive: &keepAlive) {
                reportFirstFrameIfNeeded()
            }

            if scene.viewSize.width > 0, scene.viewSize.height > 0 {
                let ratio = texelsPerPixel(scene)
                if let tex = rgbTexture, !mipsValid, ratio > 2 || scene.minimap != nil,
                   let blit = commandBuffer.makeBlitCommandEncoder() {
                    blit.generateMipmaps(for: tex)
                    blit.endEncoding()
                    mipsValid = true
                }
                encodeDisplay(scene, ratio: ratio, cursorID: cursorID, target: drawable.texture, commandBuffer: commandBuffer)
            } else {
                clear(drawable.texture, commandBuffer: commandBuffer)
            }
            #if !targetEnvironment(simulator) // presented handlers don't exist in the simulator
            if frame != nil {
                let timing = self.timing
                drawable.addPresentedHandler { d in
                    guard d.presentedTime > 0 else { return timing.presented(nil) }
                    timing.presented(.init(waited: drawStart - frameAt, glass: d.presentedTime - drawStart,
                                           late: target.map { d.presentedTime - $0 }))
                }
            }
            #else
            _ = (frameAt, drawStart, target)
            #endif
            commandBuffer.present(drawable)
            commandBuffer.addCompletedHandler { _ in withExtendedLifetime(keepAlive) {} }
            commandBuffer.commit()
        }
    }

    private func reportFirstFrameIfNeeded() {
        let callback = lock.withLock { () -> (() -> Void)? in
            guard !firstFrameReported else { return nil }
            firstFrameReported = true
            return _onFirstFrame
        }
        callback?()
    }

    private func texelsPerPixel(_ scene: Scene) -> CGFloat {
        guard let tex = rgbTexture, scene.contentFrame.width > 0 else { return 1 }
        return CGFloat(tex.width) / (scene.contentFrame.width * scene.scale)
    }

    /// NV12 (or BGRA) pixel buffer → `rgbTexture`. Returns false if the frame couldn't be used.
    private func convert(_ buffer: CVPixelBuffer, commandBuffer: MTLCommandBuffer, keepAlive: inout [CVMetalTexture]) -> Bool {
        let format = CVPixelBufferGetPixelFormatType(buffer)
        let width = CVPixelBufferGetWidth(buffer), height = CVPixelBufferGetHeight(buffer)
        guard width > 0, height > 0, width <= 16384, height <= 16384 else { return false }

        let isNV12 = format == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange || format == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
        let isBGRA = format == kCVPixelFormatType_32BGRA
        guard isNV12 || isBGRA else {
            if !loggedUnsupportedFormat {
                loggedUnsupportedFormat = true
                logger.error("unsupported pixel format \(format)")
            }
            return false
        }
        guard let target = ensureRGBTexture(width: width, height: height) else { return false }

        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .dontCare
        pass.colorAttachments[0].storeAction = .store
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else { return false }
        defer { encoder.endEncoding() }

        var quad = QuadUniforms(rect: SIMD4(-1, 1, 1, -1), uvRect: SIMD4(0, 0, 1, 1))
        encoder.setVertexBytes(&quad, length: MemoryLayout<QuadUniforms>.stride, index: 0)

        if isNV12 {
            guard CVPixelBufferGetPlaneCount(buffer) == 2,
                  let y = cvTexture(buffer, plane: 0, format: .r8Unorm),
                  let c = cvTexture(buffer, plane: 1, format: .rg8Unorm),
                  let yTex = CVMetalTextureGetTexture(y), let cTex = CVMetalTextureGetTexture(c) else { return false }
            keepAlive += [y, c]
            var u = YUVConversion.uniforms(matrix: YUVConversion.matrix(of: buffer),
                                           fullRange: format == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange)
            encoder.setRenderPipelineState(nv12Pipeline)
            encoder.setFragmentTexture(yTex, index: 0)
            encoder.setFragmentTexture(cTex, index: 1)
            encoder.setFragmentBytes(&u, length: MemoryLayout<YUVConversion.Uniforms>.stride, index: 0)
        } else {
            guard let t = cvTexture(buffer, plane: nil, format: .bgra8Unorm), let tex = CVMetalTextureGetTexture(t) else { return false }
            keepAlive.append(t)
            encoder.setRenderPipelineState(bgraPipeline)
            encoder.setFragmentTexture(tex, index: 0)
        }
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        mipsValid = false
        return true
    }

    private func cvTexture(_ buffer: CVPixelBuffer, plane: Int?, format: MTLPixelFormat) -> CVMetalTexture? {
        guard let cache = textureCache else { return nil }
        let w = plane.map { CVPixelBufferGetWidthOfPlane(buffer, $0) } ?? CVPixelBufferGetWidth(buffer)
        let h = plane.map { CVPixelBufferGetHeightOfPlane(buffer, $0) } ?? CVPixelBufferGetHeight(buffer)
        var out: CVMetalTexture?
        let status = CVMetalTextureCacheCreateTextureFromImage(kCFAllocatorDefault, cache, buffer, nil, format, w, h, plane ?? 0, &out)
        return status == kCVReturnSuccess ? out : nil
    }

    private func ensureRGBTexture(width: Int, height: Int) -> MTLTexture? {
        if let t = rgbTexture, t.width == width, t.height == height { return t }
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: true)
        d.usage = [.renderTarget, .shaderRead]
        d.storageMode = .private
        rgbTexture = device.makeTexture(descriptor: d)
        mipsValid = false
        return rgbTexture
    }

    /// The drawable from the display link must be presented; with nothing to show, present black.
    private func clear(_ target: MTLTexture, commandBuffer: MTLCommandBuffer) {
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        pass.colorAttachments[0].storeAction = .store
        commandBuffer.makeRenderCommandEncoder(descriptor: pass)?.endEncoding()
    }

    private func encodeDisplay(_ scene: Scene, ratio: CGFloat, cursorID: UInt64?, target: MTLTexture, commandBuffer: MTLCommandBuffer) {
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        pass.colorAttachments[0].storeAction = .store
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else { return }
        defer { encoder.endEncoding() }

        let view = scene.viewSize

        // Remote screen
        if let tex = rgbTexture {
            var quad = QuadUniforms(ndc: scene.contentFrame, in: view)
            var u = DisplayUniforms(params: SIMD4(Float(ratio), scene.dim, 0, 0),
                                    texel: SIMD4(1 / Float(tex.width), 1 / Float(tex.height), Float(tex.width), Float(tex.height)))
            encoder.setRenderPipelineState(displayPipeline)
            encoder.setVertexBytes(&quad, length: MemoryLayout<QuadUniforms>.stride, index: 0)
            encoder.setFragmentTexture(tex, index: 0)
            encoder.setFragmentBytes(&u, length: MemoryLayout<DisplayUniforms>.stride, index: 0)
            encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        }

        // Cursor (and its held-button halo), drawn in the same pass so it can never lag the screen.
        if let cursor = scene.cursor, cursor.visible, rgbTexture != nil {
            let f = scene.contentFrame
            let hotspot = CGPoint(x: f.minX + cursor.position.x * f.width, y: f.minY + cursor.position.y * f.height)
            if cursor.held {
                let d: CGFloat = 38
                let rect = CGRect(x: hotspot.x - d / 2, y: hotspot.y - d / 2, width: d, height: d)
                var quad = QuadUniforms(ndc: rect, in: view)
                var u = RingUniforms(color: SIMD4(0.302, 0.584, 1.0, 1.0), params: SIMD4(Float(d * scene.scale), 0.12, 0, 0))
                encoder.setRenderPipelineState(ringPipeline)
                encoder.setVertexBytes(&quad, length: MemoryLayout<QuadUniforms>.stride, index: 0)
                encoder.setFragmentBytes(&u, length: MemoryLayout<RingUniforms>.stride, index: 0)
                encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
            }
            if let sprite = cursorID.flatMap({ sprites[$0] }) ?? defaultCursorSprite() {
                let rect = CGRect(x: hotspot.x - sprite.hotspot.x * cursor.scale,
                                  y: hotspot.y - sprite.hotspot.y * cursor.scale,
                                  width: sprite.size.width * cursor.scale, height: sprite.size.height * cursor.scale)
                var quad = QuadUniforms(ndc: rect, in: view)
                var params = SIMD4<Float>(1, 0, 0, 0)
                encoder.setRenderPipelineState(spritePipeline)
                encoder.setVertexBytes(&quad, length: MemoryLayout<QuadUniforms>.stride, index: 0)
                encoder.setFragmentTexture(sprite.texture, index: 0)
                encoder.setFragmentBytes(&params, length: MemoryLayout<SIMD4<Float>>.stride, index: 0)
                encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
            }
        }

        // Minimap
        if let map = scene.minimap, map.alpha > 0.01, let tex = rgbTexture {
            var quad = QuadUniforms(ndc: map.frame, in: view)
            let px = map.frame.size.applying(CGAffineTransform(scaleX: scene.scale, y: scene.scale))
            let lod = max(log2(Float(tex.width) / Float(max(px.width, 1))) - 0.5, 0)
            let c = map.cursor
            var u = MinimapUniforms(
                visible: SIMD4(Float(map.visible.minX), Float(map.visible.minY), Float(map.visible.maxX), Float(map.visible.maxY)),
                size: SIMD4(Float(px.width), Float(px.height), Float(9 * scene.scale), map.alpha),
                cursor: SIMD4(Float(c?.x ?? 0), Float(c?.y ?? 0), Float(2.6 * scene.scale), c == nil ? 0 : 1),
                params: SIMD4(lod, 0, 0, 0))
            encoder.setRenderPipelineState(minimapPipeline)
            encoder.setVertexBytes(&quad, length: MemoryLayout<QuadUniforms>.stride, index: 0)
            encoder.setFragmentTexture(tex, index: 0)
            encoder.setFragmentBytes(&u, length: MemoryLayout<MinimapUniforms>.stride, index: 0)
            encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        }
    }

    // MARK: Cursor sprites

    private func makeSprite(_ image: CursorImage) {
        guard sprites[image.id] == nil, let ui = UIImage(data: image.png), let cg = ui.cgImage,
              let texture = Self.texture(from: cg, device: device) else { return }
        let w = image.width > 0 ? image.width : Double(cg.width) / 2
        let h = image.height > 0 ? image.height : Double(cg.height) / 2
        sprites[image.id] = Sprite(texture: texture, hotspot: CGPoint(x: image.hotspotX, y: image.hotspotY),
                                   size: CGSize(width: w, height: h))
        if sprites.count > 64 { sprites.removeValue(forKey: sprites.keys.first { $0 != image.id }!) }
    }

    private func defaultCursorSprite() -> Sprite? {
        if let defaultSprite { return defaultSprite }
        let art = CursorArt.arrow(scale: 3)
        guard let tex = Self.texture(from: art.image, device: device) else { return nil }
        defaultSprite = Sprite(texture: tex, hotspot: art.hotspot, size: art.size)
        return defaultSprite
    }

    /// Premultiplied BGRA texture from a CGImage.
    static func texture(from image: CGImage, device: MTLDevice) -> MTLTexture? {
        let w = image.width, h = image.height
        guard w > 0, h > 0, w <= 1024, h <= 1024 else { return nil }
        var data = [UInt8](repeating: 0, count: w * h * 4)
        let info = CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        let ok = data.withUnsafeMutableBytes { raw -> Bool in
            guard let ctx = CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: info) else { return false }
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard ok else { return nil }
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: w, height: h, mipmapped: false)
        d.usage = .shaderRead
        guard let tex = device.makeTexture(descriptor: d) else { return nil }
        tex.replace(region: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0, withBytes: data, bytesPerRow: w * 4)
        return tex
    }
}

/// A thread with its own run loop for the display link, so drawing never waits behind the main thread.
final class RenderThread: Thread, @unchecked Sendable {
    private let ready = DispatchSemaphore(value: 0)
    private var runLoop: CFRunLoop?

    override init() {
        super.init()
        name = "reach.render"
        qualityOfService = .userInteractive
    }

    func startAndWait() {
        start()
        ready.wait()
    }

    override func main() {
        runLoop = CFRunLoopGetCurrent()
        // A run loop with no sources returns immediately; a port keeps it alive.
        RunLoop.current.add(NSMachPort(), forMode: .default)
        ready.signal()
        while !isCancelled {
            _ = RunLoop.current.run(mode: .default, before: .distantFuture)
        }
    }

    /// Runs `block` on the render thread.
    func perform(_ block: @escaping () -> Void) {
        guard let runLoop else { return }
        CFRunLoopPerformBlock(runLoop, CFRunLoopMode.defaultMode.rawValue, block)
        CFRunLoopWakeUp(runLoop)
    }
}

/// `CAMetalDisplayLink` needs an NSObject delegate (held weakly); this forwards to a closure.
final class DisplayLinkDelegate: NSObject, CAMetalDisplayLinkDelegate {
    private let handler: (CAMetalDisplayLink, CAMetalDisplayLink.Update) -> Void
    init(_ handler: @escaping (CAMetalDisplayLink, CAMetalDisplayLink.Update) -> Void) { self.handler = handler }
    func metalDisplayLink(_ link: CAMetalDisplayLink, needsUpdate update: CAMetalDisplayLink.Update) {
        handler(link, update)
    }
}

/// Time from a frame leaving the decoder to it being on glass, logged every couple of seconds, split
/// into waiting for the draw and draw → glass. `late` is how far after the display link's target
/// presentation time the frame actually appeared.
final class RenderTiming: @unchecked Sendable {
    struct Sample {
        var waited: CFTimeInterval
        var glass: CFTimeInterval
        var late: CFTimeInterval?
    }

    private let lock = NSLock()
    private var count = 0
    private var total: CFTimeInterval = 0
    private var worst: CFTimeInterval = 0
    private var waited: CFTimeInterval = 0
    private var glass: CFTimeInterval = 0
    private var late: CFTimeInterval = 0
    private var lateCount = 0
    /// Appeared a refresh or more after the slot it was drawn for.
    private var missed = 0
    private var skipped = 0
    private var since = CACurrentMediaTime()

    /// A decoded frame was replaced by a newer one before it could be drawn.
    func coalesced() { lock.withLock { skipped += 1 } }

    func presented(_ sample: Sample?) {
        let line: String? = lock.withLock {
            if let sample {
                let t = sample.waited + sample.glass
                count += 1
                total += t
                worst = max(worst, t)
                waited += sample.waited
                glass += sample.glass
                if let l = sample.late {
                    late += l
                    lateCount += 1
                    if l > 0.008 { missed += 1 }
                }
            }
            let now = CACurrentMediaTime()
            guard now - since >= 2, count > 0 else { return nil }
            let n = Double(count)
            var l = String(format: "render fps=%.1f decoded→glass avg=%.1fms max=%.1fms (wait %.1f + draw→glass %.1f) skipped=%d",
                           n / (now - since), total / n * 1000, worst * 1000, waited / n * 1000, glass / n * 1000, skipped)
            if lateCount > 0 { l += String(format: " late=%.1fms missed=%d", late / Double(lateCount) * 1000, missed) }
            count = 0; total = 0; worst = 0; waited = 0; glass = 0; late = 0; lateCount = 0; missed = 0; skipped = 0; since = now
            return l
        }
        if let line { ReachLog.info("perf", line) }
    }
}

// MARK: - Uniform layouts (must match ShaderLibrary.source)

struct QuadUniforms {
    var rect: SIMD4<Float>
    var uvRect: SIMD4<Float>

    init(rect: SIMD4<Float>, uvRect: SIMD4<Float>) {
        self.rect = rect
        self.uvRect = uvRect
    }

    /// A view-space rectangle as NDC.
    init(ndc r: CGRect, in view: CGSize) {
        let x0 = Float(r.minX / view.width * 2 - 1), x1 = Float(r.maxX / view.width * 2 - 1)
        let y0 = Float(1 - r.minY / view.height * 2), y1 = Float(1 - r.maxY / view.height * 2)
        self.init(rect: SIMD4(x0, y0, x1, y1), uvRect: SIMD4(0, 0, 1, 1))
    }
}

struct DisplayUniforms {
    var params: SIMD4<Float>
    var texel: SIMD4<Float>
}

struct RingUniforms {
    var color: SIMD4<Float>
    var params: SIMD4<Float>
}

struct MinimapUniforms {
    var visible: SIMD4<Float>
    var size: SIMD4<Float>
    var cursor: SIMD4<Float>
    var params: SIMD4<Float>
}
