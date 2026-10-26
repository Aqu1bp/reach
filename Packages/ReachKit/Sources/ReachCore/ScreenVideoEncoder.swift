import Foundation
import os
import CoreMedia
import VideoToolbox
import WebRTC

/// Hardware H.264 / HEVC encoder using VideoToolbox's low-latency rate control, the mode Apple built
/// for video calls.
///
/// WebRTC's bundled encoder uses the default rate control, which suits a screen badly: when a scroll
/// stops, the text keeps whatever quality the moving frames got. Static frames then cost almost no
/// bits, so nothing sharpens it until the next key frame. Low-latency rate control keeps refining a
/// still picture over the next frames (the host re-sends the last frame for that). It also keeps
/// frame sizes close to the target, so a big frame doesn't hold up the ones behind it. Measured on
/// scrolling text at 2.5 Mbit/s: about 51 dB once the scroll settles, against about 43 dB with the
/// default rate control.
final class ScreenVideoEncoder: NSObject, RTCVideoEncoder {
    enum Codec: Equatable {
        case h264(baseline: Bool)
        case hevc

        var videoToolboxType: CMVideoCodecType {
            if case .hevc = self { return kCMVideoCodecType_HEVC }
            return kCMVideoCodecType_H264
        }

        var profile: CFString {
            switch self {
            case .h264(let baseline):
                return baseline ? kVTProfileLevel_H264_ConstrainedBaseline_AutoLevel : kVTProfileLevel_H264_ConstrainedHigh_AutoLevel
            case .hevc:
                return kVTProfileLevel_HEVC_Main_AutoLevel
            }
        }
    }

    // MARK: Process-wide

    /// HostEngine stamps every newly captured buffer with a serial number (a CFNumber). Re-sent
    /// frames are the same buffer, so they keep it.
    static let frameSerialKey = "reach.frameSerial" as CFString

    /// What the encoders in this process have done, for the host's `perf` line. The frame counts only
    /// grow; the rest is the latest setting.
    struct Counters: Sendable {
        var encodedFrames = 0
        /// Frames VideoToolbox's rate control skipped rather than blow its budget.
        var droppedFrames = 0
        var targetKbps = 0
        /// The rate VideoToolbox is told to expect (it budgets each frame as bitrate ÷ this).
        var expectedFps = 0
        /// The input frame rate WebRTC last passed to `setBitrate`.
        var webrtcFps = 0
    }
    private static let countersLock = OSAllocatedUnfairLock(initialState: Counters())
    static var counters: Counters { countersLock.withLock { $0 } }

    private let codec: Codec
    private let callbackLock = NSLock()
    private var _callback: RTCVideoEncoderCallback?
    private var callback: RTCVideoEncoderCallback? {
        get { callbackLock.withLock { _callback } }
        set { callbackLock.withLock { _callback = newValue } }
    }

    // Encoder-thread state (WebRTC calls everything below from its single encoder queue).
    private var session: VTCompressionSession?
    private var width: Int32 = 0
    private var height: Int32 = 0
    private var bitrateBps = 4_000_000
    private var frameRate = 60
    /// What WebRTC last reported (for logs and the perf line).
    private var webrtcFrameRate = 0
    private var loggedKbps = 0
    private var rateLoggedAt: UInt64 = 0
    private var rateLowKbps = Int.max
    private var rateHighKbps = 0
    private var screenshare = true
    private var lowLatency = true
    private var lastPTS = CMTime.invalid
    /// The host re-sends its last capture after motion stops so the picture can sharpen. Those
    /// repeats are only worth encoding after a change big enough to have cost quality; after a small
    /// one (a caret blink, a clock ticking) they'd just spend bandwidth on an idle screen.
    private var lastSource: SourceID?
    private let refreshLock = NSLock()
    private var _refreshBudget = 0
    private var refreshBudget: Int {
        get { refreshLock.withLock { _refreshBudget } }
        set { refreshLock.withLock { _refreshBudget = newValue } }
    }
    /// About 1.5 s at 60 fps: enough for even a low bitrate to bring text back to full sharpness.
    private static let refreshFrames = 90
    /// Changes encoded larger than this get a refresh. Small edits are already sent at the quality of a
    /// still picture.
    private static let refreshTriggerBytes = 3_000
    private var scalePool: CVPixelBufferPool?
    private var scalePoolSize = (0, 0)
    private var scaleTemp: [UInt8] = []

    init(codec: Codec) {
        self.codec = codec
        super.init()
    }

    deinit { destroySession() }

    // MARK: RTCVideoEncoder

    func setCallback(_ callback: RTCVideoEncoderCallback?) {
        self.callback = callback
    }

    func startEncode(with settings: RTCVideoEncoderSettings, numberOfCores: Int32) -> Int {
        screenshare = settings.mode == .screensharing
        if settings.startBitrate > 0 { bitrateBps = Int(settings.startBitrate) * 1000 }
        frameRate = Int(max(1, min(120, settings.maxFramerate)))
        let ok = makeSession(width: Int32(settings.width), height: Int32(settings.height))
        return ok ? Codes.ok : Codes.error
    }

    func release() -> Int {
        destroySession()
        return Codes.ok
    }

    func encode(_ frame: RTCVideoFrame, codecSpecificInfo info: (any RTCCodecSpecificInfo)?, frameTypes: [NSNumber]) -> Int {
        guard callback != nil else { return Codes.uninitialized }
        var forceKey = frameTypes.contains { $0.uintValue == RTCFrameType.videoFrameKey.rawValue }
        let source = (frame.buffer as? RTCCVPixelBuffer).map { Self.sourceID(of: $0.pixelBuffer) }
        let isRepeat = source != nil && source == lastSource
        lastSource = source
        if isRepeat, !forceKey {
            // Nothing new on screen and nothing left to sharpen.
            guard refreshBudget > 0 else { return Codes.ok }
            refreshBudget -= 1
        }
        guard let pixelBuffer = pixelBuffer(for: frame) else { return Codes.error }
        let w = Int32(CVPixelBufferGetWidth(pixelBuffer)), h = Int32(CVPixelBufferGetHeight(pixelBuffer))
        if session == nil || w != width || h != height {
            guard makeSession(width: w, height: h) else { return Codes.error }
            forceKey = true
        }
        // VideoToolbox wants strictly increasing timestamps; re-sent frames can land on the same tick.
        var pts = CMTime(value: frame.timeStampNs, timescale: 1_000_000_000)
        if lastPTS.isValid, pts <= lastPTS { pts = CMTimeAdd(lastPTS, CMTime(value: 1, timescale: 1_000_000)) }
        lastPTS = pts

        let rtpTimestamp = UInt32(bitPattern: frame.timeStamp)
        let captureMs = frame.timeStampNs / 1_000_000
        let props = forceKey ? [kVTEncodeFrameOptionKey_ForceKeyFrame: kCFBooleanTrue] as CFDictionary : nil
        let context = FrameContext(rtpTimestamp: rtpTimestamp, captureMs: captureMs, width: w, height: h,
                                   screenshare: screenshare, isRepeat: isRepeat)
        var status = submit(pixelBuffer, pts: pts, props: props, context: context)
        if status == kVTInvalidSessionErr {
            // The hardware encoder can be torn down underneath us (sleep, GPU reset): start over.
            ReachLog.info("video", "encoder session invalidated; recreating")
            guard makeSession(width: w, height: h) else { return Codes.error }
            let key = [kVTEncodeFrameOptionKey_ForceKeyFrame: kCFBooleanTrue] as CFDictionary
            status = submit(pixelBuffer, pts: pts, props: key, context: context)
        }
        if status != noErr {
            ReachLog.error("video", "encode failed: \(status)")
            return Codes.error
        }
        return Codes.ok
    }

    func setBitrate(_ bitrateKbit: UInt32, framerate: UInt32) -> Int32 {
        let bps = Int(bitrateKbit) * 1000
        let fps = Int(max(1, min(120, framerate)))
        if bps > 0, bps != bitrateBps {
            bitrateBps = bps
            applyBitrate()
        }
        webrtcFrameRate = fps
        if fps != frameRate {
            frameRate = fps
            if let session { VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ExpectedFrameRate, value: fps as CFNumber) }
        }
        publishRates()
        logRateIfChanged()
        return Int32(Codes.ok)
    }

    /// One line when the target has moved by more than 10%, at most every 2 s; the range shows any
    /// dips in between.
    private func logRateIfChanged() {
        let kbps = bitrateBps / 1000
        rateLowKbps = min(rateLowKbps, kbps)
        rateHighKbps = max(rateHighKbps, kbps)
        let now = DispatchTime.now().uptimeNanoseconds
        guard abs(kbps - loggedKbps) * 10 > loggedKbps, now &- rateLoggedAt >= 2_000_000_000 else { return }
        ReachLog.info("video", "encoder rate: target=\(kbps) kbps (\(rateLowKbps)–\(rateHighKbps) since last) " +
                      "expect=\(frameRate) fps webrtc=\(webrtcFrameRate) fps")
        loggedKbps = kbps
        rateLoggedAt = now
        rateLowKbps = kbps
        rateHighKbps = kbps
    }

    private func publishRates() {
        let kbps = bitrateBps / 1000, expected = frameRate, reported = webrtcFrameRate
        Self.countersLock.withLock {
            $0.targetKbps = kbps
            $0.expectedFps = expected
            $0.webrtcFps = reported
        }
    }

    func implementationName() -> String {
        let name = codec == .hevc ? "VideoToolbox HEVC" : "VideoToolbox H.264"
        return lowLatency ? "\(name) (low latency)" : name
    }

    /// No QP-based downscaling: the host app chooses the stream size itself.
    func scalingSettings() -> RTCVideoEncoderQpThresholds? { nil }

    var resolutionAlignment: Int { 1 }
    var applyAlignmentToAllSimulcastLayers: Bool { false }
    var supportsNativeHandle: Bool { true }

    // MARK: Session

    private func makeSession(width: Int32, height: Int32) -> Bool {
        destroySession()
        guard width > 0, height > 0 else { return false }
        var session: VTCompressionSession?
        var status = OSStatus(-1)
        for lowLatency in [true, false] {
            var spec: [CFString: Any] = [:]
            if lowLatency { spec[kVTVideoEncoderSpecification_EnableLowLatencyRateControl] = true }
            #if os(macOS)
            spec[kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder] = true
            #endif
            status = VTCompressionSessionCreate(allocator: nil, width: width, height: height, codecType: codec.videoToolboxType,
                                                encoderSpecification: spec as CFDictionary, imageBufferAttributes: nil,
                                                compressedDataAllocator: nil, outputCallback: nil, refcon: nil,
                                                compressionSessionOut: &session)
            if status == noErr {
                self.lowLatency = lowLatency
                break
            }
        }
        guard status == noErr, let session else {
            ReachLog.error("video", "couldn't create \(implementationName()) encoder \(width)×\(height): \(status)")
            return false
        }
        func set(_ key: CFString, _ value: CFTypeRef) {
            let r = VTSessionSetProperty(session, key: key, value: value)
            if r != noErr { ReachLog.debug("video", "encoder property \(key) rejected: \(r)") }
        }
        set(kVTCompressionPropertyKey_RealTime, kCFBooleanTrue)
        set(kVTCompressionPropertyKey_AllowFrameReordering, kCFBooleanFalse)
        set(kVTCompressionPropertyKey_ProfileLevel, codec.profile)
        set(kVTCompressionPropertyKey_ExpectedFrameRate, frameRate as CFNumber)
        // Key frames only when the receiver asks (loss it couldn't repair, or a new decoder).
        set(kVTCompressionPropertyKey_MaxKeyFrameInterval, 7200 as CFNumber)
        set(kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration, 240 as CFNumber)
        set(kVTCompressionPropertyKey_ColorPrimaries, kCVImageBufferColorPrimaries_ITU_R_709_2)
        set(kVTCompressionPropertyKey_TransferFunction, kCVImageBufferTransferFunction_ITU_R_709_2)
        set(kVTCompressionPropertyKey_YCbCrMatrix, kCVImageBufferYCbCrMatrix_ITU_R_709_2)
        self.session = session
        self.width = width
        self.height = height
        lastPTS = .invalid
        applyBitrate()
        publishRates()
        VTCompressionSessionPrepareToEncodeFrames(session)
        ReachLog.info("video", "encoder: \(implementationName()) \(width)×\(height) @ \(bitrateBps / 1000) kbps, \(frameRate) fps")
        return true
    }

    private func applyBitrate() {
        guard let session else { return }
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AverageBitRate, value: bitrateBps as CFNumber)
        // Same ceiling WebRTC's own encoder uses: at most 1.5× the target in any one second.
        let limits = [Double(bitrateBps) * 1.5 / 8, 1.0] as CFArray
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_DataRateLimits, value: limits)
    }

    private func destroySession() {
        guard let session else { return }
        VTCompressionSessionInvalidate(session)
        self.session = nil
    }

    // MARK: Encoding

    private struct FrameContext {
        let rtpTimestamp: UInt32
        let captureMs: Int64
        let width: Int32
        let height: Int32
        let screenshare: Bool
        let isRepeat: Bool
    }

    /// Which picture a frame carries: HostEngine's serial, or the buffer's address if it has none.
    /// The address alone can mislead: if WebRTC drops a frame before it reaches `encode`,
    /// ScreenCaptureKit can later reuse that buffer for a new picture, which would then look like a
    /// repeat of the last one encoded and be skipped.
    private enum SourceID: Equatable {
        case serial(Int64)
        case buffer(UnsafeMutableRawPointer)
    }

    private static func sourceID(of buffer: CVPixelBuffer) -> SourceID {
        if let serial = (CVBufferCopyAttachment(buffer, frameSerialKey, nil) as? NSNumber)?.int64Value { return .serial(serial) }
        return .buffer(Unmanaged.passUnretained(buffer).toOpaque())
    }

    private func submit(_ buffer: CVPixelBuffer, pts: CMTime, props: CFDictionary?, context: FrameContext) -> OSStatus {
        guard let session else { return kVTInvalidSessionErr }
        return VTCompressionSessionEncodeFrame(session, imageBuffer: buffer, presentationTimeStamp: pts, duration: .invalid,
                                               frameProperties: props, infoFlagsOut: nil) { [weak self] status, flags, sample in
            self?.didEncode(status: status, flags: flags, sample: sample, context: context)
        }
    }

    /// Called on a VideoToolbox thread.
    private func didEncode(status: OSStatus, flags: VTEncodeInfoFlags, sample: CMSampleBuffer?, context: FrameContext) {
        guard status == noErr else {
            ReachLog.error("video", "encoder output error: \(status)")
            return
        }
        // Low-latency rate control may skip a frame rather than blow the budget. Counted so the perf
        // line shows it (frames it skips never reach WebRTC's stats).
        if flags.contains(.frameDropped) {
            Self.countersLock.withLock { $0.droppedFrames += 1 }
            return
        }
        guard let sample, let callback else { return }
        Self.countersLock.withLock { $0.encodedFrames += 1 }
        let isKey = Self.isKeyFrame(sample)
        guard let data = AnnexB.encode(sample, hevc: codec == .hevc, includeParameterSets: isKey) else {
            ReachLog.error("video", "couldn't convert encoded frame")
            return
        }
        if !context.isRepeat, isKey || data.count > Self.refreshTriggerBytes { refreshBudget = Self.refreshFrames }
        let image = RTCEncodedImage()
        image.buffer = data
        image.encodedWidth = context.width
        image.encodedHeight = context.height
        image.timeStamp = context.rtpTimestamp
        image.captureTimeMs = context.captureMs
        image.frameType = isKey ? .videoFrameKey : .videoFrameDelta
        image.rotation = ._0
        image.contentType = context.screenshare ? .screenshare : .unspecified
        image.flags = 0xFF // VideoSendTiming::kInvalid — no timing frame
        image.qp = NSNumber(value: -1)
        let info: any RTCCodecSpecificInfo = codec == .hevc ? HEVCCodecSpecificInfo() : RTCCodecSpecificInfoH264()
        if !callback(image, info) { ReachLog.debug("video", "encoded frame not accepted") }
    }

    private static func isKeyFrame(_ sample: CMSampleBuffer) -> Bool {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[CFString: Any]],
              let first = attachments.first else { return true }
        return !((first[kCMSampleAttachmentKey_NotSync] as? Bool) ?? false)
    }

    /// The captured buffer, cropped/scaled first if WebRTC adapted the frame size.
    private func pixelBuffer(for frame: RTCVideoFrame) -> CVPixelBuffer? {
        guard let rtc = frame.buffer as? RTCCVPixelBuffer else {
            ReachLog.error("video", "encoder got a non-CVPixelBuffer frame")
            return nil
        }
        let w = Int(frame.width), h = Int(frame.height)
        guard rtc.requiresCropping() || rtc.requiresScaling(toWidth: Int32(w), height: Int32(h)) else { return rtc.pixelBuffer }
        if scalePool == nil || scalePoolSize != (w, h) {
            let attrs: [CFString: Any] = [
                kCVPixelBufferWidthKey: w,
                kCVPixelBufferHeightKey: h,
                kCVPixelBufferPixelFormatTypeKey: CVPixelBufferGetPixelFormatType(rtc.pixelBuffer),
                kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
            ]
            var pool: CVPixelBufferPool?
            CVPixelBufferPoolCreate(nil, nil, attrs as CFDictionary, &pool)
            scalePool = pool
            scalePoolSize = (w, h)
        }
        guard let pool = scalePool else { return nil }
        var out: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &out)
        guard let out else { return nil }
        let tempSize = Int(rtc.bufferSizeForCroppingAndScaling(toWidth: Int32(w), height: Int32(h)))
        if scaleTemp.count < tempSize { scaleTemp = [UInt8](repeating: 0, count: tempSize) }
        let ok = scaleTemp.withUnsafeMutableBufferPointer { rtc.cropAndScale(to: out, withTempBuffer: tempSize > 0 ? $0.baseAddress : nil) }
        return ok ? out : nil
    }

    enum Codes {
        static let ok = 0
        static let error = -1
        static let uninitialized = -7
    }
}

/// Marks an HEVC frame for WebRTC. This build has no Objective-C H.265 info class, so the frame
/// travels as "generic" codec info; WebRTC still packetizes it as H.265 because it picks the RTP
/// packetizer from the negotiated payload type.
final class HEVCCodecSpecificInfo: NSObject, RTCCodecSpecificInfo {}

/// Annex B ⇄ length-prefixed conversion. VideoToolbox works with length-prefixed NAL units
/// (avcC/hvcC); RTP packetizers and depacketizers use start codes.
enum AnnexB {
    static let startCode: [UInt8] = [0, 0, 0, 1]

    /// Encoder output → Annex B, with the parameter sets in front of key frames so a receiver can
    /// start decoding from any key frame.
    static func encode(_ sample: CMSampleBuffer, hevc: Bool, includeParameterSets: Bool) -> Data? {
        guard let block = CMSampleBufferGetDataBuffer(sample) else { return nil }
        var out = Data()
        var lengthSize: Int32 = 4
        if let format = CMSampleBufferGetFormatDescription(sample) {
            var count = 0
            let probe = hevc
                ? CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(format, parameterSetIndex: 0, parameterSetPointerOut: nil,
                                                                     parameterSetSizeOut: nil, parameterSetCountOut: &count,
                                                                     nalUnitHeaderLengthOut: &lengthSize)
                : CMVideoFormatDescriptionGetH264ParameterSetAtIndex(format, parameterSetIndex: 0, parameterSetPointerOut: nil,
                                                                     parameterSetSizeOut: nil, parameterSetCountOut: &count,
                                                                     nalUnitHeaderLengthOut: &lengthSize)
            if probe != noErr { return nil }
            if includeParameterSets {
                for i in 0..<count {
                    var pointer: UnsafePointer<UInt8>?
                    var size = 0
                    let status = hevc
                        ? CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(format, parameterSetIndex: i, parameterSetPointerOut: &pointer,
                                                                             parameterSetSizeOut: &size, parameterSetCountOut: nil,
                                                                             nalUnitHeaderLengthOut: nil)
                        : CMVideoFormatDescriptionGetH264ParameterSetAtIndex(format, parameterSetIndex: i, parameterSetPointerOut: &pointer,
                                                                             parameterSetSizeOut: &size, parameterSetCountOut: nil,
                                                                             nalUnitHeaderLengthOut: nil)
                    guard status == noErr, let pointer else { return nil }
                    out.append(contentsOf: startCode)
                    out.append(pointer, count: size)
                }
            }
        }
        let total = CMBlockBufferGetDataLength(block)
        var bytes = [UInt8](repeating: 0, count: total)
        guard CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: total, destination: &bytes) == noErr else { return nil }
        let n = Int(lengthSize)
        out.reserveCapacity(out.count + total + 16)
        var offset = 0
        while offset + n <= total {
            var length = 0
            for k in 0..<n { length = (length << 8) | Int(bytes[offset + k]) }
            offset += n
            guard length > 0, offset + length <= total else { return nil }
            out.append(contentsOf: startCode)
            out.append(contentsOf: bytes[offset..<(offset + length)])
            offset += length
        }
        return out
    }

    /// The NAL units in an Annex B buffer (without their start codes).
    static func nalUnits(in data: Data) -> [Data] {
        var units: [Data] = []
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            let p = raw.bindMemory(to: UInt8.self)
            let n = p.count
            var i = 0
            var start = -1
            while i + 2 < n {
                if p[i] == 0, p[i + 1] == 0, p[i + 2] == 1 {
                    if start >= 0 {
                        // Zeros before a start code (a 4-byte start code, or trailing_zero_8bits) aren't
                        // part of the previous unit.
                        var end = i
                        while end > start, p[end - 1] == 0 { end -= 1 }
                        units.append(Data(p[start..<end]))
                    }
                    i += 3
                    start = i
                } else {
                    i += 1
                }
            }
            if start >= 0, start < n { units.append(Data(p[start..<n])) }
        }
        return units
    }
}
