import Foundation
import SwiftData
import MongoDB

/// A saved MongoDB connection, persisted with SwiftData.
/// Password is stored in plain text for now; Keychain integration is a noted future step.
@Model
final class ConnectionRecord {
    var name: String
    var host: String
    var port: Int
    var username: String?
    var password: String?
    var authSource: String?
    var defaultDatabase: String?
    var directConnection: Bool = false

    init(name: String, host: String, port: Int, username: String? = nil,
         password: String? = nil, authSource: String? = nil, defaultDatabase: String? = nil,
         directConnection: Bool = false) {
        self.name = name
        self.host = host
        self.port = port
        self.username = username
        self.password = password
        self.authSource = authSource
        self.defaultDatabase = defaultDatabase
        self.directConnection = directConnection
    }

    /// Maps the persisted record to the driver-facing connection configuration.
    func toConfig() -> ConnectionConfig {
        ConnectionConfig(
            name: name,
            host: host,
            port: UInt16(port),
            username: username,
            password: password,
            authSource: authSource,
            defaultDatabase: defaultDatabase,
            directConnection: directConnection
        )
    }

    /// Builds a record from a configuration (used when saving an edit).
    static func from(config: ConnectionConfig) -> ConnectionRecord {
        ConnectionRecord(
            name: config.name,
            host: config.host,
            port: Int(config.port),
            username: config.username,
            password: config.password,
            authSource: config.authSource,
            defaultDatabase: config.defaultDatabase,
            directConnection: config.directConnection
        )
    }
}
