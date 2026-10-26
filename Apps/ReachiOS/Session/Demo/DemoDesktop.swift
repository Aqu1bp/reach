import UIKit

/// A small, interactive, macOS-looking desktop drawn with CoreGraphics: menu bar, dock, and a few
/// windows (Notes, Finder, Terminal) that can be raised, dragged, scrolled and typed into. Confined to
/// the demo host's queue.
final class DemoDesktop {
    enum Kind { case notes, finder, terminal, safari }

    struct Window {
        var id: UInt32
        var pid: Int32
        var app: String
        var title: String
        var frame: CGRect
        var kind: Kind
        var display: UInt32
    }

    struct App {
        var pid: Int32
        var name: String
        var bundleID: String
        var symbol: String
        var colors: (UIColor, UIColor)
    }

    struct Display {
        var id: UInt32
        var name: String
        /// Global points.
        var frame: CGRect
        var scale: CGFloat
    }

    let displays: [Display] = [
        Display(id: 1, name: "Built-in Retina Display", frame: CGRect(x: 0, y: 0, width: 1512, height: 982), scale: 2),
        Display(id: 2, name: "Studio Display", frame: CGRect(x: 1512, y: -240, width: 2560, height: 1440), scale: 1),
    ]

    let apps: [App] = [
        App(pid: 101, name: "Finder", bundleID: "com.apple.finder", symbol: "face.smiling", colors: (UIColor(red: 0.36, green: 0.72, blue: 1, alpha: 1), UIColor(red: 0.1, green: 0.42, blue: 0.95, alpha: 1))),
        App(pid: 102, name: "Safari", bundleID: "com.apple.Safari", symbol: "safari", colors: (UIColor(red: 0.35, green: 0.8, blue: 1, alpha: 1), UIColor(red: 0.05, green: 0.45, blue: 0.95, alpha: 1))),
        App(pid: 103, name: "Notes", bundleID: "com.apple.Notes", symbol: "note.text", colors: (UIColor(red: 1, green: 0.88, blue: 0.4, alpha: 1), UIColor(red: 0.98, green: 0.72, blue: 0.1, alpha: 1))),
        App(pid: 104, name: "Terminal", bundleID: "com.apple.Terminal", symbol: "apple.terminal", colors: (UIColor(white: 0.32, alpha: 1), UIColor(white: 0.1, alpha: 1))),
        App(pid: 105, name: "Messages", bundleID: "com.apple.MobileSMS", symbol: "message.fill", colors: (UIColor(red: 0.45, green: 0.95, blue: 0.45, alpha: 1), UIColor(red: 0.1, green: 0.75, blue: 0.25, alpha: 1))),
        App(pid: 106, name: "Mail", bundleID: "com.apple.mail", symbol: "envelope.fill", colors: (UIColor(red: 0.4, green: 0.75, blue: 1, alpha: 1), UIColor(red: 0.1, green: 0.5, blue: 1, alpha: 1))),
        App(pid: 107, name: "Xcode", bundleID: "com.apple.dt.Xcode", symbol: "hammer.fill", colors: (UIColor(red: 0.3, green: 0.6, blue: 1, alpha: 1), UIColor(red: 0.1, green: 0.25, blue: 0.75, alpha: 1))),
        App(pid: 108, name: "Music", bundleID: "com.apple.Music", symbol: "music.note", colors: (UIColor(red: 1, green: 0.4, blue: 0.5, alpha: 1), UIColor(red: 0.95, green: 0.15, blue: 0.3, alpha: 1))),
        App(pid: 109, name: "System Settings", bundleID: "com.apple.systempreferences", symbol: "gearshape.fill", colors: (UIColor(white: 0.62, alpha: 1), UIColor(white: 0.38, alpha: 1))),
    ]

    /// Front to back.
    private(set) var windows: [Window] = [
        Window(id: 11, pid: 103, app: "Notes", title: "Ideas for Reach", frame: CGRect(x: 360, y: 92, width: 760, height: 520), kind: .notes, display: 1),
        Window(id: 12, pid: 104, app: "Terminal", title: "alex — zsh — 80×24", frame: CGRect(x: 830, y: 430, width: 610, height: 360), kind: .terminal, display: 1),
        Window(id: 13, pid: 101, app: "Finder", title: "Documents", frame: CGRect(x: 70, y: 300, width: 640, height: 420), kind: .finder, display: 1),
        Window(id: 14, pid: 102, app: "Safari", title: "Apple", frame: CGRect(x: 1712, y: -120, width: 1500, height: 980), kind: .safari, display: 2),
    ]

    var activeDisplayID: UInt32 = 1
    var frontApp = "Notes"
    var notesText = """
    Reach — notes

    Control the Mac from the phone, from anywhere. The phone gets its own way to drive the Mac instead of a tiny mirror of a big screen.

    • Trackpad mode: the phone is a precision trackpad. Tap to click, two fingers to scroll, pinch to zoom around the cursor.
    • Touch mode: tap exactly where you want. Drag to scroll like any iPhone app.
    • Three-finger swipes for Mission Control and Spaces.
    • Long-press and drag to move windows around.

    Latency: the cursor is drawn on the phone and predicted locally, so it moves the instant your finger does. Pan and zoom are pure GPU transforms — no round trip.

    Try typing here — every keystroke goes straight to the Mac. Use the compose sheet for long text with autocorrect and dictation.

    Scroll down for more…

    Ideas
    – Zoom to window from the window list
    – Minimap while panning
    – Paste to Mac without the paste prompt
    – Hardware keyboards pass through
    – Sticky modifiers: tap ⌘ once for the next key, twice to lock

    The end.
    """ {
        // Typing jumps to the caret, like a real editor.
        didSet { followCaret = true }
    }
    var notesScroll: CGFloat = 0
    private var followCaret = false
    /// Measured on each draw so scrolling stops at the end of the note.
    private var notesMaxScroll: CGFloat = 900
    var hud: (symbol: String, text: String, until: Date)?
    var contextMenu: (point: CGPoint, until: Date)?
    var selectedFinderItem: Int?

    // MARK: Geometry

    var activeDisplay: Display { displays.first { $0.id == activeDisplayID } ?? displays[0] }

    /// Local (display) frame of a window on the active display.
    func localFrame(_ w: Window) -> CGRect {
        w.frame.offsetBy(dx: -activeDisplay.frame.minX, dy: -activeDisplay.frame.minY)
    }

    func windowIndex(at local: CGPoint) -> Int? {
        windows.indices.first { windows[$0].display == activeDisplayID && localFrame(windows[$0]).contains(local) }
    }

    func titleBarContains(_ index: Int, _ local: CGPoint) -> Bool {
        let f = localFrame(windows[index])
        return CGRect(x: f.minX, y: f.minY, width: f.width, height: 30).contains(local)
    }

    func notesEditorRect(_ w: Window) -> CGRect {
        let f = localFrame(w)
        return CGRect(x: f.minX + 210, y: f.minY + 30, width: f.width - 210, height: f.height - 30)
    }

    func isOverText(_ local: CGPoint) -> Bool {
        guard let i = windowIndex(at: local), windows[i].kind == .notes else { return false }
        return notesEditorRect(windows[i]).contains(local)
    }

    func raise(_ index: Int) {
        let w = windows.remove(at: index)
        windows.insert(w, at: 0)
        frontApp = w.app
    }

    func raise(pid: Int32) -> Bool {
        if let i = windows.firstIndex(where: { $0.pid == pid }) {
            raise(i)
            return true
        }
        frontApp = apps.first { $0.pid == pid }?.name ?? frontApp
        return false
    }

    func raise(windowID: UInt32) {
        if let i = windows.firstIndex(where: { $0.id == windowID }) {
            if windows[i].display != activeDisplayID { activeDisplayID = windows[i].display }
            raise(i)
        }
    }

    func move(windowAt index: Int, to origin: CGPoint) {
        windows[index].frame.origin = CGPoint(x: origin.x + activeDisplay.frame.minX, y: max(origin.y, 25) + activeDisplay.frame.minY)
    }

    func scrollNotes(by dy: CGFloat) {
        notesScroll = min(max(notesScroll - dy, 0), notesMaxScroll)
    }

    func dockIconIndex(at local: CGPoint) -> Int? {
        let layout = dockLayout(for: activeDisplay.frame.size)
        return layout.icons.firstIndex { $0.contains(local) }
    }

    func showHUD(_ symbol: String, _ text: String) {
        hud = (symbol, text, Date().addingTimeInterval(1.4))
    }

    // MARK: Drawing

    private var wallpaperCache: [UInt32: UIImage] = [:]
    private var iconCache: [String: UIImage] = [:]

    func draw(in ctx: CGContext, size: CGSize, scale: CGFloat) {
        UIGraphicsPushContext(ctx)
        defer { UIGraphicsPopContext() }
        let now = Date()
        wallpaper(size: size, scale: scale).draw(in: CGRect(origin: .zero, size: size))

        for w in windows.reversed() where w.display == activeDisplayID {
            drawWindow(w, in: ctx)
        }
        drawDock(size: size, in: ctx)
        drawMenuBar(size: size, in: ctx, now: now)
        if let menu = contextMenu, menu.until > now { drawContextMenu(at: menu.point, in: ctx) }
        if let hud, hud.until > now { drawHUD(hud.symbol, hud.text, size: size, in: ctx) }
    }

    var needsTimedRedraw: Bool {
        let now = Date()
        return (hud.map { $0.until > now.addingTimeInterval(-0.2) } ?? false)
    }

    private func wallpaper(size: CGSize, scale: CGFloat) -> UIImage {
        if let cached = wallpaperCache[activeDisplayID] { return cached }
        let format = UIGraphicsImageRendererFormat()
        format.scale = scale
        format.opaque = true
        let image = UIGraphicsImageRenderer(size: size, format: format).image { c in
            let cg = c.cgContext
            let colors = [UIColor(red: 0.07, green: 0.12, blue: 0.32, alpha: 1).cgColor,
                          UIColor(red: 0.26, green: 0.18, blue: 0.52, alpha: 1).cgColor,
                          UIColor(red: 0.85, green: 0.42, blue: 0.48, alpha: 1).cgColor] as CFArray
            let g = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors, locations: [0, 0.55, 1])!
            cg.drawLinearGradient(g, start: .zero, end: CGPoint(x: size.width * 0.6, y: size.height), options: [])
            func blob(_ center: CGPoint, _ r: CGFloat, _ color: UIColor) {
                let gg = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                                    colors: [color.cgColor, color.withAlphaComponent(0).cgColor] as CFArray, locations: [0, 1])!
                cg.drawRadialGradient(gg, startCenter: center, startRadius: 0, endCenter: center, endRadius: r, options: [])
            }
            blob(CGPoint(x: size.width * 0.82, y: size.height * 0.2), size.width * 0.45, UIColor(red: 0.2, green: 0.55, blue: 1, alpha: 0.55))
            blob(CGPoint(x: size.width * 0.15, y: size.height * 0.85), size.width * 0.4, UIColor(red: 1, green: 0.55, blue: 0.35, alpha: 0.45))
            blob(CGPoint(x: size.width * 0.45, y: size.height * 0.45), size.width * 0.3, UIColor(red: 0.55, green: 0.3, blue: 0.95, alpha: 0.35))
        }
        wallpaperCache[activeDisplayID] = image
        return image
    }

    private func drawMenuBar(size: CGSize, in ctx: CGContext, now: Date) {
        let bar = CGRect(x: 0, y: 0, width: size.width, height: 25)
        UIColor(white: 1, alpha: 0.72).setFill()
        UIBezierPath(rect: bar).fill()
        var x: CGFloat = 18
        if let apple = symbol("apple.logo", size: 15, weight: .medium) {
            apple.withTintColor(.black).draw(at: CGPoint(x: x, y: 4))
            x += 34
        }
        x += text(frontApp, at: CGPoint(x: x, y: 4), size: 13.5, weight: .bold).width + 20
        for item in ["File", "Edit", "View", "Window", "Help"] {
            x += text(item, at: CGPoint(x: x, y: 4), size: 13.5, weight: .regular).width + 20
        }
        let clock = DateFormatter.localizedString(from: now, dateStyle: .none, timeStyle: .short)
        let day = now.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated))
        let right = "\(day)  \(clock)"
        let w = measure(right, size: 13.5, weight: .regular).width
        text(right, at: CGPoint(x: size.width - w - 16, y: 4), size: 13.5, weight: .regular)
        var rx = size.width - w - 40
        for s in ["switch.2", "wifi", "battery.75percent"] {
            if let img = symbol(s, size: 14, weight: .regular) {
                rx -= img.size.width + 14
                img.withTintColor(.black).draw(at: CGPoint(x: rx, y: 12.5 - img.size.height / 2))
            }
        }
    }

    private struct DockLayout {
        var frame: CGRect
        var icons: [CGRect]
    }

    private func dockLayout(for size: CGSize) -> DockLayout {
        let icon: CGFloat = 52, gap: CGFloat = 8, pad: CGFloat = 8
        let width = CGFloat(apps.count) * icon + CGFloat(apps.count - 1) * gap + pad * 2
        let frame = CGRect(x: (size.width - width) / 2, y: size.height - icon - pad * 2 - 6, width: width, height: icon + pad * 2)
        let icons = apps.indices.map { i in
            CGRect(x: frame.minX + pad + CGFloat(i) * (icon + gap), y: frame.minY + pad, width: icon, height: icon)
        }
        return DockLayout(frame: frame, icons: icons)
    }

    private func drawDock(size: CGSize, in ctx: CGContext) {
        let layout = dockLayout(for: size)
        let path = UIBezierPath(roundedRect: layout.frame, cornerRadius: 20)
        UIColor(white: 1, alpha: 0.28).setFill()
        path.fill()
        UIColor(white: 1, alpha: 0.45).setStroke()
        path.lineWidth = 0.75
        path.stroke()
        let running = Set(windows.map(\.app))
        for (i, app) in apps.enumerated() {
            let r = layout.icons[i]
            appIcon(app, size: r.width).draw(in: r)
            if running.contains(app.name) {
                UIColor(white: 0.1, alpha: 0.8).setFill()
                UIBezierPath(ovalIn: CGRect(x: r.midX - 2, y: r.maxY + 3, width: 4, height: 4)).fill()
            }
        }
    }

    func appIcon(_ app: App, size: CGFloat) -> UIImage {
        let key = "\(app.name)-\(size)"
        if let cached = iconCache[key] { return cached }
        let format = UIGraphicsImageRendererFormat()
        format.scale = 2
        let img = UIGraphicsImageRenderer(size: CGSize(width: size, height: size), format: format).image { c in
            let rect = CGRect(x: 0, y: 0, width: size, height: size).insetBy(dx: size * 0.04, dy: size * 0.04)
            let path = UIBezierPath(roundedRect: rect, cornerRadius: rect.width * 0.225)
            c.cgContext.saveGState()
            path.addClip()
            let g = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                               colors: [app.colors.0.cgColor, app.colors.1.cgColor] as CFArray, locations: [0, 1])!
            c.cgContext.drawLinearGradient(g, start: CGPoint(x: 0, y: rect.minY), end: CGPoint(x: 0, y: rect.maxY), options: [])
            c.cgContext.restoreGState()
            let config = UIImage.SymbolConfiguration(pointSize: size * 0.46, weight: .semibold)
            if let s = UIImage(systemName: app.symbol, withConfiguration: config)?.withTintColor(.white, renderingMode: .alwaysOriginal) {
                s.draw(at: CGPoint(x: rect.midX - s.size.width / 2, y: rect.midY - s.size.height / 2))
            }
        }
        iconCache[key] = img
        return img
    }

    private func drawWindow(_ w: Window, in ctx: CGContext) {
        let f = localFrame(w)
        let isFront = windows.first(where: { $0.display == activeDisplayID })?.id == w.id
        let shape = UIBezierPath(roundedRect: f, cornerRadius: 11)
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: 14), blur: isFront ? 40 : 24,
                      color: UIColor.black.withAlphaComponent(isFront ? 0.45 : 0.3).cgColor)
        (w.kind == .terminal ? UIColor(white: 0.12, alpha: 1) : UIColor.white).setFill()
        shape.fill()
        ctx.restoreGState()

        ctx.saveGState()
        shape.addClip()
        switch w.kind {
        case .notes: drawNotes(w, frame: f, ctx: ctx)
        case .finder: drawFinder(frame: f, ctx: ctx)
        case .terminal: drawTerminal(frame: f)
        case .safari: drawSafari(frame: f)
        }
        // Title bar
        let bar = CGRect(x: f.minX, y: f.minY, width: f.width, height: 30)
        let barColor = w.kind == .terminal ? UIColor(white: 0.2, alpha: 1) : UIColor(white: 0.955, alpha: 1)
        barColor.setFill()
        UIBezierPath(rect: bar).fill()
        let lights: [UIColor] = isFront
            ? [UIColor(red: 1, green: 0.37, blue: 0.34, alpha: 1), UIColor(red: 1, green: 0.74, blue: 0.18, alpha: 1), UIColor(red: 0.16, green: 0.79, blue: 0.25, alpha: 1)]
            : [UIColor(white: 0.78, alpha: 1), UIColor(white: 0.78, alpha: 1), UIColor(white: 0.78, alpha: 1)]
        for (i, c) in lights.enumerated() {
            c.setFill()
            UIBezierPath(ovalIn: CGRect(x: f.minX + 13 + CGFloat(i) * 20, y: f.minY + 9, width: 12, height: 12)).fill()
        }
        let titleColor = w.kind == .terminal ? UIColor(white: 0.8, alpha: 1) : UIColor(white: 0.25, alpha: 1)
        let tw = measure(w.title, size: 13, weight: .semibold).width
        text(w.title, at: CGPoint(x: f.midX - tw / 2, y: f.minY + 7), size: 13, weight: .semibold, color: titleColor)
        ctx.restoreGState()

        UIColor(white: 0, alpha: 0.18).setStroke()
        shape.lineWidth = 0.5
        shape.stroke()
    }

    private func drawNotes(_ w: Window, frame f: CGRect, ctx: CGContext) {
        let sidebar = CGRect(x: f.minX, y: f.minY + 30, width: 210, height: f.height - 30)
        UIColor(red: 0.97, green: 0.96, blue: 0.93, alpha: 1).setFill()
        UIBezierPath(rect: sidebar).fill()
        let notes = [("Ideas for Reach", "Today"), ("Groceries", "Yesterday"), ("Trip to Lisbon", "Monday"), ("Book list", "Sep 28"), ("Meeting notes", "Sep 20")]
        for (i, n) in notes.enumerated() {
            let r = CGRect(x: sidebar.minX + 8, y: sidebar.minY + 10 + CGFloat(i) * 56, width: sidebar.width - 16, height: 50)
            if i == 0 {
                UIColor(red: 1, green: 0.84, blue: 0.3, alpha: 1).setFill()
                UIBezierPath(roundedRect: r, cornerRadius: 7).fill()
            }
            text(n.0, at: CGPoint(x: r.minX + 10, y: r.minY + 7), size: 13, weight: .semibold)
            text(n.1, at: CGPoint(x: r.minX + 10, y: r.minY + 27), size: 11.5, weight: .regular, color: UIColor(white: 0.4, alpha: 1))
        }
        let editor = notesEditorRect(w).insetBy(dx: 28, dy: 18)
        ctx.saveGState()
        UIBezierPath(rect: notesEditorRect(w)).addClip()
        let para = NSMutableParagraphStyle()
        para.lineSpacing = 4
        para.paragraphSpacing = 6
        let attrs: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: 15),
            .foregroundColor: UIColor(white: 0.1, alpha: 1),
            .paragraphStyle: para,
        ]
        let body = NSMutableAttributedString(string: notesText, attributes: attrs)
        if let firstLine = notesText.components(separatedBy: "\n").first {
            body.addAttribute(.font, value: UIFont.systemFont(ofSize: 24, weight: .bold), range: NSRange(location: 0, length: (firstLine as NSString).length))
        }
        let bounds = body.boundingRect(with: CGSize(width: editor.width, height: 4000), options: [.usesLineFragmentOrigin], context: nil)
        notesMaxScroll = max(0, bounds.height - editor.height + 40)
        if followCaret {
            followCaret = false
            notesScroll = max(notesScroll, bounds.height - editor.height + 8)
        }
        notesScroll = min(notesScroll, notesMaxScroll)
        let rect = CGRect(x: editor.minX, y: editor.minY - notesScroll, width: editor.width, height: 4000)
        body.draw(with: rect, options: [.usesLineFragmentOrigin], context: nil)
        // Caret after the last character.
        let last = notesText.components(separatedBy: "\n").last ?? ""
        let lastWidth = measure(last, size: 15, weight: .regular).width.truncatingRemainder(dividingBy: max(editor.width, 1))
        UIColor(red: 0.98, green: 0.65, blue: 0.0, alpha: 1).setFill()
        UIBezierPath(rect: CGRect(x: editor.minX + lastWidth + 1, y: rect.minY + bounds.height - 19, width: 2, height: 18)).fill()
        ctx.restoreGState()
    }

    private func drawFinder(frame f: CGRect, ctx: CGContext) {
        let sidebar = CGRect(x: f.minX, y: f.minY + 30, width: 170, height: f.height - 30)
        UIColor(white: 0.93, alpha: 1).setFill()
        UIBezierPath(rect: sidebar).fill()
        text("Favorites", at: CGPoint(x: sidebar.minX + 14, y: sidebar.minY + 12), size: 11, weight: .semibold, color: UIColor(white: 0.5, alpha: 1))
        let items = [("airplayaudio", "AirDrop"), ("clock", "Recents"), ("square.grid.2x2", "Applications"), ("menubar.dock.rectangle", "Desktop"), ("doc", "Documents"), ("arrow.down.circle", "Downloads")]
        for (i, item) in items.enumerated() {
            let y = sidebar.minY + 34 + CGFloat(i) * 28
            if item.1 == "Documents" {
                UIColor(white: 0.84, alpha: 1).setFill()
                UIBezierPath(roundedRect: CGRect(x: sidebar.minX + 8, y: y - 4, width: sidebar.width - 16, height: 24), cornerRadius: 5).fill()
            }
            symbol(item.0, size: 13, weight: .regular)?.withTintColor(UIColor(red: 0.1, green: 0.48, blue: 1, alpha: 1)).draw(at: CGPoint(x: sidebar.minX + 16, y: y))
            text(item.1, at: CGPoint(x: sidebar.minX + 40, y: y), size: 13, weight: .regular)
        }
        let files = ["Projects", "Invoices", "Photos 2026", "Reach Design.key", "Budget.numbers", "Notes.txt", "Taxes", "Screenshots"]
        let cols = 4
        for (i, name) in files.enumerated() {
            let cx = sidebar.maxX + 30 + CGFloat(i % cols) * 110
            let cy = f.minY + 60 + CGFloat(i / cols) * 120
            let isFolder = !name.contains(".")
            if selectedFinderItem == i {
                UIColor(red: 0.1, green: 0.48, blue: 1, alpha: 0.18).setFill()
                UIBezierPath(roundedRect: CGRect(x: cx - 8, y: cy - 6, width: 96, height: 104), cornerRadius: 8).fill()
            }
            if let icon = symbol(isFolder ? "folder.fill" : "doc.fill", size: 50, weight: .regular) {
                icon.withTintColor(isFolder ? UIColor(red: 0.35, green: 0.68, blue: 1, alpha: 1) : UIColor(white: 0.75, alpha: 1))
                    .draw(at: CGPoint(x: cx + 40 - icon.size.width / 2, y: cy))
            }
            let tw = measure(name, size: 12, weight: .regular).width
            text(name, at: CGPoint(x: cx + 40 - min(tw, 90) / 2, y: cy + 70), size: 12, weight: .regular)
        }
    }

    func finderItem(at local: CGPoint, in w: Window) -> Int? {
        let f = localFrame(w)
        for i in 0..<8 {
            let cx = f.minX + 170 + 30 + CGFloat(i % 4) * 110
            let cy = f.minY + 60 + CGFloat(i / 4) * 120
            if CGRect(x: cx - 8, y: cy - 6, width: 96, height: 104).contains(local) { return i }
        }
        return nil
    }

    private func drawTerminal(frame f: CGRect) {
        let lines = [
            ("Last login: Tue Oct  7 09:12:44 on ttys001", UIColor(white: 0.75, alpha: 1)),
            ("alex@MacBook-Pro ~ % reach-probe host --synthetic", UIColor(white: 0.95, alpha: 1)),
            ("[host] started; fingerprint=7F3A-91C2", UIColor(red: 0.45, green: 0.9, blue: 0.5, alpha: 1)),
            ("[host] relays online (ntfy, hivemq)", UIColor(red: 0.45, green: 0.9, blue: 0.5, alpha: 1)),
            ("[host] session from iPhone — route: local, rtt 3 ms", UIColor(red: 0.45, green: 0.75, blue: 1, alpha: 1)),
            ("[host] H.264 3024×1964 @ 60 fps, 6.2 Mbps", UIColor(red: 0.45, green: 0.75, blue: 1, alpha: 1)),
            ("alex@MacBook-Pro ~ % ", UIColor(white: 0.95, alpha: 1)),
        ]
        for (i, l) in lines.enumerated() {
            mono(l.0, at: CGPoint(x: f.minX + 14, y: f.minY + 44 + CGFloat(i) * 19), color: l.1)
        }
    }

    private func drawSafari(frame f: CGRect) {
        UIColor(white: 0.97, alpha: 1).setFill()
        UIBezierPath(rect: CGRect(x: f.minX, y: f.minY + 30, width: f.width, height: 44)).fill()
        UIColor(white: 0.9, alpha: 1).setFill()
        UIBezierPath(roundedRect: CGRect(x: f.midX - 260, y: f.minY + 38, width: 520, height: 28), cornerRadius: 8).fill()
        text("apple.com", at: CGPoint(x: f.midX - 30, y: f.minY + 44), size: 13, weight: .regular)
        let hero = CGRect(x: f.minX, y: f.minY + 74, width: f.width, height: f.height - 74)
        UIColor.black.setFill()
        UIBezierPath(rect: hero).fill()
        text("MacBook Pro", at: CGPoint(x: hero.midX - 150, y: hero.minY + 120), size: 56, weight: .bold, color: .white)
        text("A work of art. At work.", at: CGPoint(x: hero.midX - 150, y: hero.minY + 200), size: 26, weight: .regular, color: UIColor(white: 0.8, alpha: 1))
    }

    private func drawContextMenu(at p: CGPoint, in ctx: CGContext) {
        let items = ["Get Info", "Rename", "Copy", "Paste", "Share…", "Quick Look"]
        let rect = CGRect(x: p.x, y: p.y, width: 180, height: CGFloat(items.count) * 24 + 10)
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: 8), blur: 20, color: UIColor.black.withAlphaComponent(0.35).cgColor)
        UIColor(white: 0.97, alpha: 0.98).setFill()
        UIBezierPath(roundedRect: rect, cornerRadius: 8).fill()
        ctx.restoreGState()
        for (i, item) in items.enumerated() {
            if i == 0 {
                UIColor(red: 0.1, green: 0.48, blue: 1, alpha: 1).setFill()
                UIBezierPath(roundedRect: CGRect(x: rect.minX + 5, y: rect.minY + 5, width: rect.width - 10, height: 22), cornerRadius: 4).fill()
            }
            text(item, at: CGPoint(x: rect.minX + 16, y: rect.minY + 8 + CGFloat(i) * 24), size: 13, weight: .regular, color: i == 0 ? .white : .black)
        }
    }

    private func drawHUD(_ symbolName: String, _ label: String, size: CGSize, in ctx: CGContext) {
        let w: CGFloat = 220, h: CGFloat = 200
        let r = CGRect(x: (size.width - w) / 2, y: size.height * 0.62 - h / 2, width: w, height: h)
        UIColor(white: 0.12, alpha: 0.78).setFill()
        UIBezierPath(roundedRect: r, cornerRadius: 26).fill()
        if let s = symbol(symbolName, size: 64, weight: .medium)?.withTintColor(.white) {
            s.draw(at: CGPoint(x: r.midX - s.size.width / 2, y: r.minY + 40))
        }
        let tw = min(measure(label, size: 18, weight: .semibold).width, w - 20)
        text(label, at: CGPoint(x: r.midX - tw / 2, y: r.maxY - 52), size: 18, weight: .semibold, color: .white)
    }

    // MARK: Text helpers

    @discardableResult
    private func text(_ s: String, at p: CGPoint, size: CGFloat, weight: UIFont.Weight, color: UIColor = UIColor(white: 0.08, alpha: 1)) -> CGSize {
        let attrs: [NSAttributedString.Key: Any] = [.font: UIFont.systemFont(ofSize: size, weight: weight), .foregroundColor: color]
        (s as NSString).draw(at: p, withAttributes: attrs)
        return (s as NSString).size(withAttributes: attrs)
    }

    private func mono(_ s: String, at p: CGPoint, color: UIColor) {
        let attrs: [NSAttributedString.Key: Any] = [.font: UIFont.monospacedSystemFont(ofSize: 13, weight: .regular), .foregroundColor: color]
        (s as NSString).draw(at: p, withAttributes: attrs)
    }

    private func measure(_ s: String, size: CGFloat, weight: UIFont.Weight) -> CGSize {
        (s as NSString).size(withAttributes: [.font: UIFont.systemFont(ofSize: size, weight: weight)])
    }

    private func symbol(_ name: String, size: CGFloat, weight: UIImage.SymbolWeight) -> UIImage? {
        UIImage(systemName: name, withConfiguration: UIImage.SymbolConfiguration(pointSize: size, weight: weight))
    }
}
