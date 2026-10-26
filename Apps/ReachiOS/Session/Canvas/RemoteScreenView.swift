import UIKit
import ReachProtocol

/// The session canvas: a `CAMetalLayer`-backed view that receives raw touches, hardware keys and the
/// keyboard, and keeps the renderer's scene (viewport, cursor, minimap, dimming) up to date.
@MainActor
final class RemoteScreenView: UIView, GestureEngineDelegate {
    override class var layerClass: AnyClass { CAMetalLayer.self }
    private var metalLayer: CAMetalLayer { layer as! CAMetalLayer }

    let controller: SessionController
    let viewportController = ViewportController()
    private(set) lazy var gestures = GestureEngine(viewport: viewportController, cursor: controller.cursor, input: controller.input)

    private let keyboardView = KeyboardInputView(frame: CGRect(x: 0, y: 0, width: 1, height: 1))
    private let feedbackLayer = CALayer()
    private let minimapAlpha = ValueAnimator(0)
    private let dimAmount = ValueAnimator(0)
    private var minimapHideWork: DispatchWorkItem?
    private var buttonHeld = false
    private var keyboardOverlap: CGFloat = 0
    private var appliedInitialZoom = false
    private var lastPublished: Viewport?

    /// Height of the SwiftUI accessory bar that sits on top of the keyboard.
    var accessoryBarHeight: CGFloat = 60 {
        didSet { if accessoryBarHeight != oldValue { updateInsets(duration: 0.2) } }
    }

    init(controller: SessionController) {
        self.controller = controller
        super.init(frame: .zero)
        backgroundColor = .black
        isMultipleTouchEnabled = true
        isOpaque = true
        layer.addSublayer(feedbackLayer)
        addSubview(keyboardView)
        configureAccessibility()

        controller.renderer?.attach(metalLayer)
        controller.canvas = self
        gestures.delegate = self
        gestures.config.mode = controller.inputMode

        viewportController.onChange = { [weak self] v in self?.viewportChanged(v) }
        minimapAlpha.onUpdate = { [weak self] _ in self?.pushScene() }
        dimAmount.onUpdate = { [weak self] _ in self?.pushScene() }

        // Cursor updates may come from the network thread: go straight to the (thread-safe) renderer.
        let renderer = controller.renderer
        controller.cursor.onChange = { snap in
            renderer?.update { s in
                s.cursor?.position = snap.position
                s.cursor?.visible = snap.visible && !snap.offDisplay
                if s.minimap != nil { s.minimap?.cursor = snap.offDisplay ? nil : snap.position }
            }
        }
        controller.cursor.onHostMove = { [weak self] p in
            DispatchQueue.main.async { self?.hostMovedCursor(to: p) }
        }

        keyboardView.onText = { [weak controller] text in controller?.input.text(text) }
        keyboardView.onDelete = { [weak controller] in controller?.input.keyPress(MacKey.delete) }
        keyboardView.onReturn = { [weak controller] in controller?.input.keyPress(MacKey.returnKey) }
        keyboardView.onPress = { [weak self] press, down in self?.handlePress(press, down: down) ?? false }

        let nc = NotificationCenter.default
        nc.addObserver(self, selector: #selector(keyboardWillChangeFrame(_:)), name: UIResponder.keyboardWillChangeFrameNotification, object: nil)
        nc.addObserver(self, selector: #selector(keyboardWillHide(_:)), name: UIResponder.keyboardWillHideNotification, object: nil)

        let hover = UIHoverGestureRecognizer(target: self, action: #selector(hovered(_:)))
        addGestureRecognizer(hover)
        let scroll = UIPanGestureRecognizer(target: self, action: #selector(scrolled(_:)))
        scroll.allowedScrollTypesMask = .all
        scroll.allowedTouchTypes = []
        addGestureRecognizer(scroll)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func configureAccessibility() {
        isAccessibilityElement = true
        accessibilityLabel = "Screen of \(controller.host.name)"
        accessibilityHint = "Touches control your Mac directly."
        accessibilityTraits = [.allowsDirectInteraction]
    }

    // MARK: Layout

    override func layoutSubviews() {
        super.layoutSubviews()
        let scale = window?.screen.scale ?? traitCollection.displayScale
        metalLayer.contentsScale = scale
        metalLayer.drawableSize = CGSize(width: bounds.width * scale, height: bounds.height * scale)
        feedbackLayer.frame = bounds
        viewportController.setContentSize(controller.contentSize)
        viewportController.setBounds(bounds.size)
        if !appliedInitialZoom, bounds.width > 0 {
            appliedInitialZoom = true
            if let z = LaunchOptions.initialZoom { viewportController.setZoomRelativeToFit(CGFloat(z)) }
        }
        pushScene()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil {
            DispatchQueue.main.async { [weak self] in self?.reclaimFirstResponder() }
        } else {
            viewportController.invalidate()
            minimapAlpha.invalidate()
            dimAmount.invalidate()
        }
    }

    /// Hardware keys reach us when we're first responder (unless the soft keyboard's view is).
    override var canBecomeFirstResponder: Bool { true }
    override var editingInteractionConfiguration: UIEditingInteractionConfiguration { .none }

    func reclaimFirstResponder() {
        guard window != nil else { return }
        if controller.keyboardVisible {
            if !keyboardView.isFirstResponder { keyboardView.becomeFirstResponder() }
        } else if !isFirstResponder {
            becomeFirstResponder()
        }
    }

    // MARK: Commands from the controller / SwiftUI

    func apply(config: GestureEngine.Config, dimmed: Bool, accessoryHeight: CGFloat) {
        if gestures.config != config { gestures.config = config }
        dimAmount.animate(to: dimmed ? 1 : 0, duration: 0.35)
        accessoryBarHeight = accessoryHeight
    }

    func inputModeChanged() {
        gestures.config.mode = controller.inputMode
    }

    func contentSizeDidChange() {
        viewportController.setContentSize(controller.contentSize)
    }

    func displayDidChange() {
        viewportController.fit(animated: false)
    }

    func zoom(toContentRect rect: CGRect) {
        viewportController.zoom(toContentRect: rect)
    }

    func fitToScreen() {
        viewportController.fit(animated: true)
    }

    func setKeyboardVisible(_ visible: Bool) {
        if visible {
            keyboardView.becomeFirstResponder()
        } else {
            if keyboardView.isFirstResponder { keyboardView.resignFirstResponder() }
            becomeFirstResponder()
        }
    }

    // MARK: Scene

    private func viewportChanged(_ v: Viewport) {
        defer { lastPublished = v }
        let scale = metalLayer.contentsScale
        controller.viewportDidChange(displayedPixels: CGSize(width: v.contentFrame.width * scale,
                                                             height: v.contentFrame.height * scale))
        if let last = lastPublished, v.isZoomedIn, last.offset != v.offset || last.zoom != v.zoom {
            showMinimapBriefly()
        } else if !v.isZoomedIn, minimapAlpha.target > 0 {
            minimapAlpha.animate(to: 0, duration: 0.2)
        }
        pushScene()
    }

    private func showMinimapBriefly() {
        minimapHideWork?.cancel()
        if minimapAlpha.target < 1 { minimapAlpha.animate(to: 1, duration: 0.16) }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            if self.viewportController.isMoving { self.showMinimapBriefly(); return }
            self.minimapAlpha.animate(to: 0, duration: 0.4)
        }
        minimapHideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.1, execute: work)
    }

    private func pushScene() {
        guard let renderer = controller.renderer, bounds.width > 0 else { return }
        let v = viewportController.viewport
        let snap = controller.cursor.snapshot
        let scale = metalLayer.contentsScale
        let size = bounds.size
        let held = buttonHeld
        let alpha = Float(minimapAlpha.value)
        let dim = Float(dimAmount.value)
        let minimap: RemoteRenderer.MinimapDraw? = alpha > 0.01 && v.isZoomedIn
            ? RemoteRenderer.MinimapDraw(frame: minimapFrame(for: v), visible: v.visibleNormalizedRect,
                                         cursor: snap.offDisplay ? nil : snap.position, alpha: alpha)
            : nil
        // Scale the cursor with the zoom, but clamp it so it stays findable when zoomed out and doesn't
        // become a blob when zoomed in.
        let cursorScale = min(max(v.zoom, 0.62), 1.5)
        renderer.update { s in
            s.viewSize = size
            s.scale = scale
            s.contentFrame = v.contentFrame
            s.cursor = RemoteRenderer.CursorDraw(position: snap.position, scale: cursorScale, held: held,
                                                 visible: snap.visible && !snap.offDisplay)
            s.minimap = minimap
            s.dim = dim
        }
    }

    /// Top-trailing, inside the safe area, sized to the display's aspect ratio.
    private func minimapFrame(for v: Viewport) -> CGRect {
        let landscape = bounds.width > bounds.height
        let width: CGFloat = min(landscape ? 150 : 124, bounds.width * 0.34)
        let aspect = v.contentSize.height / max(v.contentSize.width, 1)
        let height = width * aspect
        let x = bounds.width - safeAreaInsets.right - 14 - width
        let y = max(safeAreaInsets.top, 12) + (landscape ? 4 : 8)
        return CGRect(x: x, y: y, width: width, height: height)
    }

    private func hostMovedCursor(to p: CGPoint) {
        guard controller.inputMode == .trackpad, !controller.input.isButtonHeld else { return }
        viewportController.ensureVisible(viewportController.viewport.viewPoint(forNormalized: p))
    }

    // MARK: Touches

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        gestures.touchesBegan(touches, in: self, event: event)
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        gestures.touchesMoved(touches, in: self, event: event)
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        gestures.touchesEnded(touches, in: self, event: event, cancelled: false)
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        gestures.touchesEnded(touches, in: self, event: event, cancelled: true)
    }

    @objc private func hovered(_ g: UIHoverGestureRecognizer) {
        guard g.state == .began || g.state == .changed else { return }
        gestures.hover(at: g.location(in: self))
    }

    private var lastScrollTranslation = CGPoint.zero

    @objc private func scrolled(_ g: UIPanGestureRecognizer) {
        let t = g.translation(in: self)
        if g.state == .began { lastScrollTranslation = .zero }
        let delta = t - lastScrollTranslation
        lastScrollTranslation = t
        gestures.indirectScroll(translationDelta: delta, phase: g.state, velocity: g.velocity(in: self))
    }

    // MARK: Hardware keyboard

    private func handlePress(_ press: UIPress, down: Bool) -> Bool {
        guard let key = HardwareKeys.macKey(for: press) else { return false }
        controller.input.key(key.code, down: down, modifiers: key.modifiers)
        return true
    }

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        let unhandled = presses.filter { !handlePress($0, down: true) }
        if !unhandled.isEmpty { super.pressesBegan(unhandled, with: event) }
    }

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        let unhandled = presses.filter { !handlePress($0, down: false) }
        if !unhandled.isEmpty { super.pressesEnded(unhandled, with: event) }
    }

    override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        let unhandled = presses.filter { !handlePress($0, down: false) }
        if !unhandled.isEmpty { super.pressesCancelled(unhandled, with: event) }
    }

    // MARK: Soft keyboard

    @objc private func keyboardWillChangeFrame(_ n: Notification) {
        guard let window, let end = (n.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue)?.cgRectValue else { return }
        let frame = convert(end, from: window.screen.coordinateSpace)
        let overlap = frame.intersects(bounds) ? max(0, bounds.maxY - frame.minY) : 0
        keyboardOverlap = overlap
        let duration = n.userInfo?[UIResponder.keyboardAnimationDurationUserInfoKey] as? Double ?? 0.25
        updateInsets(duration: duration)
    }

    @objc private func keyboardWillHide(_ n: Notification) {
        keyboardOverlap = 0
        updateInsets(duration: n.userInfo?[UIResponder.keyboardAnimationDurationUserInfoKey] as? Double ?? 0.25)
        // Dismissed by the system (e.g. iPad keyboard key) rather than from our UI.
        if controller.keyboardVisible, !keyboardView.isFirstResponder { controller.keyboardVisible = false }
    }

    private func updateInsets(duration: TimeInterval) {
        let bottom = keyboardOverlap > 0 ? keyboardOverlap + accessoryBarHeight : 0
        viewportController.setInsets(UIEdgeInsets(top: 0, left: 0, bottom: bottom, right: 0), duration: duration,
                                     keeping: controller.cursor.position)
    }

    // MARK: GestureEngineDelegate

    func gestureDidBegin(_ engine: GestureEngine) {
        controller.dismissTransientUI()
    }

    func gesture(_ engine: GestureEngine, buttonHeld held: Bool) {
        buttonHeld = held
        pushScene()
    }

    func gesture(_ engine: GestureEngine, feedback: GestureFeedback, at p: CGPoint) {
        switch feedback {
        case .click:
            Haptics.shared.play(.click)
            ripple(at: p, color: .white, size: 34)
        case .doubleClick:
            Haptics.shared.play(.click)
            ripple(at: p, color: .white, size: 34)
            ripple(at: p, color: .white, size: 52, delay: 0.05)
        case .rightClick:
            Haptics.shared.play(.rightClick)
            ripple(at: p, color: UIColor(red: 0.302, green: 0.584, blue: 1, alpha: 1), size: 44)
        case .dragStart, .longPressArmed:
            Haptics.shared.play(.dragStart)
            ripple(at: p, color: UIColor(red: 0.302, green: 0.584, blue: 1, alpha: 1), size: 56, expand: false)
        case .dragEnd:
            Haptics.shared.play(.dragEnd)
        case .zoomToggle:
            Haptics.shared.play(.detent)
        }
    }

    func gesture(_ engine: GestureEngine, zoomToWindowAt p: CGPoint) {
        let content = viewportController.viewport.contentPoint(forView: p)
        if let window = controller.window(at: content), let rect = controller.contentRect(for: window) {
            Haptics.shared.play(.dragStart)
            viewportController.zoom(toContentRect: rect)
        } else {
            Haptics.shared.play(.detent)
            controller.requestWindows(force: true)
        }
    }

    func gesture(_ engine: GestureEngine, performed action: SystemAction) {
        Haptics.shared.play(.gesture)
        controller.showToast(symbol: action.symbol, action.title)
    }

    // MARK: Click feedback

    /// A subtle ripple where the click landed — confirmation without waiting for the Mac to react.
    private func ripple(at p: CGPoint, color: UIColor, size: CGFloat, delay: CFTimeInterval = 0, expand: Bool = true) {
        let ring = CAShapeLayer()
        ring.path = UIBezierPath(ovalIn: CGRect(x: -size / 2, y: -size / 2, width: size, height: size)).cgPath
        ring.position = p
        ring.fillColor = color.withAlphaComponent(0.18).cgColor
        ring.strokeColor = color.withAlphaComponent(0.85).cgColor
        ring.lineWidth = 1.5
        ring.opacity = 0
        feedbackLayer.addSublayer(ring)

        let reduce = UIAccessibility.isReduceMotionEnabled
        let scale = CABasicAnimation(keyPath: "transform.scale")
        scale.fromValue = reduce || !expand ? 1 : 0.35
        scale.toValue = expand ? 1 : 0.6
        let fade = CAKeyframeAnimation(keyPath: "opacity")
        fade.values = [0.95, 0.8, 0]
        fade.keyTimes = [0, 0.35, 1]
        let group = CAAnimationGroup()
        group.animations = [scale, fade]
        group.duration = expand ? 0.34 : 0.42
        group.beginTime = CACurrentMediaTime() + delay
        group.timingFunction = CAMediaTimingFunction(name: .easeOut)
        group.isRemovedOnCompletion = true
        CATransaction.begin()
        CATransaction.setCompletionBlock { ring.removeFromSuperlayer() }
        ring.add(group, forKey: "ripple")
        CATransaction.commit()
    }
}

extension SystemAction {
    var title: String {
        switch self {
        case .missionControl: return "Mission Control"
        case .appExpose: return "App Exposé"
        case .showDesktop: return "Show Desktop"
        case .launchpad: return "Launchpad"
        case .spotlight: return "Spotlight"
        case .notificationCenter: return "Notification Center"
        case .previousSpace: return "Previous Space"
        case .nextSpace: return "Next Space"
        case .appSwitcher: return "App Switcher"
        case .lockScreen: return "Lock Screen"
        case .screenshot: return "Screenshot"
        case .forceQuit: return "Force Quit"
        case .wakeDisplay: return "Wake Display"
        }
    }

    var symbol: String {
        switch self {
        case .missionControl: return "rectangle.3.group"
        case .appExpose: return "rectangle.stack"
        case .showDesktop: return "menubar.dock.rectangle"
        case .launchpad: return "square.grid.3x3"
        case .spotlight: return "magnifyingglass"
        case .notificationCenter: return "bell.badge"
        case .previousSpace: return "rectangle.lefthalf.inset.filled.arrow.left"
        case .nextSpace: return "rectangle.righthalf.inset.filled.arrow.right"
        case .appSwitcher: return "command"
        case .lockScreen: return "lock"
        case .screenshot: return "camera.viewfinder"
        case .forceQuit: return "xmark.octagon"
        case .wakeDisplay: return "sun.max"
        }
    }
}
