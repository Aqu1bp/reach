import Foundation
import CryptoKit
import Security

/// A device's long-term identity: a random 128-bit id (used to derive its relay mailbox) and an
/// X25519 key pair used to authenticate and encrypt signaling.
public struct LocalIdentity: Codable, Sendable {
    public let id: String
    public let privateKey: Data

    public static func generate() -> LocalIdentity {
        LocalIdentity(id: randomHex(bytes: 16),
                      privateKey: Curve25519.KeyAgreement.PrivateKey().rawRepresentation)
    }

    public var publicKey: Data {
        (try? Curve25519.KeyAgreement.PrivateKey(rawRepresentation: privateKey))?.publicKey.rawRepresentation ?? Data()
    }

    var agreementKey: Curve25519.KeyAgreement.PrivateKey {
        get throws { try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: privateKey) }
    }

    /// Short human-comparable fingerprint of the public key, e.g. "7F3A-91C2".
    public var fingerprint: String { Self.fingerprint(of: publicKey) }

    public static func fingerprint(of publicKey: Data) -> String {
        let digest = SHA256.hash(data: publicKey).prefix(4).map { String(format: "%02X", $0) }.joined()
        return digest.prefix(4) + "-" + digest.suffix(4)
    }
}

/// Persistent storage for small secrets.
public protocol SecretStore: AnyObject, Sendable {
    func load(_ key: String) -> Data?
    func save(_ key: String, _ data: Data) throws
    func delete(_ key: String)
}

/// Generic-password Keychain store.
public final class KeychainStore: SecretStore, @unchecked Sendable {
    private let service: String

    public init(service: String = Bundle.main.bundleIdentifier ?? "reach") {
        self.service = service
    }

    public func load(_ key: String) -> Data? {
        var query = baseQuery(key)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess else { return nil }
        return out as? Data
    }

    public func save(_ key: String, _ data: Data) throws {
        let query = baseQuery(key)
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var add = query
            add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            let s = SecItemAdd(add as CFDictionary, nil)
            guard s == errSecSuccess else { throw ReachError.storage("Keychain add failed (\(s))") }
        } else if status != errSecSuccess {
            throw ReachError.storage("Keychain update failed (\(status))")
        }
    }

    public func delete(_ key: String) {
        SecItemDelete(baseQuery(key) as CFDictionary)
    }

    private func baseQuery(_ key: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: key]
    }
}

/// File-backed store (0600 permissions). Used by the CLI probe and tests.
public final class FileSecretStore: SecretStore, @unchecked Sendable {
    private let directory: URL
    private let lock = NSLock()

    public init(directory: URL) {
        self.directory = directory
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
    }

    public func load(_ key: String) -> Data? {
        lock.withLock { try? Data(contentsOf: url(key)) }
    }

    public func save(_ key: String, _ data: Data) throws {
        try lock.withLock {
            try data.write(to: url(key), options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url(key).path)
        }
    }

    public func delete(_ key: String) {
        lock.withLock { try? FileManager.default.removeItem(at: url(key)) }
    }

    private func url(_ key: String) -> URL { directory.appendingPathComponent(key) }
}

extension LocalIdentity {
    /// Loads the identity stored under `key`, creating and persisting a new one on first use.
    public static func loadOrCreate(in store: SecretStore, key: String) throws -> LocalIdentity {
        if let data = store.load(key), let id = try? JSONDecoder().decode(LocalIdentity.self, from: data) {
            return id
        }
        let id = LocalIdentity.generate()
        try store.save(key, JSONEncoder().encode(id))
        return id
    }
}

public enum ReachError: Error, LocalizedError, Equatable {
    case storage(String)
    case crypto(String)
    case invalidPairingCode
    case pairingExpired
    case pairingRejected(String)
    case timeout(String)
    case relayUnavailable
    case unknownPeer
    case webrtc(String)
    case closed

    public var errorDescription: String? {
        switch self {
        case .storage(let s): return "Storage error: \(s)"
        case .crypto(let s): return "Security error: \(s)"
        case .invalidPairingCode: return "That isn't a valid Reach pairing code."
        case .pairingExpired: return "This pairing code has expired. Generate a new one on your Mac."
        case .pairingRejected(let s): return "Your Mac declined pairing: \(s)"
        case .timeout(let s): return s
        case .relayUnavailable: return "Couldn't reach the internet relays. Check your connection."
        case .unknownPeer: return "This device isn't paired with that Mac anymore."
        case .webrtc(let s): return "Connection error: \(s)"
        case .closed: return "The connection was closed."
        }
    }
}

func randomHex(bytes: Int) -> String {
    randomData(bytes).map { String(format: "%02x", $0) }.joined()
}

/// Ids, pairing secrets and nonces all come from here; a failing system RNG is not something to
/// carry on past.
func randomData(_ count: Int) -> Data {
    var buf = [UInt8](repeating: 0, count: count)
    guard SecRandomCopyBytes(kSecRandomDefault, count, &buf) == errSecSuccess else {
        fatalError("SecRandomCopyBytes failed")
    }
    return Data(buf)
}

extension Data {
    var base64URL: String {
        base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }

    init?(base64URL: String) {
        var s = base64URL.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while s.count % 4 != 0 { s += "=" }
        self.init(base64Encoded: s)
    }
}
