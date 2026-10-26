// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "ReachKit",
    platforms: [.iOS(.v18), .macOS(.v14)],
    products: [
        .library(name: "ReachProtocol", targets: ["ReachProtocol"]),
        .library(name: "ReachCore", targets: ["ReachCore"]),
        .executable(name: "reach-probe", targets: ["reach-probe"]),
    ],
    targets: [
        // Prebuilt Google WebRTC (M154) for iOS + macOS. Provides ICE/STUN/TURN NAT
        // traversal, DTLS-SRTP, congestion control and VideoToolbox H.264.
        .binaryTarget(
            name: "WebRTC",
            url: "https://github.com/stasel/WebRTC/releases/download/154.0.0/WebRTC-M154.xcframework.zip",
            checksum: "a2bcdda93578c82452ceb6e49d54a2746e1bcb4caf7c2fa601ffac8028b58c16"
        ),
        // Pure-Swift wire protocol shared by host and client. No WebRTC dependency.
        .target(name: "ReachProtocol"),
        // Identity, pairing crypto, signaling relays and the WebRTC session layer.
        .target(name: "ReachCore", dependencies: ["ReachProtocol", "WebRTC"]),
        // Headless test client / diagnostics tool used for end-to-end verification.
        .executableTarget(name: "reach-probe", dependencies: ["ReachCore", "ReachProtocol"]),
        .testTarget(name: "ReachKitTests", dependencies: ["ReachProtocol", "ReachCore"]),
    ],
    swiftLanguageModes: [.v5]
)
