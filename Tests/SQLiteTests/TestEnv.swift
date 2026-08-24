import Foundation
@testable import SQLite

/// Integration-test support: SQLite needs no server — each test creates its
/// OWN temporary database file (the analogue of the Mongo per-test database /
/// PG per-test schema), so Swift Testing's parallel execution is safe. Files
/// are removed on the way out, always after the connection is closed.
enum TestEnv {
  static func freshFile(_ label: String) -> String {
    NSTemporaryDirectory() + "dbclient_\(label)_\(UUID().uuidString.prefix(8)).sqlite"
  }

  static func config(label: String, path: String? = nil) -> SQLiteConnectionConfig {
    SQLiteConnectionConfig(name: "test", filePath: path ?? freshFile(label))
  }

  static func connect(_ config: SQLiteConnectionConfig) async throws -> SQLiteConnection {
    let conn = SQLiteConnection(config: config)
    try await conn.connect()
    return conn
  }

  /// Creates an empty file at `path` (connect requires an existing file —
  /// like Open With, it never creates one).
  static func createEmptyFile(at path: String) {
    FileManager.default.createFile(atPath: path, contents: nil)
  }

  static func remove(_ path: String) {
    try? FileManager.default.removeItem(atPath: path)
  }
}