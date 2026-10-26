import AppKit
import ReachCore
import ReachProtocol

/// `--self-test`: checks the pure logic (and a few system behaviours it depends on) without needing
/// a session, Screen Recording or Accessibility. Prints one line per check and a summary.
@MainActor
enum SelfTest {
    static func run() -> Bool {
        // AppKit resources such as NSCursor.arrow are empty until the application object exists.
        _ = NSApplication.shared
        var t = Checks()
        pointerMapping(&t)
        captureGeometry(&t)
        momentum(&t)
        accumulator(&t)
        keyFlags(&t)
        layoutMap(&t)
        textPlanner(&t)
        symbolicHotKeys(&t)
        actionResolver(&t)
        scrollEventConversion(&t)
        formatting(&t)
        modelNames(&t)
        qrCode(&t)
        clipboardLimits(&t)
        appListBatching(&t)
        turnServer(&t)
        cursorSamplingCost(&t)
        print("\n\(t.passed) passed, \(t.failed) failed")
        return t.failed == 0
    }

    // MARK: - Groups

    private static func pointerMapping(_ t: inout Checks) {
        t.group("PointerMapper")
        let frame = CGRect(x: -1512, y: 0, width: 1512, height: 982)
        t.near(PointerMapper.globalPoint(normalizedX: 0, y: 0, in: frame), CGPoint(x: -1512, y: 0), "top-left corner")
        t.near(PointerMapper.globalPoint(normalizedX: 0.5, y: 0.5, in: frame), CGPoint(x: -756, y: 491), "centre")
        t.near(PointerMapper.globalPoint(normalizedX: 1, y: 1, in: frame), CGPoint(x: -0.5, y: 981.5),
               "far edge stays on this display")
        t.near(PointerMapper.globalPoint(normalizedX: -3, y: 7, in: frame), CGPoint(x: -1512, y: 981.5), "clamped")
        t.expect(PointerMapper.globalPoint(normalizedX: .nan, y: 0.5, in: frame) == nil, "NaN rejected")
        t.expect(PointerMapper.globalPoint(normalizedX: 0.5, y: .infinity, in: frame) == nil, "infinity rejected")
        t.expect(PointerMapper.globalPoint(normalizedX: 0.5, y: 0.5, in: .zero) == nil, "empty frame rejected")
        let back = PointerMapper.normalized(CGPoint(x: -378, y: 245.5), in: frame)
        t.expect(abs(back.x - 0.75) < 1e-9 && abs(back.y - 0.25) < 1e-9, "normalized round trip")
        let outside = PointerMapper.normalized(CGPoint(x: 100, y: 0), in: frame)
        t.expect(outside.x > 1, "normalized is unclamped off-display")
    }

    private static func captureGeometry(_ t: inout Checks) {
        t.group("CaptureGeometry")
        t.equal(CaptureGeometry.outputSize(nativeWidth: 3024, nativeHeight: 1964), (3024, 1964), "MacBook Pro 14 native")
        t.equal(CaptureGeometry.outputSize(nativeWidth: 5120, nativeHeight: 2880), (4096, 2304), "5K capped to box")
        t.equal(CaptureGeometry.outputSize(nativeWidth: 6016, nativeHeight: 3384), (4096, 2304), "6K (16:9) capped to box")
        t.equal(CaptureGeometry.outputSize(nativeWidth: 5120, nativeHeight: 3200), (3686, 2304), "16:10 keeps aspect, even")
        t.equal(CaptureGeometry.outputSize(nativeWidth: 2160, nativeHeight: 3840), (2160, 3840), "portrait 4K fits as is")
        t.equal(CaptureGeometry.outputSize(nativeWidth: 2880, nativeHeight: 5120), (2304, 4096), "portrait 5K uses rotated box")
        t.equal(CaptureGeometry.outputSize(nativeWidth: 3024, nativeHeight: 1964, downscale: 2), (1512, 982), "data saver half")
        t.equal(CaptureGeometry.outputSize(nativeWidth: 1366, nativeHeight: 767), (1366, 766), "odd height made even")
        t.equal(CaptureGeometry.outputSize(nativeWidth: 0, nativeHeight: 100), (2, 2), "degenerate input")
        t.equal(CaptureGeometry.outputSize(nativeWidth: 3024, nativeHeight: 1964, scale: 0.75), (2268, 1472), "¾ tier, even sides")
        func tier(_ w: Int, _ h: Int, _ mode: QualityMode = .balanced) -> Double {
            CaptureGeometry.streamScale(nativeWidth: 3024, nativeHeight: 1964,
                                        viewport: ViewportHint(displayedPixelWidth: w, displayedPixelHeight: h),
                                        clientScreen: nil, mode: mode)
        }
        t.equal(tier(1290, 838), 0.5, "iPhone portrait, fitted: half resolution")
        t.equal(tier(1986, 1290), 0.75, "iPhone landscape, fitted: ¾")
        t.equal(tier(3000, 1948), 1, "zoomed in: native")
        t.equal(tier(9000, 5845), 1, "deep zoom never exceeds native")
        t.equal(tier(1290, 838, .sharp), 0.5, "Sharp, portrait: half already exceeds what's shown")
        t.equal(tier(1450, 942, .sharp), 0.75, "Sharp keeps a margin above what's shown")
        t.equal(tier(1450, 942), 0.5, "Balanced accepts slight upscaling")
        t.equal(tier(3000, 1948, .dataSaver), 0.5, "Data Saver capped at half")
        t.equal(CaptureGeometry.streamScale(nativeWidth: 3024, nativeHeight: 1964, viewport: nil,
                                            clientScreen: (1290, 2796), mode: .balanced), 0.75,
                "no viewport yet: assume landscape fit of the phone screen")
        t.equal(CaptureGeometry.streamScale(nativeWidth: 3024, nativeHeight: 1964, viewport: nil,
                                            clientScreen: nil, mode: .balanced), 0.5, "nothing known: start small")
        do {
            let px = Double(3024 * 1964)
            var b = BandwidthTier()
            _ = b.update(estimateBps: 30e6, nativePixels: px)
            _ = b.update(estimateBps: 30e6, nativePixels: px)
            _ = b.update(estimateBps: 8e6, nativePixels: px)
            t.equal(b.cap, 1, "one low sample is ignored")
            _ = b.update(estimateBps: 8e6, nativePixels: px)
            t.equal(b.cap, 0.5, "~4 s at 8 Mbps steps down to half")
            _ = b.update(estimateBps: 15e6, nativePixels: px)
            _ = b.update(estimateBps: 15e6, nativePixels: px)
            t.equal(b.cap, 0.5, "steps up only after ~6 s of headroom")
            _ = b.update(estimateBps: 15e6, nativePixels: px)
            t.equal(b.cap, 0.75, "15 Mbps sustained: ¾")
            for _ in 0..<3 { _ = b.update(estimateBps: 30e6, nativePixels: px) }
            t.equal(b.cap, 1, "30 Mbps sustained: native")
        }
        let balanced = QualityPreference(mode: .balanced, maxFramesPerSecond: 120)
        t.expect(CaptureGeometry.framesPerSecond(for: balanced, displayRefreshRate: 120) == 120, "120 Hz ProMotion")
        t.expect(CaptureGeometry.framesPerSecond(for: balanced, displayRefreshRate: 60) == 60, "capped at refresh")
        t.expect(CaptureGeometry.framesPerSecond(for: balanced, displayRefreshRate: 0) == 120, "unknown refresh ignored")
        t.expect(CaptureGeometry.framesPerSecond(for: .init(mode: .dataSaver, maxFramesPerSecond: 60),
                                                 displayRefreshRate: 120) == 30, "data saver ≤ 30")
        t.expect(CaptureGeometry.framesPerSecond(for: .init(mode: .sharp, maxFramesPerSecond: 1),
                                                 displayRefreshRate: 60) == 10, "floor 10 fps")
    }

    private static func momentum(_ t: inout Checks) {
        t.group("ScrollMomentum")
        t.expect(ScrollMomentum(velocityX: 0, velocityY: 30) == nil, "slow release doesn't coast")
        t.expect(ScrollMomentum(velocityX: .nan, velocityY: 3000) == nil, "NaN velocity rejected")
        guard let fling = ScrollMomentum(velocityX: 0, velocityY: 2000) else { return t.fail("fling should coast") }
        t.expect(fling.offset(at: 0).dy == 0, "starts at zero")
        t.expect(fling.duration > 0.5 && fling.duration <= ScrollMomentum.maximumDuration, "duration \(fling.duration)")
        let early = fling.offset(at: 0.1).dy, late = fling.offset(at: 0.2).dy - early
        t.expect(early > late && late > 0, "decelerates")
        t.expect(abs(fling.speed(at: fling.duration) - ScrollMomentum.stopSpeed) < 0.5, "ends at stop speed")
        // Closed form vs. the definition (0.998 retained per ms): ∫ v·r^t dt summed in 1 ms steps.
        var sum = 0.0
        for ms in 0..<Int(fling.duration * 1000) { sum += 2000 * pow(0.998, Double(ms)) / 1000 }
        t.expect(abs(sum - fling.totalDistance.dy) / sum < 0.01, "closed form ≈ discrete (\(Int(sum)) pt)")
        guard let huge = ScrollMomentum(velocityX: 1e9, velocityY: 0) else { return t.fail("huge fling should coast") }
        t.expect(abs(huge.velocityX - ScrollMomentum.maximumSpeed) < 1e-6, "speed limited")
    }

    private static func accumulator(_ t: inout Checks) {
        t.group("ScrollAccumulator")
        var a = ScrollAccumulator()
        var total: Int32 = 0
        for _ in 0..<10 { total += a.take(dx: 0, dy: 0.3).dy }
        t.expect(total == 3, "carries fractions (10 × 0.3 → 3)")
        a.reset()
        t.expect(a.take(dx: -1.6, dy: 0).dx == -2, "rounds negative")
        a.reset()
        let extreme = a.take(dx: 1e300, dy: -.infinity)
        t.expect(extreme.dy == 0 && extreme.dx > 0, "extreme input clamped, non-finite ignored")
    }

    private static func keyFlags(_ t: inout Checks) {
        t.group("KeyFlags")
        let cmdShift = KeyFlags.flags(for: [.command, .shift])
        t.expect(cmdShift.contains(.maskCommand) && cmdShift.contains(.maskShift), "⌘⇧ masks")
        t.expect(cmdShift.rawValue & KeyFlags.Device.leftCommand != 0, "left ⌘ device bit by default")
        let right = KeyFlags.flags(for: .option, heldKeys: [MacKey.rightOption])
        t.expect(right.rawValue & KeyFlags.Device.rightOption != 0 && right.rawValue & KeyFlags.Device.leftOption == 0,
                 "right ⌥ device bit when right key held")
        t.expect(KeyFlags.intrinsicFlags(forKeyCode: MacKey.leftArrow) == [.maskSecondaryFn, .maskNumericPad], "arrow: fn+numpad")
        t.expect(KeyFlags.intrinsicFlags(forKeyCode: MacKey.f11) == .maskSecondaryFn, "F11: fn")
        t.expect(KeyFlags.intrinsicFlags(forKeyCode: MacKey.keypad5) == .maskNumericPad, "keypad: numpad")
        t.expect(KeyFlags.intrinsicFlags(forKeyCode: MacKey.a).isEmpty, "letter: none")
        t.expect(KeyFlags.keysToHold(for: [.command, .control, .shift]).map(\.code) == [MacKey.control, MacKey.shift, MacKey.command],
                 "hold order ⌃⇧⌘")
        t.expect(KeyFlags.keysToHold(for: .capsLock).isEmpty, "caps lock is never held")
    }

    private static func layoutMap(_ t: inout Checks) {
        t.group("KeyboardLayoutMap")
        // A tiny synthetic layout: "a"/"A" on 0x00, "é" only via Option, "q" twice (first wins).
        let synthetic = KeyboardLayoutMap(layoutName: "Test") { code, modifiers in
            switch (code, modifiers) {
            case (MacKey.a, []): return "a"
            case (MacKey.a, [.shift]): return "A"
            case (MacKey.e, [.option]): return "é"
            case (MacKey.q, []), (MacKey.w, []): return "q"
            case (MacKey.s, []): return "\u{7F}"
            default: return nil
            }
        }
        t.expect(synthetic.stroke(for: "a") == KeyStroke(keyCode: MacKey.a, modifiers: []), "plain key")
        t.expect(synthetic.stroke(for: "A") == KeyStroke(keyCode: MacKey.a, modifiers: .shift), "shifted key")
        t.expect(synthetic.stroke(for: "é") == KeyStroke(keyCode: MacKey.e, modifiers: .option), "option key")
        t.expect(synthetic.stroke(for: "q")?.keyCode == MacKey.q, "lowest key code wins")
        t.expect(synthetic.stroke(for: "\u{7F}") == nil, "control characters excluded")

        guard let current = KeyboardLayoutMap.current() else { return t.fail("no current keyboard layout") }
        t.note("current layout: \(current.layoutName), \(current.count) characters, IME \(current.inputMethodActive)")
        t.expect(current.count >= 90, "current layout maps printable ASCII-ish set")
        let alphanumerics = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789 "
        let missing = alphanumerics.filter { current.stroke(for: $0) == nil }
        t.expect(missing.isEmpty, "letters, digits and space reachable (missing: \(String(missing).debugDescription))")
        t.expect(current.stroke(for: "1")?.keyCode == MacKey.digit1, "digits come from the top row, not the keypad")
    }

    private static func textPlanner(_ t: inout Checks) {
        t.group("TextPlanner")
        let layout = KeyboardLayoutMap(layoutName: "Test") { code, modifiers in
            switch (code, modifiers) {
            case (MacKey.h, []): return "h"
            case (MacKey.i, []): return "i"
            case (MacKey.s, []): return "s"
            case (MacKey.e, [.option]): return "é"
            default: return nil
            }
        }
        let hi = TextPlanner.plan("hi\n👋\té", layout: layout)
        t.expect(hi == [
            .key(KeyStroke(keyCode: MacKey.h, modifiers: []), text: "h"),
            .key(KeyStroke(keyCode: MacKey.i, modifiers: []), text: "i"),
            .key(KeyStroke(keyCode: MacKey.returnKey, modifiers: []), text: "\r"),
            .unicode("👋"),
            .key(KeyStroke(keyCode: MacKey.tab, modifiers: []), text: "\t"),
            .key(KeyStroke(keyCode: MacKey.e, modifiers: .option), text: "é"),
        ], "keys, newline, emoji, tab, option-letter")
        t.expect(TextPlanner.plan("a\r\nb", layout: nil).count == 3, "CRLF is one Return")
        t.expect(TextPlanner.plan("\u{1B}x", layout: nil) == [.unicode("x")], "control characters dropped")
        t.expect(TextPlanner.plan("S", layout: layout, modifiers: .command)
                    == [.key(KeyStroke(keyCode: MacKey.s, modifiers: []), text: "s")], "⌘+S falls back to s key")
        let ime = KeyboardLayoutMap(layoutName: "IME", inputMethodActive: true) { code, mods in
            code == MacKey.s && mods.isEmpty ? "s" : nil
        }
        t.expect(TextPlanner.plan("s", layout: ime) == [.unicode("s")], "IME active: plain text as Unicode")
        t.expect(TextPlanner.plan("s", layout: ime, modifiers: .command).first.map { if case .key = $0 { return true } else { return false } } ?? false,
                 "IME active: shortcuts still use keys")
    }

    private static func symbolicHotKeys(_ t: inout Checks) {
        t.group("SymbolicHotKeys")
        t.expect(SymbolicHotKeys.resolve(.spotlight, in: nil) == SymbolicHotKey.spotlight.defaultChord, "default when absent")
        let disabled: [String: Any] = ["64": ["enabled": false]]
        t.expect(SymbolicHotKeys.resolve(.spotlight, in: disabled) == nil, "disabled → nil")
        // ⌃→ as stored by System Settings: (ASCII 65535, key 124, ⌃ | fn | numpad).
        let custom: [String: Any] = ["81": ["enabled": true, "value": ["parameters": [65535, 124, 0x84_0000 | 0x80_0000], "type": "standard"]]]
        t.expect(SymbolicHotKeys.resolve(.nextSpace, in: custom) == KeyChord(keyCode: MacKey.rightArrow, modifiers: .control),
                 "arrow chord drops intrinsic fn")
        let cmdOptSpace: [String: Any] = ["64": ["enabled": 1, "value": ["parameters": [32, 49, 0x18_0000]]]]
        t.expect(SymbolicHotKeys.resolve(.spotlight, in: cmdOptSpace) == KeyChord(keyCode: MacKey.space, modifiers: [.command, .option]),
                 "custom ⌥⌘Space")
        let malformed: [String: Any] = ["64": ["enabled": true, "value": ["parameters": ["x"]]]]
        t.expect(SymbolicHotKeys.resolve(.spotlight, in: malformed) == SymbolicHotKey.spotlight.defaultChord, "malformed → default")
        t.note("this Mac: Spotlight \(describe(SymbolicHotKeys.current(.spotlight))), "
               + "next Space \(describe(SymbolicHotKeys.current(.nextSpace))), "
               + "Notification Center \(describe(SymbolicHotKeys.current(.notificationCenter)))")
    }

    private static func actionResolver(_ t: inout Checks) {
        t.group("SystemActionResolver")
        let all: (String) -> Bool = { _ in true }
        let none: (String) -> Bool = { _ in false }
        let mc = URL(fileURLWithPath: SystemActionResolver.missionControlApp)
        t.expect(SystemActionResolver.mechanism(for: .missionControl, fileExists: all) == .docklet(mc, argument: nil), "Mission Control docklet")
        t.expect(SystemActionResolver.mechanism(for: .appExpose, fileExists: all) == .docklet(mc, argument: "2"), "App Exposé = 2")
        t.expect(SystemActionResolver.mechanism(for: .showDesktop, fileExists: all) == .docklet(mc, argument: "1"), "Show Desktop = 1")
        t.expect(SystemActionResolver.mechanism(for: .missionControl, fileExists: none, hotKey: { _ in nil })
                    == .unavailable("This Mac has no shortcut for that."), "no docklet and no shortcut")
        t.expect(SystemActionResolver.mechanism(for: .missionControl, fileExists: none, hotKey: { $0.defaultChord })
                    == .chord(KeyChord(keyCode: MacKey.upArrow, modifiers: .control)), "falls back to ⌃↑")
        for action in SystemAction.allCases {
            let mechanism = SystemActionResolver.mechanism(for: action)
            if case .unavailable(let reason) = mechanism {
                t.note("on this Mac \(action.rawValue) is unavailable: \(reason)")
            } else {
                t.note("on this Mac \(action.rawValue) → \(mechanism)")
            }
        }
    }

    /// The injector posts pixel deltas unchanged and relies on the system to apply the user's
    /// scroll-direction preference to real *and* synthetic events alike (verified here).
    private static func scrollEventConversion(_ t: inout Checks) {
        t.group("Scroll events")
        guard let event = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: 10, wheel2: -4, wheel3: 0) else {
            return t.fail("couldn't create scroll event")
        }
        event.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
        event.setIntegerValueField(.scrollWheelEventScrollPhase, value: Int64(CGScrollPhase.began.rawValue))
        guard let nsEvent = NSEvent(cgEvent: event) else { return t.fail("couldn't convert scroll event") }
        t.expect(nsEvent.scrollingDeltaY == 10 && nsEvent.scrollingDeltaX == -4, "pixel deltas pass through")
        t.expect(nsEvent.hasPreciseScrollingDeltas, "precise (trackpad-like) deltas")
        t.expect(nsEvent.phase == .began, "phase began")
        t.expect(!nsEvent.isDirectionInvertedFromDevice, "synthetic events aren't flagged inverted")
    }

    private static func formatting(_ t: inout Checks) {
        t.group("Formatting")
        t.expect(Formatting.roundTrip(0.2) == "1 ms", "sub-ms rounds up")
        t.expect(Formatting.roundTrip(23.4) == "23 ms", "rounds")
        t.expect(Formatting.roundTrip(.nan) == "–", "NaN")
        t.expect(Formatting.link(route: .direct, roundTripMs: 41) == "Direct · 41 ms", "link")
        t.expect(Formatting.link(route: nil, roundTripMs: nil) == "Connecting", "link unknown")
        t.expect(Formatting.countdown(599.2) == "10:00", "countdown rounds up")
        t.expect(Formatting.countdown(61) == "1:01", "countdown")
        t.expect(Formatting.countdown(-5) == "0:00", "countdown floor")
        t.expect(Formatting.duration(30) == "Just now", "duration < 1 min")
        let now = Date()
        t.expect(Formatting.lastSeen(pairedAt: now.addingTimeInterval(-86_400 * 3), lastConnectedAt: now.addingTimeInterval(-10), now: now)
                    == "Last used just now", "last used just now")
        t.note("examples: \(Formatting.duration(125 * 60)) · \(Formatting.lastSeen(pairedAt: now.addingTimeInterval(-7200), lastConnectedAt: nil, now: now))")
    }

    private static func modelNames(_ t: inout Checks) {
        t.group("MacModel")
        t.expect(MacModel.family(fromProductName: "MacBook Pro (14-inch, M5)") == "MacBook Pro", "family from product name")
        t.expect(MacModel.family(fromProductName: "Mac mini") == "Mac mini", "no parenthetical")
        t.expect(MacModel.family(forIdentifier: "MacBookPro18,3") == "MacBook Pro", "legacy identifier")
        t.expect(MacModel.family(forIdentifier: "MacBookAir10,1") == "MacBook Air", "MacBookAir before MacBook")
        t.expect(MacModel.family(forIdentifier: "Mac99,9") == "Mac", "unknown → Mac")
        let current = MacModel.current
        t.note("this Mac: \(current.identifier) · \(current.productName ?? "no product name") · \(current.family)")
        let info = HostDescription.current()
        t.note("host info: \(info.name) · \(info.model) · \(info.osVersion) · app \(info.appVersion)")
        t.expect(!info.name.isEmpty && info.osVersion.hasPrefix("macOS "), "host info populated")
    }

    private static func qrCode(_ t: inout Checks) {
        t.group("QR code")
        let link = "reach://pair?v=1&h=0123456789abcdef0123456789abcdef&k=AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"
            + "&s=BBBBBBBBBBBBBBBBBBBBBB&n=Alex%E2%80%99s%20MacBook%20Pro"
        guard let image = QRCodeRenderer.image(for: link) else { return t.fail("QR generation failed") }
        t.expect(image.width == image.height && image.width >= 21, "square, \(image.width) modules incl. quiet zone")
        let side = QRTile.pixelExactSide(modules: image.width, target: 172, scale: 2)
        let pixelsPerModule = side * 2 / CGFloat(image.width)
        t.expect(side <= 172 && pixelsPerModule == pixelsPerModule.rounded(), "whole pixels per module (\(pixelsPerModule))")
    }

    private static func clipboardLimits(_ t: inout Checks) {
        t.group("Clipboard")
        let big = ClipboardContent(text: String(repeating: "x", count: 4_000_000))
        t.expect(ClipboardSync.fitsInMessage(big), "4 MB text fits")
        let tooBig = ClipboardContent(text: String(repeating: "x", count: 6_100_000))
        t.expect(!ClipboardSync.fitsInMessage(tooBig), "6.1 MB text exceeds the control-message budget")
        let png = ClipboardContent(imagePNG: Data(count: 4_600_000))
        t.expect(!ClipboardSync.fitsInMessage(png), "4.6 MB PNG exceeds after base64 (×4/3)")
        t.expect(ClipboardSync.fitsInMessage(ClipboardContent(imagePNG: Data(count: 4_400_000))), "4.4 MB PNG fits")
    }

    private static func appListBatching(_ t: inout Checks) {
        t.group("App list batching")
        let apps = (0..<30).map { AppInfo(pid: Int32($0), bundleID: "app.\($0)", name: "App \($0)", icon: Data(count: 12_000),
                                          isActive: false, isHidden: false) }
        let batches = AppListBatcher.batches(apps)
        t.expect(batches.count > 1, "30 × 12 kB icons split into \(batches.count) messages")
        t.expect(batches.allSatisfy { $0.map(\.pid) == apps.map(\.pid) }, "every message carries the full list")
        let iconsSent = batches.flatMap { $0.filter { $0.icon != nil }.map(\.pid) }
        t.expect(iconsSent.sorted() == apps.map(\.pid), "each icon sent exactly once")
        let fits = batches.allSatisfy { batch in
            ((try? WireCodec.encode(HostMessage.apps(batch)))?.count ?? .max) <= ClipboardSync.maxMessageBytes
        }
        t.expect(fits, "every message fits the control-message budget")
        t.expect(AppListBatcher.batches(Array(apps.prefix(3))).count == 1, "small list stays one message")
    }

    private static func turnServer(_ t: inout Checks) {
        t.group("TURN server")
        func urls(_ text: String) -> [String] {
            guard case .success(let server?) = TurnServer.parse(urls: text, username: "u", credential: "p") else { return [] }
            return server.urls
        }
        t.equal(urls("turn:relay.example.com:3478"), ["turn:relay.example.com:3478"], "host and port")
        t.equal(urls("TURNS:Relay.Example.com:443?Transport=TCP"), ["turns:relay.example.com:443?transport=tcp"],
                "canonical lower case (WebRTC rejects TURN:)")
        t.equal(urls("turn://relay.example.com"), ["turn:relay.example.com"], "stray // dropped (WebRTC rejects it)")
        t.equal(urls(" turn:relay.example.com?transport=udp,\nturns:relay.example.com:5349  turn:relay.example.com?transport=udp "),
                ["turn:relay.example.com?transport=udp", "turns:relay.example.com:5349"], "several, any separator, duplicates dropped")
        t.equal(urls("turn:[2001:DB8::1]:3478"), ["turn:[2001:db8::1]:3478"], "IPv6 literal")
        t.equal(urls("turn:203.0.113.5"), ["turn:203.0.113.5"], "IPv4, default port")
        // Not TURN, or forms WebRTC refuses (it then won't create a peer connection at all).
        for bad in ["stun:stun.example.com", "relay.example.com:3478", "turn:", "turn:relay.example.com:0",
                    "turn:relay.example.com:65536", "turn:relay.example.com:+80", "turn:relay.example.com:3478?transport=tls",
                    "turn:relay.example.com?foo=bar", "turn:user@relay.example.com", "turn:relay.example.com/path",
                    "turn:relayé.example.com", "turn:[2001:db8::1", "https://relay.example.com"] {
            t.expect(TurnURL(bad) == nil, "rejects \(bad)")
        }
        t.equal(TurnServer.parse(urls: "turn:a.example.com, stun:b.example.com", username: "u", credential: "p"),
                .failure(.invalidURL("stun:b.example.com")), "names the bad entry")
        t.equal(TurnServer.parse(urls: "turn:relay.example.com", username: " ", credential: "p"), .failure(.missingCredentials),
                "needs a username")
        t.equal(TurnServer.parse(urls: "turn:relay.example.com", username: "u", credential: ""), .failure(.missingCredentials),
                "needs a password")
        t.equal(TurnServer.parse(urls: "", username: "u", credential: ""), .failure(.missingURL), "credentials without an address")
        t.equal(TurnServer.parse(urls: " ", username: "", credential: "\n"), .success(nil), "all empty: no relay server")

        let server = TurnServer(urls: ["turn:relay.example.com:3478", "turns:relay.example.com:443?transport=tcp"],
                                username: "reach", credential: "s3cret-pass")
        let ice = TurnServer.iceServers(with: server)
        t.expect(ice.dropLast() == IceServerConfig.defaultSTUN[...], "public STUN first")
        t.expect(ice.last == IceServerConfig(urls: server.urls, username: "reach", credential: "s3cret-pass") && ice.last?.isRelay == true,
                 "then the relay, with its credentials")
        t.expect(TurnServer.iceServers(with: nil) == IceServerConfig.defaultSTUN && !IceServerConfig.defaultSTUN.contains { $0.isRelay },
                 "none set: STUN only, no relay")
        t.equal(server.displayHost, "relay.example.com", "shown as")

        // Persistence against scratch stores, not the real defaults and keychain. A suite named by an
        // absolute path keeps its plist in the scratch directory instead of ~/Library/Preferences.
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("reach.selftest.\(UUID().uuidString)",
                                                                                      isDirectory: true)
        let suite = directory.appendingPathComponent("defaults").path
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        guard let defaults = UserDefaults(suiteName: suite) else { return t.fail("scratch defaults unavailable") }
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
        let settings = AppSettings(defaults: defaults, secrets: FileSecretStore(directory: directory))
        t.expect(settings.turnServer == nil, "off by default")
        do {
            try settings.setTurnServer(server)
        } catch {
            return t.fail("save failed: \(error)")
        }
        t.expect(settings.turnServer == server, "round trip")
        let stored = defaults.persistentDomain(forName: suite).map { "\($0)" } ?? ""
        t.expect(!stored.contains("s3cret-pass"), "password kept out of defaults")
        let noPassword = AppSettings(defaults: defaults, secrets: FileSecretStore(directory: directory.appendingPathComponent("empty")))
        t.expect(noPassword.turnServer == nil, "password missing: off, not a server WebRTC would reject")
        try? settings.setTurnServer(nil)
        t.expect(settings.turnServer == nil, "removed")
    }

    /// The cursor shape is sampled on the main thread 25×/s; make sure that stays cheap.
    private static func cursorSamplingCost(_ t: inout Checks) {
        t.group("Cursor sampling")
        let iterations = 200
        let start = DispatchTime.now().uptimeNanoseconds
        var available = 0
        for _ in 0..<iterations {
            let system = NSCursor.currentSystem
            if system != nil { available += 1 }
            _ = CursorSample(cursor: system ?? NSCursor.arrow)
        }
        let perSample = Double(DispatchTime.now().uptimeNanoseconds - start) / Double(iterations) / 1000
        let cpuShare = perSample * 25 / 1_000_000 * 100
        t.note(String(format: "%.0f µs per sample → %.2f%% of one core at 25 Hz (currentSystem non-nil %d/%d)",
                      perSample, cpuShare, available, iterations))
        t.expect(CursorSample(cursor: NSCursor.arrow) != nil, "arrow fallback samples")
        t.expect(cpuShare < 1, "shape sampling under 1% CPU")
        let positionStart = DispatchTime.now().uptimeNanoseconds
        for _ in 0..<10_000 { _ = CGEvent(source: nil)?.location }
        let perPosition = Double(DispatchTime.now().uptimeNanoseconds - positionStart) / 10_000 / 1000
        t.note(String(format: "%.2f µs per position sample", perPosition))
        t.expect(perPosition * 120 / 1_000_000 * 100 < 0.5, "position sampling under 0.5% CPU at 120 Hz")
    }

    private static func describe(_ chord: KeyChord?) -> String {
        guard let chord else { return "off" }
        return "key \(chord.keyCode) mods \(chord.modifiers.rawValue)"
    }
}

/// A minimal check recorder.
private struct Checks {
    var passed = 0
    var failed = 0

    mutating func group(_ name: String) {
        print("\n[\(name)]")
    }

    mutating func expect(_ condition: Bool, _ label: String) {
        if condition {
            passed += 1
            print("  ✓ \(label)")
        } else {
            failed += 1
            print("  ✗ \(label)")
        }
    }

    mutating func fail(_ label: String) {
        expect(false, label)
    }

    mutating func equal(_ actual: (width: Int, height: Int), _ expected: (Int, Int), _ label: String) {
        expect(actual.width == expected.0 && actual.height == expected.1, "\(label): \(actual.width)×\(actual.height)")
    }

    mutating func equal<T: Equatable>(_ actual: T, _ expected: T, _ label: String) {
        expect(actual == expected, "\(label): \(actual)")
    }

    mutating func near(_ actual: CGPoint?, _ expected: CGPoint, _ label: String) {
        guard let actual else { return fail("\(label): nil") }
        expect(abs(actual.x - expected.x) < 1e-6 && abs(actual.y - expected.y) < 1e-6, "\(label): \(actual)")
    }

    func note(_ text: String) {
        print("  · \(text)")
    }
}
