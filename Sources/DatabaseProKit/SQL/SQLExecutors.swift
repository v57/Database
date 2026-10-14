import DuckDBKit
import Foundation
import MySQLWire
import PostgresWire
import SQLiteKit
import TDSWire
import WireKit

/// Lets one async operation at a time through, so a `USE db` and the query after it stay together.
actor SerialGate {
  private var busy = false
  private var waiters: [CheckedContinuation<Void, Never>] = []

  func run<T: Sendable>(_ body: @Sendable () async throws -> T) async throws -> T {
    while busy { await withCheckedContinuation { waiters.append($0) } }
    busy = true
    defer {
      busy = false
      if !waiters.isEmpty { waiters.removeFirst().resume() }
    }
    return try await body()
  }
}

/// Runs SQL text against one engine, in a given database when the engine has several.
protocol SQLExecutor: Sendable {
  /// Keeps a database switch and the statements after it together.
  var gate: SerialGate { get }
  /// Runs on the connection for `database`; callers hold the gate.
  func runUngated(_ sql: String, database: String?) async throws -> [DBResult]
  func close() async
  var serverDescription: String { get async }
  /// The database a new query runs in when none is picked.
  var defaultDatabase: String? { get async }
}

extension SQLExecutor {
  func run(_ sql: String, database: String?) async throws -> [DBResult] {
    try await gate.run { try await self.runUngated(sql, database: database) }
  }

  /// BEGIN, each statement (checked), COMMIT — and ROLLBACK if anything fails.
  func transaction(
    _ statements: [String], dialect: SQLDialect, database: String?,
    check: @escaping @Sendable (Int, DBResult) throws -> Void
  ) async throws -> [DBResult] {
    try await gate.run {
      _ = try await self.runUngated(dialect.beginTransaction, database: database)
      var results: [DBResult] = []
      do {
        for (index, statement) in statements.enumerated() {
          let result = try await self.runUngated(statement, database: database).last ?? DBResult()
          try check(index, result)
          results.append(result)
        }
        _ = try await self.runUngated(dialect.commit, database: database)
      } catch {
        _ = try? await self.runUngated(dialect.rollback, database: database)
        throw error
      }
      return results
    }
  }
}

// MARK: - PostgreSQL: one connection per database

actor PostgresExecutor: SQLExecutor {
  let base: PostgresClient.Config
  private var clients: [String: PostgresClient] = [:]
  nonisolated let gate = SerialGate()

  init(base: PostgresClient.Config, first: PostgresClient) {
    self.base = base
    clients[base.database] = first
  }

  var defaultDatabase: String? { base.database }

  private func client(for database: String?) async throws -> PostgresClient {
    let name = database?.isEmpty == false ? database! : base.database
    if let existing = clients[name], await existing.isOpen { return existing }
    var config = base
    config.database = name
    let client = try await PostgresClient.connect(config)
    clients[name] = client
    return client
  }

  func runUngated(_ sql: String, database: String?) async throws -> [DBResult] {
    try await client(for: database).query(sql)
  }

  func close() async {
    for client in clients.values { await client.close() }
    clients.removeAll()
  }

  var serverDescription: String {
    get async {
      guard let any = clients.values.first else { return "PostgreSQL" }
      return "PostgreSQL \(await any.serverVersion)"
    }
  }
}

// MARK: - MySQL / MariaDB

actor MySQLExecutor: SQLExecutor {
  let client: MySQLClient
  nonisolated let gate = SerialGate()
  init(client: MySQLClient) { self.client = client }

  var defaultDatabase: String? { get async { await client.currentDatabase } }

  func runUngated(_ sql: String, database: String?) async throws -> [DBResult] {
    if let database, !database.isEmpty, await client.currentDatabase != database {
      try await client.use(database: database)
    }
    return try await client.query(sql)
  }

  func close() async { await client.close() }

  var serverDescription: String {
    get async {
      let version = await client.serverVersion
      let maria = await client.isMariaDB
      let number = version.split(separator: "-").first.map(String.init) ?? version
      return "\(maria ? "MariaDB" : "MySQL") \(number)"
    }
  }
}

// MARK: - SQL Server

actor TDSExecutor: SQLExecutor {
  let client: TDSClient
  nonisolated let gate = SerialGate()
  init(client: TDSClient) { self.client = client }

  var defaultDatabase: String? { get async { await client.currentDatabase } }

  func runUngated(_ sql: String, database: String?) async throws -> [DBResult] {
    if let database, !database.isEmpty, await client.currentDatabase != database {
      try await client.use(database: database)
    }
    return try await client.query(sql)
  }

  func close() async { await client.close() }

  var serverDescription: String {
    get async {
      let version = await client.serverVersion
      let major = Int(version.split(separator: ".").first ?? "") ?? 0
      let product: String =
        switch major {
        case 17: "SQL Server 2025"
        case 16: "SQL Server 2022"
        case 15: "SQL Server 2019"
        case 14: "SQL Server 2017"
        default: "SQL Server"
        }
      return "\(product) (\(version))"
    }
  }
}

// MARK: - SQLite

final class SQLiteExecutor: SQLExecutor, @unchecked Sendable {
  let file: SQLiteFile
  let gate = SerialGate()
  init(file: SQLiteFile) { self.file = file }

  var defaultDatabase: String? { nil }

  func runUngated(_ sql: String, database: String?) async throws -> [DBResult] {
    try await file.query(sql)
  }

  func close() async { await file.close() }

  var serverDescription: String {
    get async {
      let version = (try? await file.execute("SELECT sqlite_version()").rows.first?.first?.stringValue) ?? nil
      return "SQLite \(version ?? "")"
    }
  }
}

// MARK: - DuckDB

final class DuckDBExecutor: SQLExecutor, @unchecked Sendable {
  let file: DuckDBFile
  let gate = SerialGate()
  init(file: DuckDBFile) { self.file = file }

  var defaultDatabase: String? { nil }

  func runUngated(_ sql: String, database: String?) async throws -> [DBResult] {
    // DuckDB returns only the last statement's rows; run them one by one to report each.
    let statements = SQLText.splitStatements(sql)
    var results: [DBResult] = []
    for statement in statements.isEmpty ? [sql] : statements {
      results.append(try await file.query(statement))
    }
    return results
  }

  func close() async { await file.close() }

  var serverDescription: String {
    get async {
      let version = (try? await file.query("SELECT version()").rows.first?.first?.stringValue) ?? nil
      return "DuckDB \(version ?? "")"
    }
  }
}

/// Small SQL text helpers.
enum SQLText {
  /// Splits on semicolons outside quotes and comments.
  static func splitStatements(_ sql: String) -> [String] {
    var statements: [String] = []
    var current = ""
    var quote: Character?
    var lineComment = false
    var blockComment = false
    var previous: Character = " "
    for ch in sql {
      if lineComment {
        current.append(ch)
        if ch == "\n" { lineComment = false }
      } else if blockComment {
        current.append(ch)
        if previous == "*" && ch == "/" { blockComment = false }
      } else if let q = quote {
        current.append(ch)
        if ch == q { quote = nil }
      } else if ch == "'" || ch == "\"" || ch == "`" {
        quote = ch
        current.append(ch)
      } else if previous == "-" && ch == "-" {
        lineComment = true
        current.append(ch)
      } else if previous == "/" && ch == "*" {
        blockComment = true
        current.append(ch)
      } else if ch == ";" {
        let trimmed = current.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty && !isOnlyComments(trimmed) { statements.append(trimmed) }
        current = ""
      } else {
        current.append(ch)
      }
      previous = ch
    }
    let trimmed = current.trimmingCharacters(in: .whitespacesAndNewlines)
    if !trimmed.isEmpty && !isOnlyComments(trimmed) { statements.append(trimmed) }
    return statements
  }

  static func isOnlyComments(_ text: String) -> Bool {
    text.split(whereSeparator: \.isNewline).allSatisfy {
      let line = $0.trimmingCharacters(in: .whitespaces)
      return line.isEmpty || line.hasPrefix("--")
    }
  }
}
