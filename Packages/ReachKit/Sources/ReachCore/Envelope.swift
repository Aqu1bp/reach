import Foundation
import Compression
import CryptoKit
import ReachProtocol

/// The only thing that ever touches the public relays. Relays see who-talks-to-whom mailboxes and
/// message sizes, nothing else: payloads are ChaCha20-Poly1305 encrypted with a key derived from the
/// two devices' static X25519 keys, and authenticated, so a relay (or anyone who learns a mailbox
/// name) can neither read nor forge signaling — which in turn pins the DTLS fingerprints in the SDP
/// and makes the WebRTC media/data path end-to-end authenticated.
struct Envelope: Codable {
    var v: Int
    /// Sender id.
    var f: String
    /// Recipient id.
    var t: String
    /// Sender public key; only present on pairing requests (the recipient doesn't know it yet).
    var k: String?
    /// 12-byte nonce.
    var n: String
    /// Ciphertext + 16-byte tag.
    var c: String
}

/// Signaling payload carried inside an envelope.
struct SignalMessage: Codable {
    /// Random id for replay protection and de-duplication across redundant relays.
    var id: String
    /// Sender wall-clock time (seconds since 1970).
    var ts: Double
    var body: SignalBody
}

enum SignalBody: Codable {
    case pairRequest(PairRequest)
    case pairResult(PairResult)
    case probe
    case probeAck(HostStatus)
    case offer(sid: String, sdp: String, restart: Bool)
    case answer(sid: String, sdp: String)
    case candidates(sid: String, list: [IceCandidateInfo])
    case bye(sid: String, reason: String)
}

struct PairRequest: Codable {
    var name: String
    var model: String
    var proof: Data
}

struct PairResult: Codable {
    var accepted: Bool
    var reason: String?
    var hostName: String
    var info: HostInfo?
    var iceServers: [IceServerConfig]
}

struct HostStatus: Codable {
    var info: HostInfo
    var connectedClientName: String?
    var iceServers: [IceServerConfig]
}

struct IceCandidateInfo: Codable, Hashable {
    var sdp: String
    var mid: String?
    var index: Int32
}

enum EnvelopeCrypto {
    static let maxClockSkew: TimeInterval = 300
    /// Signaling is a few KB (ntfy itself caps a message at 4 KB). These bound what anyone who learns
    /// a mailbox name can make a device allocate: the envelope as received, and the message inflated.
    static let maxEnvelopeBytes = 64 * 1024
    static let maxMessageBytes = 256 * 1024

    static func key(local: LocalIdentity, remoteID: String, remotePublicKey: Data) throws -> SymmetricKey {
        let remote = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: remotePublicKey)
        let secret = try local.agreementKey.sharedSecretFromKeyAgreement(with: remote)
        let ids = [local.id, remoteID].sorted().joined(separator: "|")
        return secret.hkdfDerivedSymmetricKey(using: SHA256.self, salt: Data("reach.signal.v1".utf8),
                                              sharedInfo: Data(ids.utf8), outputByteCount: 32)
    }

    static func seal(_ message: SignalMessage, from local: LocalIdentity, to remoteID: String,
                     remotePublicKey: Data, includeSenderKey: Bool) throws -> Data {
        let key = try key(local: local, remoteID: remoteID, remotePublicKey: remotePublicKey)
        let plain = try JSONEncoder().encode(message)
        let compressed = try (plain as NSData).compressed(using: .zlib) as Data
        let nonce = ChaChaPoly.Nonce()
        let aad = Data("\(local.id)>\(remoteID)".utf8)
        let box = try ChaChaPoly.seal(compressed, using: key, nonce: nonce, authenticating: aad)
        let env = Envelope(v: 1, f: local.id, t: remoteID,
                           k: includeSenderKey ? local.publicKey.base64URL : nil,
                           n: Data(nonce).base64URL, c: (box.ciphertext + box.tag).base64URL)
        return try JSONEncoder().encode(env)
    }

    /// Decodes the outer envelope and checks its shape (nothing is authenticated yet).
    static func peek(_ data: Data) -> Envelope? {
        guard data.count <= maxEnvelopeBytes,
              let env = try? JSONDecoder().decode(Envelope.self, from: data), env.v == 1,
              isDeviceID(env.f), isDeviceID(env.t), env.n.count == 16,
              env.k.map({ $0.count == 43 }) ?? true else { return nil }
        return env
    }

    /// A device id: 32 lower-case hex characters (`LocalIdentity.generate`).
    static func isDeviceID(_ s: String) -> Bool {
        s.utf8.count == 32 && s.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }

    static func open(_ env: Envelope, local: LocalIdentity, remotePublicKey: Data) throws -> SignalMessage {
        guard env.t == local.id,
              let nonceData = Data(base64URL: env.n), let combined = Data(base64URL: env.c), combined.count > 16 else {
            throw ReachError.crypto("malformed envelope")
        }
        let key = try key(local: local, remoteID: env.f, remotePublicKey: remotePublicKey)
        let box = try ChaChaPoly.SealedBox(nonce: ChaChaPoly.Nonce(data: nonceData),
                                           ciphertext: combined.dropLast(16), tag: combined.suffix(16))
        let aad = Data("\(env.f)>\(local.id)".utf8)
        let compressed = try ChaChaPoly.open(box, using: key, authenticating: aad)
        let plain = try inflate(compressed, limit: maxMessageBytes)
        let msg = try JSONDecoder().decode(SignalMessage.self, from: plain)
        guard abs(msg.ts - Date().timeIntervalSince1970) < maxClockSkew else {
            throw ReachError.crypto("stale or future-dated message")
        }
        return msg
    }

    /// zlib inflate that gives up past `limit` bytes instead of expanding whatever it's handed.
    static func inflate(_ data: Data, limit: Int) throws -> Data {
        var input = data
        let filter = try InputFilter(.decompress, using: .zlib) { (length: Int) -> Data? in
            let chunk = input.prefix(length)
            input.removeFirst(chunk.count)
            return chunk
        }
        var output = Data()
        while let page = try filter.readData(ofLength: 16 * 1024), !page.isEmpty {
            output.append(page)
            guard output.count <= limit else { throw ReachError.crypto("signaling message too large") }
        }
        return output
    }

    static func makeMessage(_ body: SignalBody) -> SignalMessage {
        SignalMessage(id: randomHex(bytes: 8), ts: Date().timeIntervalSince1970, body: body)
    }
}

/// Remembers recently seen message ids so duplicate deliveries (we publish to several relays at
/// once) and replays are dropped.
final class ReplayFilter {
    private var seen: [String: Date] = [:]

    /// Returns true the first time an id is seen.
    func admit(_ id: String) -> Bool {
        let now = Date()
        if seen.count > 512 {
            seen = seen.filter { now.timeIntervalSince($0.value) < EnvelopeCrypto.maxClockSkew * 2 }
        }
        if seen[id] != nil { return false }
        seen[id] = now
        return true
    }
}

/// The relay "topic" a device listens on. Derived from its secret-ish id so it isn't guessable from
/// anything public.
func mailbox(for id: String) -> String {
    let digest = SHA256.hash(data: Data("reach.mailbox.v1:\(id)".utf8))
    return "reach_" + digest.prefix(15).map { String(format: "%02x", $0) }.joined()
}
