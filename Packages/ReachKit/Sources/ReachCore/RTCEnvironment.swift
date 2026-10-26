import Foundation
import VideoToolbox
import WebRTC

/// Process-wide WebRTC setup.
final class RTCEnvironment: @unchecked Sendable {
    static let shared = RTCEnvironment()

    let factory: RTCPeerConnectionFactory

    private init() {
        RTCInitializeSSL()
        #if os(iOS)
        // Reach sends no audio through WebRTC; keep it from activating/reconfiguring the app's audio
        // session (which would interrupt whatever the user is listening to).
        let audio = RTCAudioSession.sharedInstance()
        audio.useManualAudio = true
        audio.isAudioEnabled = false
        #endif
        (LegacyFieldTrials.self as FieldTrialInstalling.Type).install(Self.fieldTrials)
        #if DEBUG
        RTCSetMinDebugLogLevel(.warning)
        #else
        RTCSetMinDebugLogLevel(.error)
        #endif
        factory = RTCPeerConnectionFactory(encoderFactory: ScreenEncoderFactory(),
                                           decoderFactory: ScreenDecoderFactory())
    }

    func configuration(iceServers: [IceServerConfig], policy: RTCIceTransportPolicy = .all) -> RTCConfiguration {
        let c = RTCConfiguration()
        c.sdpSemantics = .unifiedPlan
        c.iceServers = iceServers.map {
            RTCIceServer(urlStrings: $0.urls, username: $0.username, credential: $0.credential)
        }
        c.iceTransportPolicy = policy
        c.bundlePolicy = .maxBundle
        c.rtcpMuxPolicy = .require
        // Keep gathering so a Wi-Fi ⇄ cellular switch produces fresh candidates for an ICE restart.
        c.continualGatheringPolicy = .gatherContinually
        c.tcpCandidatePolicy = .enabled
        c.keyType = .ECDSA
        // Notice a dead path quickly (default is ~2.5 s receiving / 5 s unwritable).
        c.iceConnectionReceivingTimeout = 2000
        c.iceBackupCandidatePairPingInterval = 2000
        c.iceUnwritableTimeout = 3000
        c.iceInactiveTimeout = 5000
        // Allow every interface (Wi-Fi, cellular, IPv6) — the best pair wins.
        c.candidateNetworkPolicy = .all
        c.disableLinkLocalNetworks = false
        c.maxIPv6Networks = 5
        c.enableDscp = true
        return c
    }

    /// Remote desktop wants frames on screen the moment they decode. A zero playout delay puts the
    /// receiver in WebRTC's low-latency rendering mode (no smoothing jitter buffer target / render
    /// delay), the same mode cloud-gaming clients use.
    static var fieldTrials: [String: String] {
        var trials = ["WebRTC-ForcePlayoutDelay": "min_ms:0,max_ms:0"]
        if let env = ProcessInfo.processInfo.environment["REACH_FIELD_TRIALS"] {
            // Format: "Name1=value1;Name2=value2" (empty value removes a default).
            for pair in env.split(separator: ";") {
                let kv = pair.split(separator: "=", maxSplits: 1).map(String.init)
                if kv.count == 2 { trials[kv[0]] = kv[1].isEmpty ? nil : kv[1] }
            }
        }
        return trials
    }

    static let emptyConstraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
}

/// The codecs offered for the screen stream, best first.
///
/// HEVC needs roughly a third fewer bits than H.264 for the same picture, and holds detail much
/// better during fast motion on a slow link, so it's preferred whenever both ends decode/encode it in
/// hardware. H.264 stays as the fallback (and for iPhones running an older Reach).
///
/// H.264 is advertised with level 5.2 so full-resolution Retina frames (up to 4096×2304) are
/// allowed; WebRTC's defaults advertise level 3.1, which caps frames at 1280×720.
enum ScreenCodecs {
    static let h265Name = "H265"

    static let hevc = RTCVideoCodecInfo(name: h265Name, parameters: [
        "profile-id": "1",
        "tier-flag": "0",
        "level-id": "156",
        "tx-mode": "SRST",
    ])
    static let constrainedHigh = RTCVideoCodecInfo(name: kRTCVideoCodecH264Name, parameters: [
        "profile-level-id": "640c34",
        "level-asymmetry-allowed": "1",
        "packetization-mode": "1",
    ])
    static let constrainedBaseline = RTCVideoCodecInfo(name: kRTCVideoCodecH264Name, parameters: [
        "profile-level-id": "42e034",
        "level-asymmetry-allowed": "1",
        "packetization-mode": "1",
    ])
    static let h264 = [constrainedHigh, constrainedBaseline]

    /// `REACH_VIDEO_CODEC=h264` turns HEVC off (for comparisons), `=hevc` offers it even without a
    /// hardware decoder (the simulator); `REACH_H264_ENCODER=webrtc` swaps in WebRTC's own H.264 encoder.
    private static let environment = ProcessInfo.processInfo.environment
    private static let hevcAllowed = environment["REACH_VIDEO_CODEC"]?.lowercased() != "h264"
    private static let hevcForced = environment["REACH_VIDEO_CODEC"]?.lowercased() == "hevc"
    static let useWebRTCH264Encoder = environment["REACH_H264_ENCODER"]?.lowercased() == "webrtc"

    /// Only the Mac sends video; probing the encoder on iOS would be wasted work.
    static let hardwareHEVCEncode: Bool = {
        #if os(macOS)
        let spec = [kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder: kCFBooleanTrue] as CFDictionary
        var session: VTCompressionSession?
        let status = VTCompressionSessionCreate(allocator: nil, width: 1280, height: 720, codecType: kCMVideoCodecType_HEVC,
                                                encoderSpecification: spec, imageBufferAttributes: nil, compressedDataAllocator: nil,
                                                outputCallback: nil, refcon: nil, compressionSessionOut: &session)
        if let session { VTCompressionSessionInvalidate(session) }
        return status == noErr
        #else
        return false
        #endif
    }()
    static let hardwareHEVCDecode = VTIsHardwareDecodeSupported(kCMVideoCodecType_HEVC)

    static var encoderCodecs: [RTCVideoCodecInfo] { (hevcAllowed && hardwareHEVCEncode ? [hevc] : []) + h264 }
    static var decoderCodecs: [RTCVideoCodecInfo] { (hevcForced || (hevcAllowed && hardwareHEVCDecode) ? [hevc] : []) + h264 }
}

final class ScreenEncoderFactory: NSObject, RTCVideoEncoderFactory {
    func createEncoder(_ info: RTCVideoCodecInfo) -> RTCVideoEncoder? {
        if info.name == ScreenCodecs.h265Name { return ScreenVideoEncoder(codec: .hevc) }
        if ScreenCodecs.useWebRTCH264Encoder { return RTCVideoEncoderH264(codecInfo: info) }
        let baseline = (info.parameters["profile-level-id"] ?? "").hasPrefix("42")
        return ScreenVideoEncoder(codec: .h264(baseline: baseline))
    }

    func supportedCodecs() -> [RTCVideoCodecInfo] { ScreenCodecs.encoderCodecs }
}

final class ScreenDecoderFactory: NSObject, RTCVideoDecoderFactory {
    func createDecoder(_ info: RTCVideoCodecInfo) -> RTCVideoDecoder? {
        info.name == ScreenCodecs.h265Name ? HEVCVideoDecoder() : RTCVideoDecoderH264()
    }

    func supportedCodecs() -> [RTCVideoCodecInfo] { ScreenCodecs.decoderCodecs }
}

/// `RTCInitFieldTrialDictionary` is marked deprecated in favour of a factory-builder API that this
/// prebuilt framework doesn't expose; calling it through a protocol keeps the build warning-free.
private protocol FieldTrialInstalling { static func install(_ trials: [String: String]) }
private enum LegacyFieldTrials: FieldTrialInstalling {
    @available(*, deprecated)
    static func install(_ trials: [String: String]) { RTCInitFieldTrialDictionary(trials) }
}
