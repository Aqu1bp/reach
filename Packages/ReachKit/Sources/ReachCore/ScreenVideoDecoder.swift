import Foundation
import CoreMedia
import VideoToolbox
import WebRTC

/// Hardware HEVC decoder for WebRTC (this WebRTC build only ships an H.264 one).
///
/// Decodes synchronously on WebRTC's decode thread: a hardware decode takes a few milliseconds, and
/// handing the frame straight back keeps it off any extra queue on its way to the screen.
final class HEVCVideoDecoder: NSObject, RTCVideoDecoder {
    private var callback: RTCVideoDecoderCallback?
    private var session: VTDecompressionSession?
    private var format: CMVideoFormatDescription?
    private var parameterSets: [Data] = []
    private var loggedSize: (Int32, Int32) = (0, 0)

    deinit { destroySession() }

    func setCallback(_ callback: @escaping RTCVideoDecoderCallback) {
        self.callback = callback
    }

    func startDecode(withNumberOfCores numberOfCores: Int32) -> Int { Codes.ok }

    func release() -> Int {
        destroySession()
        format = nil
        parameterSets = []
        return Codes.ok
    }

    func implementationName() -> String { "VideoToolbox HEVC" }

    #if DEBUG
    /// Test hook: `REACH_DEBUG_DECODE_FAILURES=N` fails every Nth frame, to exercise key frame recovery.
    private static let failEvery = Int(ProcessInfo.processInfo.environment["REACH_DEBUG_DECODE_FAILURES"] ?? "") ?? 0
    private var decodeCount = 0
    #endif

    func decode(_ encodedImage: RTCEncodedImage, missingFrames: Bool, codecSpecificInfo info: (any RTCCodecSpecificInfo)?,
                renderTimeMs: Int64) -> Int {
        #if DEBUG
        decodeCount += 1
        if Self.failEvery > 0, decodeCount % Self.failEvery == 0 {
            // Like real corruption: the session's state is lost until the next key frame.
            ReachLog.info("video", "debug: failing decode \(decodeCount)")
            destroySession()
            format = nil
            parameterSets = []
            return Codes.error
        }
        #endif
        var vps: Data?, sps: Data?, pps: Data?
        var payload = Data()
        for unit in AnnexB.nalUnits(in: encodedImage.buffer) {
            guard let header = unit.first else { continue }
            switch (header >> 1) & 0x3F {
            case 32: vps = unit
            case 33: sps = unit
            case 34: pps = unit
            default:
                var length = UInt32(unit.count).bigEndian
                withUnsafeBytes(of: &length) { payload.append(contentsOf: $0) }
                payload.append(unit)
            }
        }
        if let vps, let sps, let pps, [vps, sps, pps] != parameterSets {
            guard updateFormat(vps: vps, sps: sps, pps: pps) else { return Codes.error }
        }
        // Until a key frame arrives with its parameter sets there's nothing to decode against;
        // an error makes WebRTC ask the sender for one.
        guard let session, let format else { return Codes.error }
        guard !payload.isEmpty else { return Codes.ok }

        guard let sample = Self.makeSample(payload, format: format) else { return Codes.error }
        let rtpTimestamp = Int32(bitPattern: encodedImage.timeStamp)
        var failed = false
        let status = VTDecompressionSessionDecodeFrame(session, sampleBuffer: sample, flags: [], infoFlagsOut: nil) { [weak self] status, _, image, _, _ in
            guard status == noErr, let image else {
                failed = true
                return
            }
            let frame = RTCVideoFrame(buffer: RTCCVPixelBuffer(pixelBuffer: image), rotation: ._0, timeStampNs: renderTimeMs * 1_000_000)
            frame.timeStamp = rtpTimestamp
            self?.callback?(frame)
        }
        if status == kVTInvalidSessionErr {
            // e.g. the app was backgrounded: rebuild the session; the next key frame resumes the picture.
            ReachLog.info("video", "decoder session invalidated; recreating")
            destroySession()
            makeSession()
            return Codes.error
        }
        if status != noErr || failed {
            ReachLog.error("video", "HEVC decode failed: \(status)")
            return Codes.error
        }
        return Codes.ok
    }

    // MARK: Session

    private func updateFormat(vps: Data, sps: Data, pps: Data) -> Bool {
        var newFormat: CMFormatDescription?
        let status = vps.withUnsafeBytes { v in
            sps.withUnsafeBytes { s in
                pps.withUnsafeBytes { p in
                    let pointers = [v, s, p].map { $0.bindMemory(to: UInt8.self).baseAddress! }
                    let sizes = [vps.count, sps.count, pps.count]
                    return CMVideoFormatDescriptionCreateFromHEVCParameterSets(allocator: nil, parameterSetCount: 3,
                                                                               parameterSetPointers: pointers, parameterSetSizes: sizes,
                                                                               nalUnitHeaderLength: 4, extensions: nil,
                                                                               formatDescriptionOut: &newFormat)
                }
            }
        }
        guard status == noErr, let newFormat else {
            ReachLog.error("video", "bad HEVC parameter sets: \(status)")
            return false
        }
        parameterSets = [vps, sps, pps]
        format = newFormat
        if let session, VTDecompressionSessionCanAcceptFormatDescription(session, formatDescription: newFormat) { return true }
        destroySession()
        return makeSession()
    }

    @discardableResult
    private func makeSession() -> Bool {
        guard let format else { return false }
        var spec: [CFString: Any] = [:]
        #if os(macOS)
        spec[kVTVideoDecoderSpecification_EnableHardwareAcceleratedVideoDecoder] = true
        #endif
        // NV12 in the stream's own (video) range: no conversion pass, and the renderer samples it directly.
        let attributes: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
            kCVPixelBufferMetalCompatibilityKey: true,
        ]
        var session: VTDecompressionSession?
        let status = VTDecompressionSessionCreate(allocator: nil, formatDescription: format, decoderSpecification: spec as CFDictionary,
                                                  imageBufferAttributes: attributes as CFDictionary, outputCallback: nil,
                                                  decompressionSessionOut: &session)
        guard status == noErr, let session else {
            ReachLog.error("video", "couldn't create HEVC decoder: \(status)")
            return false
        }
        VTSessionSetProperty(session, key: kVTDecompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        self.session = session
        let size = CMVideoFormatDescriptionGetDimensions(format)
        if (size.width, size.height) != loggedSize {
            loggedSize = (size.width, size.height)
            ReachLog.info("video", "decoder: VideoToolbox HEVC \(size.width)×\(size.height)")
        }
        return true
    }

    private func destroySession() {
        guard let session else { return }
        VTDecompressionSessionInvalidate(session)
        self.session = nil
    }

    private static func makeSample(_ payload: Data, format: CMVideoFormatDescription) -> CMSampleBuffer? {
        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: payload.count, blockAllocator: nil,
                                                 customBlockSource: nil, offsetToData: 0, dataLength: payload.count,
                                                 flags: kCMBlockBufferAssureMemoryNowFlag, blockBufferOut: &block) == noErr,
              let block else { return nil }
        let copied = payload.withUnsafeBytes {
            CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: payload.count)
        }
        guard copied == noErr else { return nil }
        var sample: CMSampleBuffer?
        var size = payload.count
        guard CMSampleBufferCreateReady(allocator: nil, dataBuffer: block, formatDescription: format, sampleCount: 1,
                                        sampleTimingEntryCount: 0, sampleTimingArray: nil, sampleSizeEntryCount: 1,
                                        sampleSizeArray: &size, sampleBufferOut: &sample) == noErr else { return nil }
        return sample
    }

    private enum Codes {
        static let ok = 0
        static let error = -1
    }
}
