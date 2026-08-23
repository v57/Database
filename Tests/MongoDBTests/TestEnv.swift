import Foundation
import MongoSwift
import NIO

@testable import MongoDB

/// Integration-test support: localhost server, per-test databases so tests can
/// run in parallel, each db dropped on the way out.
enum TestEnv {
  static let host = "127.0.0.1"
  static let port: UInt16 = 27017

  static func config() -> ConnectionConfig {
    // directConnection: the local server is a replica set advertising
    // docker-compose hostnames (mongo/mongo2/mongo3) that don't resolve
    // on the host. Bypass topology discovery and talk to 127.0.0.1
    // directly, otherwise every operation hits a 30s server-selection
    // timeout trying to resolve those names.
    ConnectionConfig(name: "test", host: host, port: port, directConnection: true)
  }

  static func freshDBName(_ label: String) -> String {
    "dbclient_\(label)_\(UUID().uuidString.prefix(8))"
  }

  /// v1.3.1 requires an explicit NIO EventLoopGroup.
  static func makeClient() throws -> (MongoClient, MultiThreadedEventLoopGroup) {
    let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    let client = try MongoClient("mongodb://\(host):\(port)/?directConnection=true", using: group)
    return (client, group)
  }

  /// Seed a collection using the raw driver (insert is intentionally NOT part
  /// of the public MongoDB API surface).
  static func seed(database: String, collection: String, docs: [Document]) async throws {
    let (client, group) = try makeClient()
    defer {
      try? await client.close()
      group.shutdownGracefully { _ in }
    }
    _ = try await client.db(database).collection(collection).insertMany(docs)
  }

  static func drop(database: String) async throws {
    let (client, group) = try makeClient()
    defer {
      try? await client.close()
      group.shutdownGracefully { _ in }
    }
    try await client.db(database).drop()
  }
}
