import Foundation
import ReachCore
import ReachProtocol

/// Fixed models for UI snapshots.
@MainActor
enum PreviewData {
    static let now = Date()

    static let iPhone = TrustedClient(id: "c1", publicKey: Data(repeating: 0x11, count: 32), name: "Alex's iPhone", deviceModel: "iPhone 16",
                                      pairedAt: now.addingTimeInterval(-86_400 * 12), lastConnectedAt: now.addingTimeInterval(-2 * 3600))
    static let iPad = TrustedClient(id: "c2", publicKey: Data(repeating: 0x22, count: 32), name: "Work iPhone", deviceModel: "iPhone 16e",
                                    pairedAt: now.addingTimeInterval(-86_400 * 40), lastConnectedAt: now.addingTimeInterval(-86_400 * 6))

    static let relayServer = TurnServer(urls: ["turn:relay.example.com:3478", "turns:relay.example.com:443?transport=tcp"],
                                        username: "reach", credential: "correct-horse")

    static func idle() -> AppModel {
        AppModel(preview: PreviewState(pairedDevices: [iPhone, iPad]))
    }

    static func withRelayServer() -> AppModel {
        AppModel(preview: PreviewState(pairedDevices: [iPhone, iPad], turnServer: relayServer))
    }

    static func connected() -> AppModel {
        var connectedPhone = iPhone
        connectedPhone.lastConnectedAt = now
        let session = AppModel.ActiveSession(clientID: iPhone.id, deviceName: iPhone.name, deviceModel: iPhone.deviceModel,
                                             startedAt: now.addingTimeInterval(-12 * 60 - 5), route: .direct, roundTripMs: 23.4)
        return AppModel(preview: PreviewState(session: session, pairedDevices: [connectedPhone, iPad]))
    }

    static func missingPermissions(needsRelaunch: Bool = false) -> AppModel {
        AppModel(preview: PreviewState(pairedDevices: [], screenRecording: false, accessibility: false, needsRelaunch: needsRelaunch))
    }

    static func offline() -> AppModel {
        AppModel(preview: PreviewState(connectivity: .offline, pairedDevices: [iPhone]))
    }

    static func pairing() -> AppModel {
        AppModel(preview: PreviewState(pairing: showingCode()))
    }

    static func paired() -> AppModel {
        AppModel(preview: PreviewState(pairedDevices: [iPhone], pairing: .paired(deviceName: iPhone.name)))
    }

    static func onboarding(screenRecording: Bool, accessibility: Bool, needsRelaunch: Bool = false) -> AppModel {
        AppModel(preview: PreviewState(screenRecording: screenRecording, accessibility: accessibility,
                                       needsRelaunch: needsRelaunch, pairing: showingCode()))
    }

    private static func showingCode() -> PairingSession.State {
        let code = PairingCode(hostID: String(repeating: "a1b2c3d4", count: 4), hostPublicKey: Data((0..<32).map { UInt8($0) }),
                               secret: Data((0..<16).map { UInt8($0 &* 7) }), hostName: "Alex's MacBook Pro")
        let link = code.url.absoluteString
        guard let qr = QRCodeRenderer.image(for: link) else { return .idle }
        return .showing(.init(link: link, expiresAt: now.addingTimeInterval(PairingSession.lifetime - 18), qr: qr))
    }
}
