import AVFoundation
import UIKit

/// Owns the capture session for QR scanning. Configuration and start/stop run on a private serial queue
/// (they block for hundreds of milliseconds); results are delivered on the main thread.
final class QRScanner: NSObject, AVCaptureMetadataOutputObjectsDelegate, @unchecked Sendable {
    enum Status: Equatable { case starting, running, denied, unavailable }

    let session = AVCaptureSession()
    /// Main thread.
    var onStatus: ((Status) -> Void)?
    /// Main thread. Raw metadata object so the preview can convert its bounds into view coordinates.
    var onCode: ((AVMetadataMachineReadableCodeObject) -> Void)?

    /// Set on the scanner queue before `.running` is reported; read on main after that.
    private(set) var device: AVCaptureDevice?

    private let queue = DispatchQueue(label: "reach.scanner", qos: .userInitiated)
    private var configured = false   // queue

    func start() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            run()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                if granted { self?.run() } else { self?.report(.denied) }
            }
        default:
            report(.denied)
        }
    }

    func stop() {
        queue.async { [session] in
            if session.isRunning { session.stopRunning() }
        }
    }

    private func run() {
        queue.async { [weak self] in
            guard let self else { return }
            if !self.configured {
                guard self.configure() else { self.report(.unavailable); return }
                self.configured = true
            }
            if !self.session.isRunning { self.session.startRunning() }
            self.report(.running)
        }
    }

    private func configure() -> Bool {
        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
              let input = try? AVCaptureDeviceInput(device: device) else { return false }
        session.beginConfiguration()
        defer { session.commitConfiguration() }
        session.sessionPreset = .high
        guard session.canAddInput(input) else { return false }
        session.addInput(input)
        self.device = device
        let output = AVCaptureMetadataOutput()
        guard session.canAddOutput(output) else { return false }
        session.addOutput(output)
        output.setMetadataObjectsDelegate(self, queue: .main)
        output.metadataObjectTypes = output.availableMetadataObjectTypes.contains(.qr) ? [.qr] : []
        // Codes are read from a laptop screen at arm's length: bias autofocus to near.
        if (try? device.lockForConfiguration()) != nil {
            if device.isAutoFocusRangeRestrictionSupported { device.autoFocusRangeRestriction = .near }
            if device.isFocusModeSupported(.continuousAutoFocus) { device.focusMode = .continuousAutoFocus }
            device.unlockForConfiguration()
        }
        return true
    }

    private func report(_ status: Status) {
        DispatchQueue.main.async { [weak self] in self?.onStatus?(status) }
    }

    func metadataOutput(_ output: AVCaptureMetadataOutput, didOutput metadataObjects: [AVMetadataObject],
                        from connection: AVCaptureConnection) {
        guard let code = metadataObjects.compactMap({ $0 as? AVMetadataMachineReadableCodeObject }).first,
              code.stringValue != nil else { return }
        onCode?(code)
    }
}

/// Full-bleed camera preview, kept horizon-level as the phone rotates.
final class ScannerPreviewView: UIView {
    override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
    var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }

    private var rotation: AVCaptureDevice.RotationCoordinator?
    private var rotationObservation: NSKeyValueObservation?

    /// Call once the session is running (the device is known by then).
    func trackRotation(of device: AVCaptureDevice) {
        guard rotation == nil else { return }
        let coordinator = AVCaptureDevice.RotationCoordinator(device: device, previewLayer: previewLayer)
        rotation = coordinator
        applyRotation(coordinator.videoRotationAngleForHorizonLevelPreview)
        // KVO updates arrive on the main queue (documented in AVCaptureDevice.h).
        rotationObservation = coordinator.observe(\.videoRotationAngleForHorizonLevelPreview, options: [.new]) { [weak self] c, _ in
            let angle = c.videoRotationAngleForHorizonLevelPreview
            MainActor.assumeIsolated { self?.applyRotation(angle) }
        }
    }

    private func applyRotation(_ angle: CGFloat) {
        guard let connection = previewLayer.connection, connection.isVideoRotationAngleSupported(angle) else { return }
        connection.videoRotationAngle = angle
    }

    /// The code's outline in this view's coordinates.
    func rect(for code: AVMetadataMachineReadableCodeObject) -> CGRect? {
        previewLayer.transformedMetadataObject(for: code)?.bounds
    }
}
