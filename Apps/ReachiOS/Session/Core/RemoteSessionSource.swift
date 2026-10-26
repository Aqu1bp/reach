import Foundation
import CoreVideo
import ReachCore
import ReachProtocol

/// What the session UI needs from a connection to a Mac. `ClientSession` conforms directly; the demo
/// source synthesizes a desktop locally so the UI can be developed without a host.
///
/// Threading contract (mirrors `ClientSession`):
/// * `onState`, `onMessage` — main queue.
/// * `onCursor` — any thread (network thread for the real session).
/// * `onVideoFrame` — any thread (WebRTC's decode thread for the real session).
/// * Every method is safe to call from any thread.
protocol RemoteSessionSource: AnyObject {
    var state: ClientSession.State { get }
    var onState: ((ClientSession.State) -> Void)? { get set }
    var onMessage: ((HostMessage) -> Void)? { get set }
    var onCursor: ((CursorPacket) -> Void)? { get set }
    var onVideoFrame: ((CVPixelBuffer, Int64) -> Void)? { get set }
    var controlRoundTripMs: Double? { get }

    func send(_ message: ClientMessage)
    @discardableResult func sendPointer(x: Float, y: Float) -> UInt32
    func nextSequence() -> UInt32
    func setQuality(_ q: QualityPreference)
    func setViewport(_ v: ViewportHint)
    func stats(completion: @escaping (ConnectionStats?) -> Void)
    func restartConnection()
    func close()
}

extension ClientSession: RemoteSessionSource {}
