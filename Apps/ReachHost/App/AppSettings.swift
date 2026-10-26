import Foundation
import ReachCore
import ReachProtocol

/// Persistent user preferences (UserDefaults; the one secret, the TURN password, in the keychain).
struct AppSettings {
    private let defaults: UserDefaults
    private let secrets: SecretStore

    /// Keychain service for the host's identity and the TURN password.
    static let keychainService = Bundle.main.bundleIdentifier ?? "reach.host"

    init(defaults: UserDefaults = .standard, secrets: SecretStore = KeychainStore(service: AppSettings.keychainService)) {
        self.defaults = defaults
        self.secrets = secrets
        defaults.register(defaults: [Key.keepAwake: true])
    }

    private enum Key {
        static let keepAwake = "keepAwake"
        static let completedOnboarding = "completedOnboarding"
        static let preferredDisplay = "preferredDisplayID"
        static let turnURLs = "turnURLs"
        static let turnUsername = "turnUsername"
        /// Keychain account.
        static let turnCredential = "turn-credential"
    }

    /// "Keep Mac awake for remote access". On by default: a sleeping Mac can't be reached.
    var keepAwake: Bool {
        get { defaults.bool(forKey: Key.keepAwake) }
        nonmutating set { defaults.set(newValue, forKey: Key.keepAwake) }
    }

    var hasCompletedOnboarding: Bool {
        get { defaults.bool(forKey: Key.completedOnboarding) }
        nonmutating set { defaults.set(newValue, forKey: Key.completedOnboarding) }
    }

    /// The display the iPhone last chose, reused for the next session while it's connected.
    var preferredDisplayID: DisplayID? {
        get { (defaults.object(forKey: Key.preferredDisplay) as? NSNumber).map { DisplayID($0.uint32Value) } }
        nonmutating set { defaults.set(newValue.map { NSNumber(value: $0) }, forKey: Key.preferredDisplay) }
    }

    /// The relay server set in settings, if any. Re-checked on load, since a malformed entry would
    /// stop every connection; the keychain is only read when one is set.
    var turnServer: TurnServer? {
        guard let urls = defaults.stringArray(forKey: Key.turnURLs), !urls.isEmpty,
              let data = secrets.load(Key.turnCredential), let credential = String(data: data, encoding: .utf8),
              case .success(let server) = TurnServer.parse(urls: urls.joined(separator: " "),
                                                           username: defaults.string(forKey: Key.turnUsername) ?? "",
                                                           credential: credential) else { return nil }
        return server
    }

    /// Saves the relay server (`nil` removes it). Throws if the password can't be stored, leaving the
    /// previous setting in place.
    func setTurnServer(_ server: TurnServer?) throws {
        guard let server else {
            defaults.removeObject(forKey: Key.turnURLs)
            defaults.removeObject(forKey: Key.turnUsername)
            secrets.delete(Key.turnCredential)
            return
        }
        try secrets.save(Key.turnCredential, Data(server.credential.utf8))
        defaults.set(server.urls, forKey: Key.turnURLs)
        defaults.set(server.username, forKey: Key.turnUsername)
    }

    /// Where the list of trusted iPhones lives.
    static var trustStoreURL: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return support.appendingPathComponent("Reach Host", isDirectory: true)
            .appendingPathComponent("trusted-clients.json")
    }
}
