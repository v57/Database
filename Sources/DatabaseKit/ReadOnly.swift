import BSON
import DuckDBKit
import Foundation
import SQLiteKit
import WireKit

/// What a Read only connection lets a query tab run (D-018). The engine's own read-only mode does the refusing where
/// there is one: PostgreSQL logs in with `default_transaction_read_only` on, MySQL and MariaDB run
/// `SET SESSION TRANSACTION READ ONLY`, SQLite and DuckDB files open read-only. These checks keep a query tab from
/// turning that mode off, and stand in for it on SQL Server, MongoDB and Redis, which have no such mode for one
/// connection: there they read the statement, which a determined user can get around (a login that can only read is the
/// guarantee). DuckDB's read-only mode guards only the database file, and an in-memory DuckDB over CSV, Parquet or JSON
/// files has none, so statements that write files (`COPY … TO`, `EXPORT DATABASE`, a writable `ATTACH`, `INSTALL`) are
/// refused by the same kind of check (D-020).
enum ReadOnlyGuard {
  /// Run before each query tab's text on PostgreSQL, in case something turned the mode off.
  static let postgresSession = "SET SESSION CHARACTERISTICS AS TRANSACTION READ ONLY"
  /// Run after connecting and before each query tab's text on MySQL and MariaDB.
  static let mySQLSession = "SET SESSION TRANSACTION READ ONLY"

  /// Refuses text a query tab runs on a Read only connection, before it reaches the server.
  static func check(_ sql: String, engine: EngineKind) throws {
    switch engine {
    case .postgres, .mysql, .mariadb:
      if let statement = liftingStatement(sql) {
        throw ReadOnlyError("“\(excerpt(statement))” would turn off its read-only mode.")
      }
    case .sqlserver:
      if let word = sqlServerWrite(sql) {
        throw ReadOnlyError(
          "SQL Server runs only statements that read here, and this one has \(word).")
      }
    case .duckdb:
      if let statement = duckDBFileWrite(sql) {
        throw ReadOnlyError("“\(excerpt(statement))” writes files, which Read only doesn’t allow.")
      }
    default:
      break
    }
  }

  /// The engine's own refusal of a write, as `ReadOnlyError` with the server's words; nil for any other error.
  static func refusal(_ error: Error) -> ReadOnlyError? {
    if let server = error as? DBServerError, let code = server.code {
      // PostgreSQL's SQLSTATE 25006 read_only_sql_transaction; MySQL and MariaDB's 1792
      // ER_CANT_EXECUTE_IN_READ_ONLY_TRANSACTION ("1792 (25006)").
      if code == "25006" || code.hasPrefix("1792") || code.contains("(25006)") {
        return ReadOnlyError("\(server.engine) refused it: \(server.message)")
      }
    }
    if let sqlite = error as? SQLiteError, sqlite.code & 0xFF == 8 /* SQLITE_READONLY */ {
      return ReadOnlyError("SQLite refused it: \(sqlite.message)")
    }
    if let duck = error as? DuckDBError, duck.message.localizedCaseInsensitiveContains("read-only mode") {
      return ReadOnlyError("DuckDB refused it: \(duck.message)")
    }
    return nil
  }

  // MARK: - PostgreSQL, MySQL, MariaDB

  /// The first statement that would turn the session's read-only mode off: `SET … READ WRITE`, a setting named
  /// `…read_only`, `set_config(…)`, `RESET ALL`, `DISCARD ALL`. It reads the raw text, quotes and all, so a
  /// `DO $$ … $$` body or `EXECUTE '…'` counts too; `SHOW` and a `SELECT` that only reads such a setting pass.
  static func liftingStatement(_ sql: String) -> String? {
    for statement in SQLText.splitStatements(sql) {
      let flat = statement.uppercased().split(whereSeparator: \.isWhitespace).joined(separator: " ")
      let words = flat.split(whereSeparator: { !($0.isLetter || $0.isNumber || $0 == "_") })
      let first = words.first.map(String.init) ?? ""
      if first == "SHOW" { continue }
      if flat.contains("READ WRITE") || flat.contains("SET_CONFIG") { return statement }
      if flat.contains("READ_ONLY") && !["SELECT", "WITH"].contains(first) { return statement }
      if ["RESET", "DISCARD"].contains(first) && words.contains("ALL") { return statement }
    }
    return nil
  }

  // MARK: - DuckDB

  /// Settings and calls that make DuckDB write a file of the user's choosing (a profile, a query log, a log file) or
  /// move where it keeps extensions, secrets and spilled data.
  static let duckDBFileSettings: Set<String> = [
    "PROFILING_OUTPUT", "LOG_QUERY_PATH", "ENABLE_LOGGING", "LOGGING_STORAGE", "HTTP_LOGGING_OUTPUT", "TEMP_DIRECTORY",
    "EXTENSION_DIRECTORY", "SECRET_DIRECTORY", "HOME_DIRECTORY", "ENABLE_EXTERNAL_ACCESS", "ALLOWED_PATHS",
    "ALLOWED_DIRECTORIES", "DISABLED_FILESYSTEMS",
  ]

  /// The first statement that would write a file on DuckDB, which a read-only database file doesn't stop and an
  /// in-memory database over files doesn't have: `COPY` (to a file, or between databases), `EXPORT DATABASE`, an
  /// `ATTACH` without `READ_ONLY` (it creates and writes the file), `INSTALL`/`FORCE INSTALL`/`UPDATE EXTENSIONS`,
  /// a persistent secret, and the settings in `duckDBFileSettings`. Reading files (`read_csv`, `FROM 'x.parquet'`)
  /// passes.
  static func duckDBFileWrite(_ sql: String) -> String? {
    for statement in SQLText.splitStatements(sql) {
      var words = codeWords(statement)[...]
      // EXPLAIN ANALYZE runs the statement, and PREPARE keeps it for EXECUTE.
      while let lead = words.first, ["EXPLAIN", "ANALYZE"].contains(lead) { words = words.dropFirst() }
      if words.first == "PREPARE", let at = words.firstIndex(of: "AS") { words = words[(at + 1)...] }
      guard let first = words.first else { continue }
      switch first {
      case "COPY", "EXPORT", "INSTALL":
        return statement
      case "FORCE" where words.dropFirst().first == "INSTALL":
        return statement
      case "UPDATE" where words.dropFirst().first == "EXTENSIONS" && !words.contains("SET"):
        return statement
      case "ATTACH":
        if !words.contains("READ_ONLY") || words.contains("FALSE") { return statement }
      case "CREATE" where words.contains("PERSISTENT") && words.contains("SECRET"):
        return statement
      default:
        break
      }
      if words.contains(where: { duckDBFileSettings.contains($0) }) { return statement }
      // A setting's name may be quoted, which codeWords skips: read the raw text of SET, PRAGMA and CALL.
      if ["SET", "PRAGMA", "CALL"].contains(first) {
        let raw = statement.uppercased()
        if duckDBFileSettings.contains(where: { raw.contains($0) }) { return statement }
      }
    }
    return nil
  }

  // MARK: - SQL Server

  /// Words that make a T-SQL batch more than a read. T-SQL needs no semicolons between statements, so the whole text
  /// is searched, outside strings, comments and [quoted] or "quoted" names.
  static let sqlServerWrites: Set<String> = [
    "INSERT", "UPDATE", "DELETE", "MERGE", "INTO", "CREATE", "ALTER", "DROP", "TRUNCATE", "GRANT", "REVOKE", "DENY",
    "EXEC", "EXECUTE", "BACKUP", "RESTORE", "DBCC", "BULK", "KILL", "SHUTDOWN", "RECONFIGURE", "WRITETEXT",
    "UPDATETEXT", "CHECKPOINT", "OPENQUERY", "OPENROWSET", "OPENDATASOURCE", "ENABLE", "DISABLE", "RENAME",
  ]
  /// What a statement that only reads starts with.
  static let sqlServerReads: Set<String> = [
    "SELECT", "WITH", "SET", "DECLARE", "PRINT", "USE", "BEGIN", "COMMIT", "ROLLBACK", "IF", "ELSE", "WHILE",
    "RETURN", "WAITFOR", "END", "BREAK", "CONTINUE", "SAVE",
  ]

  /// The word that makes `sql` a write on SQL Server (as written: "DELETE"), or nil when it only reads.
  static func sqlServerWrite(_ sql: String) -> String? {
    for statement in SQLText.splitStatements(sql) {
      let words = codeWords(statement)
      guard let first = words.first else { continue }
      if let write = words.first(where: { sqlServerWrites.contains($0) }) { return write }
      if !sqlServerReads.contains(first) { return first }
    }
    return nil
  }

  /// The uppercased words of SQL text outside strings, comments and quoted names.
  static func codeWords(_ sql: String) -> [String] {
    var words: [String] = []
    var current = ""
    var chars = Array(sql)[...]
    func flush() {
      if !current.isEmpty { words.append(current.uppercased()) }
      current = ""
    }
    func skip(to end: String) {
      let close = Array(end)
      while !chars.isEmpty {
        if chars.starts(with: close) {
          chars = chars.dropFirst(close.count)
          return
        }
        chars = chars.dropFirst()
      }
    }
    while let ch = chars.first {
      chars = chars.dropFirst()
      switch ch {
      case "'":
        flush()
        // '' inside a string is a quote; skipping to the next ' and going on reads it as two strings.
        skip(to: "'")
      case "\"":
        flush()
        skip(to: "\"")
      case "[":
        flush()
        skip(to: "]")
      case "-" where chars.first == "-":
        flush()
        skip(to: "\n")
      case "/" where chars.first == "*":
        flush()
        chars = chars.dropFirst()
        skip(to: "*/")
      default:
        if ch.isLetter || ch.isNumber || ch == "_" || ch == "@" || ch == "#" || ch == "$" {
          current.append(ch)
        } else {
          flush()
        }
      }
    }
    flush()
    return words
  }

  private static func excerpt(_ statement: String) -> String {
    let flat = statement.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    return flat.count > 60 ? String(flat.prefix(60)) + "…" : flat
  }

  // MARK: - MongoDB

  /// Database commands that only read, for `db.runCommand` and `db.adminCommand` (MongoDB has no read-only mode for a
  /// connection).
  static let mongoReads: Set<String> = [
    "find", "aggregate", "count", "distinct", "listCollections", "listIndexes", "listDatabases", "dbStats",
    "collStats", "dataSize", "serverStatus", "buildInfo", "buildinfo", "hello", "isMaster", "ismaster", "ping",
    "explain", "getParameter", "connectionStatus", "hostInfo", "currentOp", "getLog", "getCmdLineOpts",
    "listCommands", "whatsmyuri", "replSetGetStatus", "top", "usersInfo", "rolesInfo", "getMore", "killCursors",
    "getDefaultRWConcern", "dbHash",
  ]

  /// Refuses a command document that can write: one not on the list, or an aggregate with `$out` or `$merge`.
  static func checkMongoCommand(_ command: BSONDocument) throws {
    guard let name = command.elements.first?.key else { return }
    guard mongoReads.contains(name) else {
      throw ReadOnlyError("MongoDB runs only commands that read here, and \(name) isn’t one.")
    }
    if name == "aggregate" {
      try checkMongoPipeline((command["pipeline"]?.arrayValue ?? []).compactMap(\.documentValue))
    }
    if name == "explain", let inner = command["explain"]?.documentValue {
      try checkMongoCommand(inner)
    }
  }

  /// Refuses a pipeline that writes its results (`$out`, `$merge`).
  static func checkMongoPipeline(_ stages: [BSONDocument]) throws {
    if let stage = stages.lazy.compactMap({ $0.elements.first?.key }).first(where: { $0 == "$out" || $0 == "$merge" }) {
      throw ReadOnlyError("\(stage) writes the pipeline’s results to a collection.")
    }
  }
}
