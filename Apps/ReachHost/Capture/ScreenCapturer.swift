import CoreMedia
import ReachCore
import ScreenCaptureKit

/// Captures one display with ScreenCaptureKit and hands complete frames to `onFrame`.
///
/// Threading: the public methods may be called from any thread; all stream management happens on a
/// private serial queue, frames are delivered on a dedicated user-interactive queue, and completion
/// and interruption callbacks arrive on the main queue.
final class ScreenCapturer: NSObject, @unchecked Sendable {
    struct Settings: Equatable {
        var displayID: CGDirectDisplayID
        var width: Int
        var height: Int
        var framesPerSecond: Int
    }

    enum Failure: Error, Equatable {
        /// Screen Recording permission is missing.
        case permissionDenied
        case displayUnavailable
        case failed(String)

        var message: String {
            switch self {
            case .permissionDenied: return "Allow Screen Recording for Reach Host on your Mac to see its screen."
            case .displayUnavailable: return "That display isn't connected anymore."
            case .failed(let reason): return "Couldn't capture the screen: \(reason)"
            }
        }
    }

    /// Called on the frame queue for every newly rendered frame. Set before the first `start`.
    var onFrame: ((CVPixelBuffer) -> Void)?
    /// Called on the main queue when a running stream stops by itself (display gone, system stop…).
    var onInterrupted: ((Failure) -> Void)?

    private let queue = DispatchQueue(label: "reach.host.capture", qos: .userInitiated)
    private let frameQueue = DispatchQueue(label: "reach.host.capture.frames", qos: .userInteractive)

    // Frame timing, confined to `frameQueue`.
    private var timingFrames = 0
    private var timingDelayTotal: UInt64 = 0
    private var timingDelayMax: UInt64 = 0
    private var timingSince = mach_absolute_time()
    private static let timebase: mach_timebase_info_data_t = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return info
    }()

    // Confined to `queue`.
    private var stream: SCStream?
    private var current: Settings?
    private var generation = 0

    /// Starts capturing with `settings`, reusing the running stream when possible.
    func start(_ settings: Settings, completion: @escaping (Result<Void, Failure>) -> Void) {
        queue.async {
            self.generation += 1
            let generation = self.generation
            if let stream = self.stream, let current = self.current, current.displayID == settings.displayID {
                self.reconfigure(stream, to: settings, generation: generation, completion: completion)
            } else {
                self.restart(with: settings, generation: generation, completion: completion)
            }
        }
    }

    func stop() {
        queue.async {
            self.generation += 1
            self.tearDown()
        }
    }

    // MARK: - Private (on `queue`)

    private func reconfigure(_ stream: SCStream, to settings: Settings, generation: Int,
                             completion: @escaping (Result<Void, Failure>) -> Void) {
        guard settings != current else { return finish(.success(()), completion) }
        stream.updateConfiguration(Self.configuration(for: settings)) { error in
            self.queue.async {
                guard generation == self.generation else { return }
                if let error {
                    ReachLog.error("host", "capture reconfigure failed (\(error.localizedDescription)); restarting")
                    self.restart(with: settings, generation: generation, completion: completion)
                } else {
                    self.current = settings
                    ReachLog.info("host", "capture reconfigured: \(settings.width)×\(settings.height) @ \(settings.framesPerSecond) fps")
                    self.finish(.success(()), completion)
                }
            }
        }
    }

    private func restart(with settings: Settings, generation: Int, completion: @escaping (Result<Void, Failure>) -> Void) {
        tearDown()
        SCShareableContent.getExcludingDesktopWindows(true, onScreenWindowsOnly: true) { content, error in
            self.queue.async {
                guard generation == self.generation else { return }
                if let error {
                    return self.finish(.failure(Self.failure(from: error)), completion)
                }
                guard let display = content?.displays.first(where: { $0.displayID == settings.displayID }) else {
                    return self.finish(.failure(.displayUnavailable), completion)
                }
                self.open(display, settings: settings, generation: generation, completion: completion)
            }
        }
    }

    private func open(_ display: SCDisplay, settings: Settings, generation: Int,
                      completion: @escaping (Result<Void, Failure>) -> Void) {
        let filter = SCContentFilter(display: display, excludingWindows: [])
        let stream = SCStream(filter: filter, configuration: Self.configuration(for: settings), delegate: self)
        do {
            try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: frameQueue)
        } catch {
            return finish(.failure(.failed(error.localizedDescription)), completion)
        }
        self.stream = stream
        current = settings
        stream.startCapture { error in
            self.queue.async {
                guard generation == self.generation else { return }
                if let error {
                    self.tearDown()
                    self.finish(.failure(Self.failure(from: error)), completion)
                } else {
                    ReachLog.info("host", "capture started: display \(settings.displayID) " +
                                  "\(settings.width)×\(settings.height) @ \(settings.framesPerSecond) fps")
                    self.finish(.success(()), completion)
                }
            }
        }
    }

    private func tearDown() {
        guard let stream else { return }
        self.stream = nil
        current = nil
        try? stream.removeStreamOutput(self, type: .screen)
        stream.stopCapture { error in
            if let error, (error as NSError).code != SCStreamError.Code.attemptToStopStreamState.rawValue {
                ReachLog.debug("host", "capture stop: \(error.localizedDescription)")
            }
        }
    }

    private func finish(_ result: Result<Void, Failure>, _ completion: @escaping (Result<Void, Failure>) -> Void) {
        DispatchQueue.main.async { completion(result) }
    }

    static func configuration(for settings: Settings) -> SCStreamConfiguration {
        let configuration = SCStreamConfiguration()
        configuration.width = settings.width
        configuration.height = settings.height
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(max(1, settings.framesPerSecond)))
        // NV12 video range + BT.709 is what the H.264 encoder consumes natively, so frames go to
        // VideoToolbox with no conversion. sRGB shares BT.709's primaries and is what the iPhone
        // displays, so the capture skips a transfer-function conversion as well.
        configuration.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        configuration.colorMatrix = CGDisplayStream.yCbCrMatrix_ITU_R_709_2
        configuration.colorSpaceName = CGColorSpace.sRGB
        // The iPhone draws the cursor itself (zero-latency local cursor), so keep it out of the video.
        configuration.showsCursor = false
        configuration.queueDepth = 5
        configuration.capturesAudio = false
        configuration.captureResolution = .best
        // Scaled sizes are rounded to even pixels, a hair off the display's aspect ratio; stretching by
        // that much is invisible, whereas preserving it would add a sliver of black border.
        configuration.preservesAspectRatio = false
        return configuration
    }

    static func failure(from error: Error) -> Failure {
        let nsError = error as NSError
        if nsError.domain == SCStreamErrorDomain, nsError.code == SCStreamError.Code.userDeclined.rawValue {
            return .permissionDenied
        }
        return .failed(nsError.localizedDescription)
    }
}

extension ScreenCapturer: SCStreamOutput {
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sampleBuffer.isValid,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
                as? [[SCStreamFrameInfo: Any]],
              let rawStatus = attachments.first?[.status] as? Int,
              let status = SCFrameStatus(rawValue: rawStatus),
              let pixelBuffer = sampleBuffer.imageBuffer else { return }
        // `.complete` is a newly rendered frame. `.started` marks the first frame after a (re)start;
        // when it carries an image it's forwarded too, otherwise a static screen would stay black
        // until something changed. Idle/blank/suspended carry nothing new.
        guard status == .complete || status == .started else { return }
        if let displayTime = attachments.first?[.displayTime] as? UInt64 { recordTiming(displayTime: displayTime) }
        onFrame?(pixelBuffer)
    }

    /// How long after the window server composed a frame it reached us; logged every 2 s.
    private func recordTiming(displayTime: UInt64) {
        let now = mach_absolute_time()
        let delay = now > displayTime ? now - displayTime : 0
        timingFrames += 1
        timingDelayTotal += delay
        timingDelayMax = max(timingDelayMax, delay)
        let elapsed = Self.nanoseconds(now - timingSince)
        guard elapsed >= 2_000_000_000 else { return }
        ReachLog.info("perf", String(format: "capture fps=%.1f delay avg=%.1fms max=%.1fms",
                                     Double(timingFrames) / (Double(elapsed) / 1e9),
                                     Double(Self.nanoseconds(timingDelayTotal)) / Double(timingFrames) / 1e6,
                                     Double(Self.nanoseconds(timingDelayMax)) / 1e6))
        timingFrames = 0; timingDelayTotal = 0; timingDelayMax = 0; timingSince = now
    }

    private static func nanoseconds(_ ticks: UInt64) -> UInt64 {
        ticks * UInt64(timebase.numer) / UInt64(timebase.denom)
    }
}

extension ScreenCapturer: SCStreamDelegate {
    func stream(_ stream: SCStream, didStopWithError error: Error) {
        queue.async {
            guard stream === self.stream else { return }
            self.stream = nil
            self.current = nil
            let failure = Self.failure(from: error)
            ReachLog.error("host", "capture stopped: \(error.localizedDescription)")
            DispatchQueue.main.async { self.onInterrupted?(failure) }
        }
    }
}
