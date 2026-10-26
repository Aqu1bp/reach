import UIKit
import CoreVideo
import ReachCore
import ReachProtocol

/// A stand-in for `ClientSession` that behaves like a Mac running Reach Host: it goes through the
/// connection states, sends hello/displays/stream/cursor/apps/windows, renders a synthetic desktop
/// into real NV12 frames and reacts to input (raise and drag windows, type into Notes, scroll, context
/// menus, HUDs for shortcuts and system actions). Launch with `-demo` to use it.
///
/// Threads: `state`/`onState`/`onMessage` on main (like `ClientSession`); the simulated host runs on its
/// own serial queue, which also delivers `onCursor` and `onVideoFrame`.
final class DemoSessionSource: RemoteSessionSource, @unchecked Sendable {
    enum Scenario { case normal, offline }

    private(set) var state: ClientSession.State = .signaling
    var onState: ((ClientSession.State) -> Void)?
    var onMessage: ((HostMessage) -> Void)?
    var onCursor: ((CursorPacket) -> Void)? {
        get { lock.withLock { _onCursor } }
        set { lock.withLock { _onCursor = newValue } }
    }
    var onVideoFrame: ((CVPixelBuffer, Int64) -> Void)? {
        get { lock.withLock { _onVideoFrame } }
        set { lock.withLock { _onVideoFrame = newValue } }
    }
    var controlRoundTripMs: Double? { 3.1 }

    static let hostInfo = HostInfo(name: "Alex’s MacBook Pro", model: "MacBook Pro", modelIdentifier: "Mac14,6",
                                   osVersion: "macOS 26.1", appVersion: "1.0")

    private let scenario: Scenario
    private let lock = NSLock()
    private var _onCursor: ((CursorPacket) -> Void)?
    private var _onVideoFrame: ((CVPixelBuffer, Int64) -> Void)?
    private var seq: UInt32 = 0
    private var frameTimes: [CFTimeInterval] = []

    // Host queue state.
    private let queue = DispatchQueue(label: "reach.demo.host", qos: .userInitiated)
    private let desktop = DemoDesktop()
    private var pointer = CGPoint(x: 0.5, y: 0.5)
    private var hostSeq: UInt32 = 0
    private var dirty = true
    private var drag: (index: Int, offset: CGPoint)?
    private var cursorShape: UInt64 = 1
    private var renderTimer: DispatchSourceTimer?
    private var momentumTimer: DispatchSourceTimer?
    private var converter: NV12Converter?
    private var bitmap: UnsafeMutableRawPointer?
    private var context: CGContext?
    private var closed = false
    private var lastClockMinute = -1
    private var lastBuffer: CVPixelBuffer?

    init(scenario: Scenario, quality: QualityPreference) {
        self.scenario = scenario
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { [weak self] in
            guard let self else { return }
            if scenario == .offline {
                DispatchQueue.main.asyncAfter(deadline: .now() + 3.2) { [weak self] in
                    self?.setState(.failed("Couldn’t reach your Mac. It may be asleep or offline."))
                }
                return
            }
            self.setState(.connecting)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
                self?.setState(.connected)
                self?.queue.async { self?.startHost() }
            }
        }
    }

    deinit {
        renderTimer?.cancel()
        momentumTimer?.cancel()
        bitmap?.deallocate()
    }

    // MARK: RemoteSessionSource

    func send(_ message: ClientMessage) {
        queue.async { [weak self] in self?.handle(message) }
    }

    @discardableResult
    func sendPointer(x: Float, y: Float) -> UInt32 {
        let s = nextSequence()
        queue.async { [weak self] in self?.pointerMoved(CGPoint(x: CGFloat(x), y: CGFloat(y))) }
        return s
    }

    func nextSequence() -> UInt32 {
        lock.withLock { seq &+= 1; return seq }
    }

    func setQuality(_ q: QualityPreference) {
        send(.setQuality(q))
    }

    func setViewport(_ v: ViewportHint) {}

    func stats(completion: @escaping (ConnectionStats?) -> Void) {
        let fps = lock.withLock { () -> Double in
            let now = CACurrentMediaTime()
            frameTimes.removeAll { now - $0 > 1 }
            return Double(frameTimes.count)
        }
        queue.async { [weak self] in
            guard let self else { return }
            let d = self.desktop.activeDisplay
            var s = ConnectionStats()
            s.route = .local
            s.localCandidateType = "host"
            s.remoteCandidateType = "host"
            s.transportProtocol = "udp"
            s.networkType = "wifi"
            s.roundTripMs = 2.6 + Double.random(in: 0...1.4)
            s.framesPerSecond = fps
            s.frameWidth = Int(d.frame.width * d.scale)
            s.frameHeight = Int(d.frame.height * d.scale)
            s.bitrateKbps = fps > 0 ? 900 + fps * 95 + Double.random(in: 0...300) : 140
            s.averageDecodeMs = 1.8 + Double.random(in: 0...0.4)
            s.jitterBufferMs = 11 + Double.random(in: 0...4)
            s.jitterMs = 0.8
            s.packetsLost = 0
            s.codecImplementation = "VideoToolbox (demo)"
            DispatchQueue.main.async { completion(s) }
        }
    }

    /// Simulates a brief network drop so the reconnecting UI can be exercised.
    func restartConnection() {
        DispatchQueue.main.async {
            self.setState(.reconnecting)
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.2) { self.setState(.connected) }
        }
    }

    func close() {
        queue.async { [weak self] in
            guard let self else { return }
            self.closed = true
            self.renderTimer?.cancel()
            self.momentumTimer?.cancel()
        }
        setState(.closed("Disconnected"))
    }

    private func setState(_ s: ClientSession.State) {
        let apply = { [weak self] in
            guard let self, self.state != s, !self.state.isTerminal else { return }
            self.state = s
            self.onState?(s)
        }
        if Thread.isMainThread { apply() } else { DispatchQueue.main.async(execute: apply) }
    }

    private func post(_ m: HostMessage) {
        DispatchQueue.main.async { [weak self] in self?.onMessage?(m) }
    }

    // MARK: Host (queue)

    private func startHost() {
        guard !closed else { return }
        post(.hello(HostHello(info: Self.hostInfo, displays: displayInfos, activeDisplayID: desktop.activeDisplayID,
                              permissions: HostPermissions(screenRecording: true, accessibility: true))))
        postStream()
        let arrow = CursorArt.arrow(scale: 2), beam = CursorArt.iBeam(scale: 2)
        post(.cursorImage(CursorImage(id: 2, png: CursorArt.png(beam), hotspotX: beam.hotspot.x, hotspotY: beam.hotspot.y,
                                      width: beam.size.width, height: beam.size.height)))
        post(.cursorImage(CursorImage(id: 1, png: CursorArt.png(arrow), hotspotX: arrow.hotspot.x, hotspotY: arrow.hotspot.y,
                                      width: arrow.size.width, height: arrow.size.height)))
        post(.frontmostApp(pid: 103, name: desktop.frontApp))
        echoCursor()

        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now(), repeating: 1.0 / (LaunchOptions.renderBench != nil ? LaunchOptions.renderBenchFPS : 60))
        t.setEventHandler { [weak self] in self?.renderIfNeeded() }
        t.resume()
        renderTimer = t
    }

    private var displayInfos: [DisplayInfo] {
        desktop.displays.map { d in
            DisplayInfo(id: d.id, name: d.name, frame: Rect(x: d.frame.minX, y: d.frame.minY, width: d.frame.width, height: d.frame.height),
                        pixelWidth: Int(d.frame.width * d.scale), pixelHeight: Int(d.frame.height * d.scale),
                        isMain: d.id == 1, refreshRate: d.id == 1 ? 120 : 60)
        }
    }

    private func postStream() {
        let d = desktop.activeDisplay
        post(.stream(StreamInfo(displayID: d.id, width: Int(d.frame.width * d.scale), height: Int(d.frame.height * d.scale),
                                maxFramesPerSecond: 60)))
    }

    private func renderIfNeeded() {
        guard !closed else { return }
        if let jitter = LaunchOptions.renderBench, let last = lastBuffer, !dirty, !desktop.needsTimedRedraw {
            if jitter > 0 { usleep(UInt32.random(in: 0...UInt32(jitter * 1000))) }
            lock.withLock { frameTimes.append(CACurrentMediaTime()) }
            onVideoFrame?(last, Int64(DispatchTime.now().uptimeNanoseconds))
            return
        }
        if desktop.needsTimedRedraw { dirty = true }
        let minute = Calendar.current.component(.minute, from: Date())
        if minute != lastClockMinute { lastClockMinute = minute; dirty = true }
        guard dirty else { return }
        dirty = false

        let d = desktop.activeDisplay
        let w = Int(d.frame.width * d.scale), h = Int(d.frame.height * d.scale)
        if converter?.width != w || converter?.height != h {
            converter = NV12Converter(width: w, height: h)
            bitmap?.deallocate()
            bitmap = UnsafeMutableRawPointer.allocate(byteCount: w * h * 4, alignment: 64)
            let info = CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
            context = CGContext(data: bitmap, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: info)
            // UIKit-style drawing: top-left origin, points.
            context?.translateBy(x: 0, y: CGFloat(h))
            context?.scaleBy(x: d.scale, y: -d.scale)
        }
        guard let ctx = context, let bitmap, let converter else { return }
        desktop.draw(in: ctx, size: d.frame.size, scale: d.scale)
        guard let pb = converter.convert(bgra: bitmap, rowBytes: w * 4) else { return }
        lastBuffer = pb
        lock.withLock { frameTimes.append(CACurrentMediaTime()) }
        onVideoFrame?(pb, Int64(DispatchTime.now().uptimeNanoseconds))
    }

    private func local(_ n: CGPoint) -> CGPoint {
        let d = desktop.activeDisplay
        return CGPoint(x: n.x * d.frame.width, y: n.y * d.frame.height)
    }

    private func pointerMoved(_ n: CGPoint) {
        guard !closed else { return }
        pointer = n
        let p = local(n)
        if let drag {
            desktop.move(windowAt: drag.index, to: CGPoint(x: p.x - drag.offset.x, y: p.y - drag.offset.y))
            dirty = true
        }
        let shape: UInt64 = desktop.isOverText(p) ? 2 : 1
        if shape != cursorShape {
            cursorShape = shape
            post(.cursorShape(id: shape))
        }
        echoCursor()
    }

    /// The real host reports the cursor position back on the unreliable channel; simulate ~a LAN hop.
    private func echoCursor() {
        hostSeq &+= 1
        let packet = CursorPacket(seq: hostSeq, x: Float(pointer.x), y: Float(pointer.y), visible: true)
        queue.asyncAfter(deadline: .now() + 0.012) { [weak self] in self?.onCursor?(packet) }
    }

    private func handle(_ m: ClientMessage) {
        guard !closed else { return }
        defer { dirty = true }
        switch m {
        case .mouseButton(let e):
            mouse(e)
        case .scroll(let s):
            scroll(s)
        case .text(let t):
            type(t)
        case .keyPress(let code, let mods):
            press(code, mods)
        case .key(let k):
            if k.isDown, !MacKey.modifierKeys.contains(k.code) { press(k.code, k.modifiers) }
        case .action(let a):
            desktop.showHUD(a.symbol, a.title)
        case .media(let key):
            desktop.showHUD(key.symbol, key.title)
        case .selectDisplay(let id):
            guard desktop.displays.contains(where: { $0.id == id }) else { return }
            desktop.activeDisplayID = id
            post(.displays(displayInfos, activeDisplayID: id))
            postStream()
        case .setQuality(let q):
            desktop.showHUD(q.mode.symbol, "Quality: \(q.mode.title)")
        case .activateApp(let pid):
            if !desktop.raise(pid: pid), let app = desktop.apps.first(where: { $0.pid == pid }) {
                desktop.showHUD(app.symbol, app.name)
            }
            post(.frontmostApp(pid: pid, name: desktop.frontApp))
        case .focusWindow(let id):
            let before = desktop.activeDisplayID
            desktop.raise(windowID: id)
            if desktop.activeDisplayID != before {
                post(.displays(displayInfos, activeDisplayID: desktop.activeDisplayID))
                postStream()
            }
            if let w = desktop.windows.first { post(.frontmostApp(pid: w.pid, name: w.app)) }
        case .requestApps:
            post(.apps(desktop.apps.map { app in
                AppInfo(pid: app.pid, bundleID: app.bundleID, name: app.name,
                        icon: desktop.appIcon(app, size: 64).pngData(),
                        isActive: app.name == desktop.frontApp, isHidden: false)
            }))
        case .requestWindows:
            post(.windows(desktop.windows.map { w in
                WindowInfo(id: w.id, pid: w.pid, appName: w.app, title: w.title,
                           frame: Rect(x: w.frame.minX, y: w.frame.minY, width: w.frame.width, height: w.frame.height),
                           isOnScreen: true)
            }))
        case .setClipboard(let c):
            desktop.showHUD("doc.on.clipboard", c.text.map { "“\($0.prefix(14))”" } ?? "Image pasted")
        case .hello, .ping, .viewport:
            break
        }
    }

    private func mouse(_ e: MouseButtonEvent) {
        let p = local(CGPoint(x: e.x, y: e.y))
        pointer = CGPoint(x: e.x, y: e.y)
        guard e.isDown else {
            drag = nil
            return
        }
        if e.button == .right {
            desktop.contextMenu = (p, Date().addingTimeInterval(5))
            return
        }
        desktop.contextMenu = nil
        if let i = desktop.dockIconIndex(at: p) {
            let app = desktop.apps[i]
            if !desktop.raise(pid: app.pid) { desktop.showHUD(app.symbol, "Opening \(app.name)") }
            post(.frontmostApp(pid: app.pid, name: desktop.frontApp))
            return
        }
        guard let i = desktop.windowIndex(at: p) else { return }
        desktop.raise(i)
        let w = desktop.windows[0]
        post(.frontmostApp(pid: w.pid, name: w.app))
        if desktop.titleBarContains(0, p) {
            let f = desktop.localFrame(w)
            drag = (0, CGPoint(x: p.x - f.minX, y: p.y - f.minY))
        } else if w.kind == .finder {
            desktop.selectedFinderItem = desktop.finderItem(at: p, in: w)
            if e.clickCount >= 2, desktop.selectedFinderItem != nil { desktop.showHUD("folder", "Open") }
        } else if w.kind == .notes, e.clickCount == 2 {
            desktop.showHUD("character.cursor.ibeam", "Select Word")
        } else if e.clickCount >= 3 {
            desktop.showHUD("text.alignleft", "Select Paragraph")
        }
    }

    private func scroll(_ s: ScrollEvent) {
        momentumTimer?.cancel()
        momentumTimer = nil
        guard let i = desktop.windowIndex(at: local(pointer)), desktop.windows[i].kind == .notes else { return }
        switch s.phase {
        case .began, .changed, .discrete:
            desktop.scrollNotes(by: s.dy)
        case .ended:
            // The real host runs momentum on the Mac; simulate it here.
            var v = s.velocityY
            guard abs(v) > 40 else { return }
            let t = DispatchSource.makeTimerSource(queue: queue)
            t.schedule(deadline: .now(), repeating: 1.0 / 60)
            t.setEventHandler { [weak self] in
                guard let self else { return }
                self.desktop.scrollNotes(by: v / 60)
                self.dirty = true
                v *= 0.95
                if abs(v) < 20 { self.momentumTimer?.cancel(); self.momentumTimer = nil }
            }
            t.resume()
            momentumTimer = t
        case .cancelled:
            break
        }
    }

    private func type(_ t: TextInput) {
        let mods = t.modifiers.subtracting([.shift, .capsLock])
        guard mods.isEmpty else {
            shortcut(t.text.uppercased(), t.modifiers)
            return
        }
        let text = t.modifiers.contains(.shift) ? t.text.uppercased() : t.text
        if desktop.windows.first?.kind == .notes {
            desktop.notesText += text
        } else {
            desktop.showHUD("keyboard", "“\(text.prefix(16))”")
        }
    }

    private func press(_ code: UInt16, _ modifiers: KeyModifiers) {
        let mods = modifiers.subtracting([.shift, .capsLock])
        let notesFront = desktop.windows.first?.kind == .notes
        if mods.isEmpty {
            switch code {
            case MacKey.delete:
                if notesFront, !desktop.notesText.isEmpty { desktop.notesText.removeLast() }
                return
            case MacKey.returnKey:
                if notesFront { desktop.notesText += "\n" }
                return
            case MacKey.space:
                if notesFront { desktop.notesText += " " }
                return
            case MacKey.escape:
                desktop.contextMenu = nil
                desktop.showHUD("escape", "esc")
                return
            default:
                let name = KeyNames.name(for: code)
                if notesFront, name.count == 1, name.first?.isLetter == true || name.first?.isNumber == true {
                    desktop.notesText += modifiers.contains(.shift) ? name : name.lowercased()
                    return
                }
            }
        }
        shortcut(KeyNames.name(for: code), modifiers)
    }

    private func shortcut(_ key: String, _ modifiers: KeyModifiers) {
        let combo = StickyModifiers.symbols(modifiers) + key
        if modifiers.contains(.command), key == "C" {
            post(.clipboard(ClipboardContent(text: "Reach makes your Mac feel close.")))
        }
        desktop.showHUD("command", combo)
    }
}

extension MediaKey {
    var title: String {
        switch self {
        case .volumeUp: return "Volume Up"
        case .volumeDown: return "Volume Down"
        case .mute: return "Mute"
        case .playPause: return "Play/Pause"
        case .next: return "Next Track"
        case .previous: return "Previous Track"
        case .brightnessUp: return "Brightness Up"
        case .brightnessDown: return "Brightness Down"
        }
    }

    var symbol: String {
        switch self {
        case .volumeUp: return "speaker.wave.3.fill"
        case .volumeDown: return "speaker.wave.1.fill"
        case .mute: return "speaker.slash.fill"
        case .playPause: return "playpause.fill"
        case .next: return "forward.fill"
        case .previous: return "backward.fill"
        case .brightnessUp: return "sun.max.fill"
        case .brightnessDown: return "sun.min.fill"
        }
    }
}
