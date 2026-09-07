import Foundation
import CPostgreSQL

/// Async facade over a single PostgreSQL server connection, backed by the
/// official libpq C library.
///
/// NOT Sendable-declared on purpose: it owns a non-Sendable libpq connection
/// handle and is driven from the MainActor UI or from tests. All operations
/// are async. Every blocking libpq call (PQconnectdb, PQexec, PQfinish, ...)
/// runs on a private serial DispatchQueue and is bridged back with an
/// async/await CheckedContinuation, so the MainActor is never blocked.
///
/// Access to the raw connection pointer is serialized by that one queue; the
/// pointer lives in an `@unchecked Sendable` box that is only ever read or
/// written on the queue, so sending it across concurrency is safe.
public final class PostgresConnection {
  public let config: PostgresConnectionConfig

  /// Serialized libpq handle. The pointer is only accessed inside
  /// `runOnQueue`, so the `@unchecked Sendable` box is safe to send across
  /// concurrency.
  private final class ConnectionHandle: @unchecked Sendable {
    var conn: OpaquePointer?
  }
  private let handle = ConnectionHandle()

  /// Database selected via use(database:). PostgreSQL cannot switch databases
  /// on an open wire connection, so this records the selection for the UI;
  /// queries address tables through qualified names (schema.table).
  public private(set) var currentDatabase: String?

  /// Every blocking C call is dispatched here so the MainActor never blocks.
  private static let queue = DispatchQueue(label: "dev.database.postgres.libpq", qos: .userInitiated)

  public init(config: PostgresConnectionConfig) { self.config = config }

  public var isConnected: Bool { handle.conn != nil }

  // MARK: - Queue bridge

  /// Runs a blocking closure on the background queue and bridges its result
  /// (or thrown error) back to the caller via a CheckedContinuation. The
  /// closure must only capture Sendable values (config, the handle box) —
  /// never `self`.
  private func runOnQueue<T: Sendable>(_ body: @escaping @Sendable () throws -> T) async throws -> T {
    try await withCheckedThrowingContinuation { cont in
      Self.queue.async {
        do { cont.resume(returning: try body()) }
        catch { cont.resume(throwing: error) }
      }
    }
  }

  // MARK: - Lifecycle

  /// Opens the connection. libpq authenticates during connect (SCRAM-SHA-256 /
  /// MD5 when a password is supplied); a trivial `SELECT 1` verifies the
  /// session is usable before reporting connected.
  public func connect() async throws {
    guard config.isValid else {
      throw PostgreSQLError.invalidConfig("host must not be empty")
    }
    let conninfo = Self.conninfo(config: config)
    let handle = self.handle
    try await runOnQueue { () -> Void in
      guard let c = PQconnectdb(conninfo) else {
        throw PostgreSQLError.server("Out of memory allocating connection")
      }
      var success = false
      defer { if !success { PQfinish(c) } }
      guard PQstatus(c) == CONNECTION_OK else {
        throw PostgreSQLError.server(String(cString: PQerrorMessage(c)))
      }
      // Confirm the session is usable before storing the connection.
      guard let res = PQexec(c, "SELECT 1") else {
        throw PostgreSQLError.server("SELECT 1 returned no result")
      }
      let ok = PQresultStatus(res) == PGRES_TUPLES_OK
      PQclear(res)
      guard ok else { throw PostgreSQLError.server("SELECT 1 failed") }
      handle.conn = c
      success = true
    }
  }

  public func disconnect() async {
    let handle = self.handle
    try? await runOnQueue { () -> Void in
      if let c = handle.conn {
        PQfinish(c)
        handle.conn = nil
      }
    }
    currentDatabase = nil
  }

  // MARK: - Operations

  /// Non-template databases, alphabetical. Works on the standard server user.
  public func listDatabases() async throws -> [String] {
    try await strings(
      fromSQL: "SELECT datname FROM pg_database WHERE NOT datistemplate ORDER BY datname")
  }

  /// Switches the active database (UI selection; see `currentDatabase`).
  public func use(database: String) async throws {
    guard handle.conn != nil else { throw PostgreSQLError.notConnected }
    currentDatabase = database
  }

  /// User tables across non-system schemas as `schema.table`, optionally
  /// filtered by case-insensitive substring (client-side; table counts are
  /// small in local development).
  public func listTables(matching search: String = "") async throws -> [String] {
    let sql =
      "SELECT table_schema || '.' || table_name FROM information_schema.tables "
      + "WHERE table_schema NOT IN ('pg_catalog', 'information_schema') "
      + "AND table_type = 'BASE TABLE' ORDER BY 1"
    let names = try await strings(fromSQL: sql)
    guard !search.isEmpty else { return names }
    return names.filter { $0.localizedCaseInsensitiveContains(search) }
  }

  /// Runs a SELECT and returns every row as key/value pairs. `limit` stops
  /// consuming the result set early; `offset` skips the first N rows (for
  /// cursor-free pagination with a stable ORDER BY). Returns rows as PostgresRowData.
  public func select(sql: String, limit: Int? = nil, offset: Int? = nil) async throws
    -> [PostgresRowData]
  {
    guard !sql.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw PostgreSQLError.invalidQuery("Empty SQL statement")
    }
    let handle = self.handle
    let applied = try Self.applyLimitOffset(sql: sql, limit: limit, offset: offset)
    return try await runOnQueue {
      guard let c = handle.conn else { throw PostgreSQLError.notConnected }
      guard let res = PQexec(c, applied) else {
        throw PostgreSQLError.server("Could not execute query")
      }
      defer { PQclear(res) }
      let status = PQresultStatus(res)
      guard status == PGRES_TUPLES_OK else {
        throw PostgreSQLError.server(String(cString: PQresultErrorMessage(res)))
      }
      let cols = Int(PQnfields(res))
      let rows = Int(PQntuples(res))
      var columns: [String] = []
      for f in 0..<cols { columns.append(Self.columnName(res, field: f)) }
      var out: [PostgresRowData] = []
      for r in 0..<rows {
        if let limit, out.count >= limit { break }
        var cells: [PostgresValue] = []
        for f in 0..<cols { cells.append(Self.value(res, row: r, field: f)) }
        out.append(PostgresRowData(id: out.count, columns: columns, cells: cells))
      }
      return out
    }
  }

  /// Appends LIMIT/OFFSET to a read query when asked; reused by the facade's
  /// pagination paths so the base `select` keeps its zero-option behavior.
  private static func applyLimitOffset(sql: String, limit: Int?, offset: Int?) throws -> String {
    let trimmed = sql.trimmingCharacters(in: .whitespacesAndNewlines)
    guard limit != nil || offset != nil else { return trimmed }
    var clauses: [String] = []
    if let limit { clauses.append("LIMIT \(limit)") }
    if let offset { clauses.append("OFFSET \(offset)") }
    return trimmed + " " + clauses.joined(separator: " ")
  }

  /// Runs any DML/DDL statement to completion. Affected-row counts are not
  /// surfaced by libpq's `PQexec` here — use `count(sql:)` with an explicit
  /// predicate when a real number matters (delete previews, tests).
  public func execute(sql: String) async throws {
    guard !sql.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw PostgreSQLError.invalidQuery("Empty SQL statement")
    }
    let handle = self.handle
    try await runOnQueue { () -> Void in
      guard let c = handle.conn else { throw PostgreSQLError.notConnected }
      guard let res = PQexec(c, sql) else {
        throw PostgreSQLError.server("Could not execute query")
      }
      defer { PQclear(res) }
      let status = PQresultStatus(res)
      guard status == PGRES_COMMAND_OK || status == PGRES_TUPLES_OK else {
        throw PostgreSQLError.server(String(cString: PQresultErrorMessage(res)))
      }
    }
  }

  /// Scalar count via SELECT count(*)-style queries (tests, delete previews).
  public func count(sql: String) async throws -> Int64 {
    let rows = try await select(sql: sql, limit: 1)
    guard let first = rows.first else { return 0 }
    for value in first.values.values {
      if case .int(let n) = value { return n }
    }
    return 0
  }

  // MARK: - Internals

  /// Runs a single-column text query and returns all values.
  private func strings(fromSQL sql: String) async throws -> [String] {
    try await select(sql: sql).compactMap { row in
      for value in row.values.values {
        if case .string(let s) = value { return s }
      }
      return nil
    }
  }

  private static func columnName(_ res: OpaquePointer, field: Int) -> String {
    guard let name = PQfname(res, Int32(field)) else { return "column" }
    let s = String(cString: name)
    return s.isEmpty ? "column" : s
  }

  /// Decodes a result cell to `PostgresValue` based on the column OID.
  private static func value(_ res: OpaquePointer, row: Int, field: Int) -> PostgresValue {
    guard PQgetisnull(res, Int32(row), Int32(field)) == 0 else { return .null }
    guard let raw = PQgetvalue(res, Int32(row), Int32(field)) else { return .null }
    let text = String(cString: raw)
    switch PQftype(res, Int32(field)) {
    case BoolOID: return .bool(parseBool(text))
    case Int2OID, Int4OID, Int8OID:
      return (Int64(text)).map { .int($0) } ?? .string(text)
    case Float4OID, Float8OID:
      return (Double(text)).map { .double($0) } ?? .string(text)
    case NumericOID: return .string(text)
    case TimestampOID, TimestamptzOID, DateOID:
      return parseDate(text).map { .date($0) } ?? .string(text)
    case JsonOID, JsonbOID: return .json(text)
    case ByteaOID: return .bytes(parseBytea(text))
    default: return .string(text)
    }
  }

  // MARK: - OID constants (from pg_type_d.h, libpq 18.4)

  private static let BoolOID: UInt32 = 16         // bool
  private static let ByteaOID: UInt32 = 17        // bytea
  private static let Int8OID: UInt32 = 20         // int8
  private static let Int2OID: UInt32 = 21         // int2
  private static let Int4OID: UInt32 = 23         // int4
  private static let JsonOID: UInt32 = 114        // json
  private static let Float4OID: UInt32 = 700      // float4
  private static let Float8OID: UInt32 = 701      // float8
  private static let DateOID: UInt32 = 1082       // date
  private static let TimestampOID: UInt32 = 1114  // timestamp
  private static let TimestamptzOID: UInt32 = 1184 // timestamptz
  private static let NumericOID: UInt32 = 1700    // numeric
  private static let JsonbOID: UInt32 = 3802      // jsonb

  private static func parseBool(_ text: String) -> Bool {
    text == "t" || text == "true" || text == "TRUE" || text == "1"
  }

  /// libpq emits bytea in hex format by default (bytea_output = hex): "\x…".
  private static func parseBytea(_ text: String) -> [UInt8] {
    if text.hasPrefix("\\x") {
      let hex: [Character: UInt8] = [
        "0": 0, "1": 1, "2": 2, "3": 3, "4": 4, "5": 5, "6": 6, "7": 7,
        "8": 8, "9": 9, "a": 10, "b": 11, "c": 12, "d": 13, "e": 14, "f": 15,
        "A": 10, "B": 11, "C": 12, "D": 13, "E": 14, "F": 15,
      ]
      let chars = Array(text.dropFirst(2))
      var out: [UInt8] = []
      var i = 0
      while i + 1 < chars.count {
        if let hi = hex[chars[i]], let lo = hex[chars[i + 1]] {
          out.append(UInt8(hi * 16 + lo))
        }
        i += 2
      }
      return out
    }
    // Fallback: legacy escape format ("\\NNN" octal, plus literal bytes).
    var out: [UInt8] = []
    var it = text.makeIterator()
    while let c = it.next() {
      if c == "\\" {
        var n = 0
        var count = 0
        while count < 3, let d = it.next(), let v = d.wholeNumberValue, v < 8 {
          n = n * 8 + v
          count += 1
        }
        out.append(UInt8(n & 0xFF))
      } else {
        out.append(c.asciiValue ?? 0)
      }
    }
    return out
  }

  // MARK: - Date parsing

  /// Best-effort parse of libpq's textual timestamp/timestamptz/date output.
  private static func parseDate(_ text: String) -> Date? {
    for format in postgresDateFormats {
      if let d = makeFormatter(format).date(from: text) { return d }
    }
    return nil
  }

  private static let postgresDateFormats: [String] = [
    "yyyy-MM-dd HH:mm:ss.SSSSSSXXXXX",
    "yyyy-MM-dd HH:mm:ss.SSSSSSX",
    "yyyy-MM-dd HH:mm:ssXXXXX",
    "yyyy-MM-dd HH:mm:ssX",
    "yyyy-MM-dd HH:mm:ss.SSSSSS",
    "yyyy-MM-dd HH:mm:ss",
    "yyyy-MM-dd",
  ]

  private static func makeFormatter(_ format: String) -> DateFormatter {
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.timeZone = TimeZone(identifier: "UTC")
    f.dateFormat = format
    return f
  }

  // MARK: - conninfo

  /// Builds a libpq conninfo string from the config: host/port/username
  /// (default "postgres")/password/dbname (default "postgres"). libpq handles
  /// SCRAM-SHA-256/MD5 natively when a password is supplied.
  private static func conninfo(config: PostgresConnectionConfig) -> String {
    var parts: [String] = []
    parts.append("host=\(connectionKeywordValue(config.host))")
    parts.append("port=\(config.port)")
    parts.append("user=\(connectionKeywordValue(config.username ?? "postgres"))")
    if let p = config.password { parts.append("password=\(connectionKeywordValue(p))") }
    parts.append("dbname=\(connectionKeywordValue(config.defaultDatabase ?? "postgres"))")
    parts.append("connect_timeout=5")
    parts.append("sslmode=disable")
    return parts.joined(separator: " ")
  }

  /// libpq keyword-value quoting: values touching unsafe characters are
  /// single-quoted with backslash escaping of `'` and `\`.
  private static func connectionKeywordValue(_ value: String) -> String {
    let safe = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "@._/-:"))
    if value.rangeOfCharacter(from: safe.inverted) == nil {
      return value
    }
    var out = "'"
    for ch in value {
      if ch == "'" || ch == "\\" { out.append("\\") }
      out.append(ch)
    }
    out.append("'")
    return out
  }
}
