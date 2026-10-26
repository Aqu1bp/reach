import Foundation
import CryptoKit
import ReachProtocol

/// Everything the iPhone needs to find and authenticate a Mac, shown on the Mac as a QR code.
///
/// The code embeds the Mac's public key (so the iPhone can verify every later message really comes
/// from that Mac) and a single-use secret (so only someone who can see the Mac's screen can pair).
public struct PairingCode: Codable, Hashable, Sendable {
    public var hostID: String
    public var hostPublicKey: Data
    public var secret: Data
    public var hostName: String

    public init(hostID: String, hostPublicKey: Data, secret: Data, hostName: String) {
        self.hostID = hostID; self.hostPublicKey = hostPublicKey; self.secret = secret; self.hostName = hostName
    }

    public static let scheme = "reach"

    /// `reach://pair?v=1&h=<id>&k=<pubkey>&s=<secret>&n=<name>` — scanning it with the iPhone camera
    /// opens the app directly.
    public var url: URL {
        var c = URLComponents()
        c.scheme = Self.scheme
        c.host = "pair"
        c.queryItems = [
            URLQueryItem(name: "v", value: "1"),
            URLQueryItem(name: "h", value: hostID),
            URLQueryItem(name: "k", value: hostPublicKey.base64URL),
            URLQueryItem(name: "s", value: secret.base64URL),
            URLQueryItem(name: "n", value: hostName),
        ]
        return c.url!
    }

    public init(string: String) throws {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let c = URLComponents(string: trimmed), c.scheme == Self.scheme, c.host == "pair" else {
            throw ReachError.invalidPairingCode
        }
        let q = Dictionary((c.queryItems ?? []).map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { a, _ in a })
        guard q["v"] == "1", let h = q["h"], h.count == 32,
              let k = q["k"].flatMap(Data.init(base64URL:)), k.count == 32,
              let s = q["s"].flatMap(Data.init(base64URL:)), s.count >= 16 else {
            throw ReachError.invalidPairingCode
        }
        self.init(hostID: h, hostPublicKey: k, secret: s, hostName: q["n"] ?? "Mac")
    }

    /// Proof that the requester saw this code: HMAC(secret, clientID ‖ clientPublicKey).
    func proof(clientID: String, clientPublicKey: Data) -> Data {
        Self.proof(secret: secret, clientID: clientID, clientPublicKey: clientPublicKey)
    }

    static func proof(secret: Data, clientID: String, clientPublicKey: Data) -> Data {
        Data(HMAC<SHA256>.authenticationCode(for: proofMessage(clientID, clientPublicKey), using: SymmetricKey(data: secret)))
    }

    /// Checks a proof in constant time.
    static func isValidProof(_ proof: Data, secret: Data, clientID: String, clientPublicKey: Data) -> Bool {
        HMAC<SHA256>.isValidAuthenticationCode(proof, authenticating: proofMessage(clientID, clientPublicKey),
                                               using: SymmetricKey(data: secret))
    }

    private static func proofMessage(_ clientID: String, _ clientPublicKey: Data) -> Data {
        var msg = Data(clientID.utf8)
        msg.append(clientPublicKey)
        return msg
    }
}

/// A Mac this iPhone has paired with.
public struct PairedHost: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var publicKey: Data
    public var name: String
    public var info: HostInfo?
    public var iceServers: [IceServerConfig]
    public var pairedAt: Date
    public var lastConnectedAt: Date?

    public init(id: String, publicKey: Data, name: String, info: HostInfo?, iceServers: [IceServerConfig],
                pairedAt: Date, lastConnectedAt: Date? = nil) {
        self.id = id; self.publicKey = publicKey; self.name = name; self.info = info
        self.iceServers = iceServers; self.pairedAt = pairedAt; self.lastConnectedAt = lastConnectedAt
    }

    public var fingerprint: String { LocalIdentity.fingerprint(of: publicKey) }
}

/// An iPhone this Mac trusts.
public struct TrustedClient: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var publicKey: Data
    public var name: String
    public var deviceModel: String
    public var pairedAt: Date
    public var lastConnectedAt: Date?

    public init(id: String, publicKey: Data, name: String, deviceModel: String, pairedAt: Date, lastConnectedAt: Date? = nil) {
        self.id = id; self.publicKey = publicKey; self.name = name; self.deviceModel = deviceModel
        self.pairedAt = pairedAt; self.lastConnectedAt = lastConnectedAt
    }

    public var fingerprint: String { LocalIdentity.fingerprint(of: publicKey) }
}

/// STUN/TURN server description (mirrors `RTCIceServer`).
public struct IceServerConfig: Codable, Hashable, Sendable {
    public var urls: [String]
    public var username: String?
    public var credential: String?

    public init(urls: [String], username: String? = nil, credential: String? = nil) {
        self.urls = urls; self.username = username; self.credential = credential
    }

    /// Public STUN servers used to discover each side's public address for hole punching.
    public static let defaultSTUN: [IceServerConfig] = [
        IceServerConfig(urls: ["stun:stun.l.google.com:19302", "stun:stun1.l.google.com:19302"]),
        IceServerConfig(urls: ["stun:stun.cloudflare.com:3478"]),
    ]

    /// A TURN server (a relay for when no direct path exists), as opposed to STUN only.
    public var isRelay: Bool {
        urls.contains { $0.hasPrefix("turn:") || $0.hasPrefix("turns:") }
    }
}

/// A `turn:` / `turns:` URL (RFC 7065): `turn:host[:port][?transport=udp|tcp]`.
///
/// WebRTC refuses to create a peer connection at all if any ICE server URL is malformed (or a TURN
/// server lacks a username and password), so TURN settings are checked with this before use and
/// stored in its canonical form.
public struct TurnURL: Hashable, Sendable {
    /// `turns:` — TURN over TLS.
    public var secure: Bool
    /// Host name, IPv4 address, or IPv6 address in brackets.
    public var host: String
    public var port: Int?
    /// "udp" or "tcp".
    public var transport: String?

    public init?(_ string: String) {
        var rest = Substring(string.trimmingCharacters(in: .whitespacesAndNewlines))
        // Any case is accepted here; WebRTC only takes the canonical lower-case form.
        let scheme = rest.prefix(6).lowercased()
        if scheme == "turns:" {
            secure = true
            rest = rest.dropFirst(6)
        } else if scheme.hasPrefix("turn:") {
            secure = false
            rest = rest.dropFirst(5)
        } else {
            return nil
        }
        // A common slip (WebRTC rejects it): "turn://host".
        if rest.hasPrefix("//") { rest = rest.dropFirst(2) }

        transport = nil
        if let q = rest.firstIndex(of: "?") {
            let query = rest[rest.index(after: q)...].lowercased()
            rest = rest[..<q]
            guard query == "transport=udp" || query == "transport=tcp" else { return nil }
            transport = String(query.dropFirst("transport=".count))
        }

        let portText: Substring?
        if rest.hasPrefix("[") {
            guard let close = rest.firstIndex(of: "]") else { return nil }
            let address = rest[rest.index(after: rest.startIndex)..<close]
            guard !address.isEmpty, address.allSatisfy({ $0.isHexDigit || $0 == ":" || $0 == "." }) else { return nil }
            host = "[\(address.lowercased())]"
            let after = rest[rest.index(after: close)...]
            guard after.isEmpty || after.hasPrefix(":") else { return nil }
            portText = after.isEmpty ? nil : after.dropFirst()
        } else {
            let parts = rest.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
            let name = parts[0]
            guard !name.isEmpty, name.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "-._".contains($0)) }) else {
                return nil
            }
            host = name.lowercased()
            portText = parts.count == 2 ? parts[1] : nil
        }

        port = nil
        if let portText {
            guard !portText.isEmpty, portText.allSatisfy({ $0.isASCII && $0.isNumber }),
                  let p = Int(portText), (1...65535).contains(p) else { return nil }
            port = p
        }
    }

    /// Canonical form, e.g. `turns:relay.example.com:443?transport=tcp`.
    public var string: String {
        var s = (secure ? "turns:" : "turn:") + host
        if let port { s += ":\(port)" }
        if let transport { s += "?transport=\(transport)" }
        return s
    }
}
