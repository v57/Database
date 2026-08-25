import Foundation
import Logging
import PostgresNIO

/// Async facade over a single PostgreSQL server connection.
/// NOT Sendable-declared on purpose: it owns a non-Sendable `PostgresConnection`
/// and is driven from the MainActor UI or from tests. All operations are async.
///
/// Uses a direct `PostgresConnection` (not the pooled `PostgresClient`, which
/// requires running its `run()` loop) — one connection matches the app's
/// single-session model and the MongoDB facade's shape.
public final class PostgresConnection {
  public let config: PostgresConnectionConfig
  private var connection: PostgresNIO.PostgresConnection?
  /// Database selected via use(database:). PostgreSQL cannot switch databases
  /// on an open wire connection, so this records the selection for the UI;
  /// queries address tables through qualified names (schema.table).
  public private(set) var currentDatabase: String?

  public init(config: PostgresConnectionConfig) { self.config = config }

  public var isConnected: Bool { connection != nil }

  /// Opens the connection. The driver authenticates during connect; a trivial
  /// `SELECT 1` verifies the session is usable before reporting connected.
  public func connect() async throws {
    guard config.isValid else { throw PostgreSQLError.invalidConfig("host must not be empty") }
    let configuration = PostgresNIO.PostgresConnection.Configuration(
      host: config.host, port: Int(config.port), username: config.username ?? "postgres",
      password: config.password, database: connectDatabaseName, tls: .disable)
    do {
      let eventLoop = PostgresNIO.PostgresConnection.defaultEventLoopGroup.any()
      let c = try await PostgresNIO.PostgresConnection.connect(
        on: eventLoop, configuration: configuration, id: 1,
        logger: Logger(label: "dev.database.postgres"))
      _ = try await c.query(PostgresQuery(unsafeSQL: "SELECT 1"), logger: Self.queryLogger)
      connection = c
    } catch { throw PostgreSQLError.server(error.localizedDescription) }
  }

  /// Database opened at connect time: explicit default, else "postgres".
  private var connectDatabaseName: String { config.defaultDatabase ?? "postgres" }

  public func disconnect() async {
    if let c = connection { try? await c.close() }
    connection = nil
    currentDatabase = nil
  }

  /// Non-template databases, alphabetical. Works on the standard server user.
  public func listDatabases() async throws -> [String] {
    guard connection != nil else { throw PostgreSQLError.notConnected }
    return try await strings(
      fromSQL: "SELECT datname FROM pg_database WHERE NOT datistemplate ORDER BY datname")
  }

  /// Switches the active database (UI selection; see `currentDatabase`).
  public func use(database: String) async throws {
    guard connection != nil else { throw PostgreSQLError.notConnected }
    currentDatabase = database
  }

  /// User tables across non-system schemas as `schema.table`, optionally
  /// filtered by case-insensitive substring (client-side; table counts are
  /// small in local development).
  public func listTables(matching search: String = "") async throws -> [String] {
    guard connection != nil else { throw PostgreSQLError.notConnected }
    let sql =
      "SELECT table_schema || '.' || table_name FROM information_schema.tables "
      + "WHERE table_schema NOT IN ('pg_catalog', 'information_schema') "
      + "AND table_type = 'BASE TABLE' ORDER BY 1"
    let names = try await strings(fromSQL: sql)
    guard !search.isEmpty else { return names }
    return names.filter { $0.localizedCaseInsensitiveContains(search) }
  }

  /// Runs a SELECT and returns every row as key/value pairs. `limit` stops
  /// consuming the row stream early (small local datasets).
  public func select(sql: String, limit: Int? = nil) async throws -> [PostgresRowData] {
    guard let c = connection else { throw PostgreSQLError.notConnected }
    guard !sql.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw PostgreSQLError.invalidQuery("Empty SQL statement")
    }
    do {
      let sequence = try await c.query(PostgresQuery(unsafeSQL: sql), logger: Self.queryLogger)
      var rows: [PostgresRowData] = []
      for try await row in sequence {
        rows.append(Self.rowData(index: rows.count, row: row))
        if let limit, rows.count >= limit { break }
      }
      return rows
    } catch let e as PostgreSQLError { throw e } catch {
      throw PostgreSQLError.server(error.localizedDescription)
    }
  }

  /// Runs any DML/DDL statement to completion. Affected-row counts are not
  /// available from the async query API — use `count(sql:)` with an explicit
  /// predicate when a real number matters (delete previews, tests).
  public func execute(sql: String) async throws {
    guard let c = connection else { throw PostgreSQLError.notConnected }
    guard !sql.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw PostgreSQLError.invalidQuery("Empty SQL statement")
    }
    do {
      // Drain the row stream so the command completes before returning.
      let sequence = try await c.query(PostgresQuery(unsafeSQL: sql), logger: Self.queryLogger)
      for try await _ in sequence {}
    } catch let e as PostgreSQLError { throw e } catch {
      throw PostgreSQLError.server(error.localizedDescription)
    }
  }

  /// Scalar count via SELECT count(*)-style queries (tests, delete previews).
  public func count(sql: String) async throws -> Int64 {
    let rows = try await select(sql: sql, limit: 1)
    guard let first = rows.first else { return 0 }
    for value in first.values.values { if case .int(let n) = value { return n } }
    return 0
  }

  // MARK: - Internals

  /// Quiet-enough logger for query calls (the async query API requires one).
  private static let queryLogger = Logger(label: "dev.database.postgres.query")

  private static func rowData(index: Int, row: PostgresRow) -> PostgresRowData {
    var columns: [String] = []
    var cells: [PostgresValue] = []
    // Random access is O(n) per cell — walk once in order instead.
    for cell in row {
      columns.append(cell.columnName.isEmpty ? "column" : cell.columnName)
      cells.append(value(of: cell))
    }
    return PostgresRowData(id: index, columns: columns, cells: cells)
  }

  /// Decodes a cell according to its wire type; unknown types fall back to
  /// their textual representation so nothing crashes the document list.
  private static func value(of cell: PostgresCell) -> PostgresValue {
    if cell.bytes == nil { return .null }
    switch cell.dataType {
    case .bool: return (try? cell.decode(Bool.self)).map { .bool($0) } ?? .string(text(cell))
    case .int2, .int4, .int8:
      return (try? cell.decode(Int64.self)).map { .int($0) } ?? .string(text(cell))
    case .float4, .float8:
      return (try? cell.decode(Double.self)).map { .double($0) } ?? .string(text(cell))
    case .numeric: return (try? cell.decode(String.self)).map { .string($0) } ?? .string(text(cell))
    case .timestamp, .timestamptz, .date:
      return (try? cell.decode(Date.self)).map { .date($0) } ?? .string(text(cell))
    case .json, .jsonb:
      return (try? cell.decode(String.self)).map { .json($0) } ?? .string(text(cell))
    case .bytea: return (try? cell.decode([UInt8].self)).map { .bytes($0) } ?? .string(text(cell))
    default: return .string(text(cell))
    }
  }

  private static func text(_ cell: PostgresCell) -> String { (try? cell.decode(String.self)) ?? "" }

  /// Runs a single-column text query and returns all values.
  private func strings(fromSQL sql: String) async throws -> [String] {
    try await select(sql: sql).compactMap { row in
      for value in row.values.values { if case .string(let s) = value { return s } }
      return nil
    }
  }
}
