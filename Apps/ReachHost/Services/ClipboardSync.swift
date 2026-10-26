import AppKit
import ReachCore
import ReachProtocol

/// Mirrors the Mac's clipboard to the iPhone during a session, and applies clipboard content the
/// iPhone sends. Main thread only (NSPasteboard).
@MainActor
final class ClipboardSync {
    static let pollInterval: TimeInterval = 0.5
    static let maxTextBytes = 4_000_000
    /// Large control messages are fragmented over a dedicated bulk channel (ReachCore caps a message
    /// at 8 MB). Data is base64-encoded on the wire, so the encoded message is what has to fit.
    nonisolated static let maxMessageBytes = 6_000_000

    /// nspasteboard.org markers that password managers and similar apps set on secrets.
    private static let privateTypes: Set<NSPasteboard.PasteboardType> = [
        NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"),
        NSPasteboard.PasteboardType("org.nspasteboard.TransientType"),
    ]

    private let pasteboard: NSPasteboard
    private let send: (ClipboardContent) -> Void
    private var timer: Timer?
    private var lastChangeCount: Int

    init(pasteboard: NSPasteboard = .general, send: @escaping (ClipboardContent) -> Void) {
        self.pasteboard = pasteboard
        self.send = send
        lastChangeCount = pasteboard.changeCount
    }

    func start(sendCurrent: Bool) {
        stop()
        lastChangeCount = pasteboard.changeCount
        if sendCurrent { sendIfAllowed() }
        let timer = Timer(timeInterval: Self.pollInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
        timer.tolerance = 0.1
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    /// Writes content from the iPhone. Not echoed back: the resulting change count is recorded as seen.
    func apply(_ content: ClipboardContent) {
        var objects: [NSPasteboardWriting] = []
        if let text = content.text { objects.append(text as NSString) }
        if let png = content.imagePNG, let image = NSImage(data: png) { objects.append(image) }
        guard !objects.isEmpty else { return }
        pasteboard.clearContents()
        if !pasteboard.writeObjects(objects) { ReachLog.error("host", "couldn't write the iPhone's clipboard") }
        lastChangeCount = pasteboard.changeCount
    }

    private func poll() {
        guard pasteboard.changeCount != lastChangeCount else { return }
        lastChangeCount = pasteboard.changeCount
        sendIfAllowed()
    }

    private func sendIfAllowed() {
        if let types = pasteboard.types, !Self.privateTypes.isDisjoint(with: types) { return }
        guard let content = currentContent() else { return }
        guard Self.fitsInMessage(content) else {
            ReachLog.info("host", "clipboard too large to send to iPhone; skipped")
            return
        }
        send(content)
    }

    /// Whether `content` fits in one control message once encoded (Data goes as base64, so a PNG
    /// can be at most about ¾ of the budget).
    nonisolated static func fitsInMessage(_ content: ClipboardContent) -> Bool {
        guard let encoded = try? WireCodec.encode(HostMessage.clipboard(content)) else { return false }
        return encoded.count <= maxMessageBytes
    }

    private func currentContent() -> ClipboardContent? {
        if let text = pasteboard.string(forType: .string), !text.isEmpty {
            return text.utf8.count <= Self.maxTextBytes ? ClipboardContent(text: text) : nil
        }
        if let png = pasteboard.data(forType: .png) { return ClipboardContent(imagePNG: png) }
        if let tiff = pasteboard.data(forType: .tiff), let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
            return ClipboardContent(imagePNG: png)
        }
        return nil
    }
}
