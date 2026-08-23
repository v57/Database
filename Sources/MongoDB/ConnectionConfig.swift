import Foundation

/// A saved connection definition. Pure value type: Codable (persistable),
/// Hashable/Identifiable (SwiftUI lists), no driver types involved.
public struct ConnectionConfig: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var host: String
    public var port: UInt16
    /// Optional credentials. Local dev servers usually need none.
    public var username: String?
    public var password: String?
    /// Auth database, used when credentials are present. Defaults to "admin" in the URI.
    public var authSource: String?
    /// Database preselected after connect (UI convenience, NOT encoded in the URI).
    public var defaultDatabase: String?
    /// When true, connects directly to the single server, bypassing topology
    /// discovery (SRV lookups / replica-set discovery). Encoded as
    /// `?directConnection=true` in the URI.
    public var directConnection: Bool

    public init(id: UUID = UUID(), name: String, host: String, port: UInt16 = 27017,
                username: String? = nil, password: String? = nil,
                authSource: String? = nil, defaultDatabase: String? = nil,
                directConnection: Bool = false) {
        self.id = id
        self.name = name
        self.host = host
        self.port = port
        self.username = username
        self.password = password
        self.authSource = authSource
        self.defaultDatabase = defaultDatabase
        self.directConnection = directConnection
    }

    /// mongodb:// URI. Path is intentionally omitted (defaultDatabase is a UI prefill,
    /// not part of the wire address) to avoid path-vs-authSource URI conflicts.
    public var connectionString: String {
        var s = "mongodb://"
        if let u = username, !u.isEmpty {
            s += u.addingPercentEncoding(withAllowedCharacters: .urlUserAllowed) ?? u
            if let p = password, !p.isEmpty {
                s += ":" + (p.addingPercentEncoding(withAllowedCharacters: .urlPasswordAllowed) ?? p)
            }
            s += "@"
        }
        s += "\(host):\(port)"
        var query: [String] = []
        if let a = authSource, !a.isEmpty {
            let enc = a.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? a
            query.append("authSource=\(enc)")
        }
        if directConnection {
            query.append("directConnection=true")
        }
        if !query.isEmpty {
            s += "/?" + query.joined(separator: "&")
        }
        return s
    }

    public var isValid: Bool {
        !host.isEmpty && port > 0
    }
}
