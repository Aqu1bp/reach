import Foundation
import ReachCore

/// The optional relay (TURN) server: the fallback path when the iPhone and the Mac can't reach each
/// other directly, e.g. both behind strict NATs or firewalls. The engine adds it to the public STUN
/// servers and shares it with paired iPhones. Media through it stays end-to-end encrypted (DTLS);
/// the server only forwards packets.
struct TurnServer: Equatable {
    /// Canonical `turn:` / `turns:` URLs, all for the same server and credentials (e.g. UDP and TLS).
    var urls: [String]
    var username: String
    var credential: String

    enum Problem: Error, Equatable {
        case missingURL
        case invalidURL(String)
        case missingCredentials

        var message: String {
            switch self {
            case .missingURL: return "Enter the server's address, like turn:relay.example.com:3478."
            case .invalidURL(let url): return "“\(url)” isn't a TURN address. Use turn:host:port or turns:host:port."
            case .missingCredentials: return "Enter the username and password for this server."
            }
        }
    }

    /// Checks what was typed in settings: one or more URLs separated by commas, spaces or new lines,
    /// plus the username and password. All three empty means no relay server (`nil`).
    ///
    /// Strict on purpose: WebRTC won't create a connection at all if any server is malformed or a
    /// TURN server lacks credentials, so a bad entry here would break every session.
    static func parse(urls: String, username: String, credential: String) -> Result<TurnServer?, Problem> {
        let entries = urls.split(whereSeparator: { $0 == "," || $0.isWhitespace }).map(String.init)
        let username = username.trimmingCharacters(in: .whitespacesAndNewlines)
        let credential = credential.trimmingCharacters(in: .whitespacesAndNewlines)
        if entries.isEmpty {
            return username.isEmpty && credential.isEmpty ? .success(nil) : .failure(.missingURL)
        }
        var canonical: [String] = []
        for entry in entries {
            guard let url = TurnURL(entry) else { return .failure(.invalidURL(entry)) }
            if !canonical.contains(url.string) { canonical.append(url.string) }
        }
        guard !username.isEmpty, !credential.isEmpty else { return .failure(.missingCredentials) }
        return .success(TurnServer(urls: canonical, username: username, credential: credential))
    }

    /// The engine's full list: the public STUN servers, then this server if there is one.
    static func iceServers(with server: TurnServer?) -> [IceServerConfig] {
        var servers = IceServerConfig.defaultSTUN
        if let server { servers.append(IceServerConfig(urls: server.urls, username: server.username, credential: server.credential)) }
        return servers
    }

    /// "relay.example.com", for showing which server is in use.
    var displayHost: String {
        urls.first.flatMap(TurnURL.init)?.host ?? urls.first ?? ""
    }
}
