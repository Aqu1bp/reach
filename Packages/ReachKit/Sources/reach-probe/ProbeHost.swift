import Foundation
import AppKit
import ReachCore
import ReachProtocol

/// A real `HostEngine` driven by a synthetic screen instead of ScreenCaptureKit. Lets the iPhone app
/// and the headless client be tested end-to-end (relays, NAT traversal, video, input) without
/// Screen Recording / Accessibility permissions.
final class ProbeHost: HostEngineDelegate {
    let engine: HostEngine
    let screen: SyntheticScreen
    let display: DisplayInfo
    private var timer: DispatchSourceTimer?
    private var fps = 60
    private var cursor = (x: 0.5, y: 0.5)
    private var buttonDown = false
    private var cursorSeq: UInt32 = 0
    private var pointerCount = 0
    private var lastPointerLog = Date()

    init(state: URL, width: Int, height: Int, policy: String?, turn: IceServerConfig?) throws {
        let store = FileSecretStore(directory: state)
        let identity = try LocalIdentity.loadOrCreate(in: store, key: "host-identity")
        let trust = TrustStore(fileURL: state.appendingPathComponent("trusted-clients.json"))
        screen = SyntheticScreen(width: width, height: height)
        display = DisplayInfo(id: 1, name: "Synthetic Display", frame: Rect(x: 0, y: 0, width: screen.pointWidth, height: screen.pointHeight),
                              pixelWidth: screen.pixelWidth, pixelHeight: screen.pixelHeight, isMain: true, refreshRate: 60)
        var servers = IceServerConfig.defaultSTUN
        if let turn { servers.append(turn) }
        engine = HostEngine(identity: identity, trustStore: trust, iceServers: servers) {
            HostInfo(name: "Probe Mac", model: "MacBook Pro", modelIdentifier: "Probe1,1",
                     osVersion: ProcessInfo.processInfo.operatingSystemVersionString, appVersion: "probe")
        }
        engine.iceTransportPolicyOverride = policy
        engine.delegate = self
    }

    func run(pairingURLFile: URL) {
        engine.start()
        let code = engine.makePairingCode(hostName: "Probe Mac", validFor: 3600)
        try? code.url.absoluteString.write(to: pairingURLFile, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: pairingURLFile.path)
        print("PAIRING_URL \(code.url.absoluteString)")
        print("host id \(engine.identity.id.prefix(8))… fingerprint \(engine.identity.fingerprint); trusted clients: \(engine.trustedClients.map(\.name))")
        let t = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "probe.frames", qos: .userInteractive))
        t.schedule(deadline: .now(), repeating: .nanoseconds(1_000_000_000 / fps), leeway: .milliseconds(1))
        t.setEventHandler { [weak self] in
            guard let self, self.engine.activeSession?.isConnected == true, let f = self.screen.nextFrame() else { return }
            self.engine.pushVideoFrame(f)
        }
        t.resume()
        timer = t
    }

    // MARK: HostEngineDelegate

    func hostEngine(_ engine: HostEngine, relayStatusChanged online: Bool) {
        print("RELAY \(online ? "online" : "offline") \(engine.relayDetail)")
    }

    func hostEngine(_ engine: HostEngine, didPair client: TrustedClient) {
        print("PAIRED \(client.name) (\(client.deviceModel)) \(client.fingerprint)")
        let code = engine.makePairingCode(hostName: "Probe Mac", validFor: 3600)
        print("PAIRING_URL \(code.url.absoluteString)")
    }

    func hostEngine(_ engine: HostEngine, sessionDidStart session: HostSessionInfo) {
        print("SESSION_START \(session.client.name)")
        engine.send(.hello(HostHello(info: HostInfo(name: "Probe Mac", model: "MacBook Pro", modelIdentifier: "Probe1,1", osVersion: "probe", appVersion: "probe"),
                                     displays: [display], activeDisplayID: display.id,
                                     permissions: HostPermissions(screenRecording: true, accessibility: true))))
        engine.send(.stream(StreamInfo(displayID: display.id, width: screen.pixelWidth, height: screen.pixelHeight, maxFramesPerSecond: fps)))
        let png = SyntheticScreen.arrowCursorPNG()
        engine.send(.cursorImage(CursorImage(id: 1, png: png, hotspotX: 1, hotspotY: 1, width: 17, height: 24)))
        engine.send(.frontmostApp(pid: 1, name: "Notes"))
        sendCursor()
    }

    func hostEngine(_ engine: HostEngine, sessionDidEnd session: HostSessionInfo, reason: String) {
        print("SESSION_END \(reason)")
    }

    func hostEngine(_ engine: HostEngine, didReceivePointer packet: PointerPacket) {
        cursor = (Double(packet.x), Double(packet.y))
        screen.inputSeq = packet.seq
        if buttonDown { screen.drag(x: cursor.x * screen.pointWidth, y: cursor.y * screen.pointHeight) }
        sendCursor()
        pointerCount += 1
        if Date().timeIntervalSince(lastPointerLog) > 1 {
            print("POINTER \(pointerCount)/s last=(\(String(format: "%.3f", packet.x)), \(String(format: "%.3f", packet.y))) seq=\(packet.seq)")
            pointerCount = 0
            lastPointerLog = Date()
        }
    }

    func hostEngine(_ engine: HostEngine, didReceive message: ClientMessage) {
        switch message {
        case .mouseButton(let e):
            cursor = (e.x, e.y)
            screen.inputSeq = e.seq
            if e.isDown {
                buttonDown = true
                screen.click(x: e.x * screen.pointWidth, y: e.y * screen.pointHeight, right: e.button == .right)
            } else {
                buttonDown = false
            }
            print("MOUSE \(e.button.rawValue) \(e.isDown ? "down" : "up") count=\(e.clickCount) at (\(String(format: "%.3f", e.x)), \(String(format: "%.3f", e.y)))")
            sendCursor()
        case .scroll(let s):
            screen.scroll(dy: s.dy)
            if s.phase != .changed { print("SCROLL \(s.phase.rawValue) dy=\(Int(s.dy)) v=\(Int(s.velocityY))") }
        case .text(let t):
            screen.type(t.text)
            print("TEXT \(t.text.debugDescription) mods=\(t.modifiers.rawValue)")
        case .key(let k):
            if k.isDown { applyKey(k.code) }
            print("KEY \(k.code) \(k.isDown ? "down" : "up") mods=\(k.modifiers.rawValue)")
        case .keyPress(let code, let mods):
            applyKey(code)
            print("KEYPRESS \(code) mods=\(mods.rawValue)")
        case .requestApps:
            let apps = ["Notes", "Finder", "Safari", "Mail", "Music"].enumerated().map { i, n in
                AppInfo(pid: Int32(i + 1), bundleID: "com.apple.\(n.lowercased())", name: n, icon: nil, isActive: i == 0, isHidden: false)
            }
            engine.send(.apps(apps))
        case .requestWindows:
            engine.send(.windows(screen.windows.map {
                WindowInfo(id: $0.id, pid: 1, appName: $0.app, title: $0.title, frame: $0.frame, isOnScreen: true)
            }))
        case .setClipboard(let c):
            print("CLIPBOARD \(c.text?.count ?? 0) chars, image \(c.imagePNG?.count ?? 0) bytes")
            // Echo a large payload back (host → client fragmentation).
            engine.send(.clipboard(ClipboardContent(text: String(repeating: "Z", count: 900_000))))
        case .hello(let h):
            print("HELLO from \(h.name) \(h.deviceModel) screen=\(h.screenPixelWidth)x\(h.screenPixelHeight) quality=\(h.quality.mode.rawValue)@\(h.quality.maxFramesPerSecond)")
        default:
            print("MSG \(message)")
        }
    }

    private func applyKey(_ code: UInt16) {
        switch code {
        case MacKey.delete: screen.backspace()
        case MacKey.returnKey: screen.type("\n")
        case MacKey.tab: screen.type("\t")
        default: break
        }
    }

    private func sendCursor() {
        cursorSeq &+= 1
        engine.sendCursor(CursorPacket(seq: cursorSeq, x: Float(cursor.x), y: Float(cursor.y), visible: true))
    }
}
