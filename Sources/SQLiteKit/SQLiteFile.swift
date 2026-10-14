import Foundation
import SQLite3
import WireKit

public struct SQLiteError: Error, LocalizedError, Sendable {
  public var code: Int32
  public var message: String
  public var errorDescription: String? { message }
}

/// A SQLite database file.
public actor SQLiteFile {
  public let path: String
  public let readOnly: Bool
  nonisolated(unsafe) private var handle: OpaquePointer?

  public init(path: String, readOnly: Bool = false, create: Bool = true) throws {
    self.path = path
    self.readOnly = readOnly
    var db: OpaquePointer?
    var flags = SQLITE_OPEN_FULLMUTEX
    flags |= readOnly ? SQLITE_OPEN_READONLY : (SQLITE_OPEN_READWRITE | (create ? SQLITE_OPEN_CREATE : 0))
    let rc = sqlite3_open_v2(path, &db, flags, nil)
    if rc != SQLITE_OK {
      let message = db.map { String(cString: sqlite3_errmsg($0)) } ?? "Couldn't open \(path)"
      sqlite3_close(db)
      throw SQLiteError(code: rc, message: message)
    }
    sqlite3_busy_timeout(db, 5000)
    sqlite3_exec(db, "PRAGMA foreign_keys = ON", nil, nil, nil)
    handle = db
  }

  deinit { sqlite3_close_v2(handle) }

  public func close() {
    sqlite3_close_v2(handle)
    handle = nil
  }

  public var isOpen: Bool { handle != nil }

  private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

  /// Runs every statement in `sql`; returns one result per statement.
  public func query(_ sql: String, maxRows: Int = 100_000) throws -> [DBResult] {
    guard let db = handle else { throw SQLiteError(code: SQLITE_MISUSE, message: "The database is closed") }
    var results: [DBResult] = []
    try sql.withCString { start in
      var tail: UnsafePointer<CChar>? = start
      while let current = tail, current.pointee != 0 {
        var statement: OpaquePointer?
        let rc = sqlite3_prepare_v2(db, current, -1, &statement, &tail)
        if rc != SQLITE_OK { throw SQLiteError(code: rc, message: String(cString: sqlite3_errmsg(db))) }
        guard let statement else { continue }  // whitespace or a comment
        defer { sqlite3_finalize(statement) }
        results.append(try run(statement, db: db, maxRows: maxRows))
      }
    }
    return results
  }

  public func execute(_ sql: String) throws -> DBResult { try query(sql).last ?? DBResult() }

  private func run(_ statement: OpaquePointer, db: OpaquePointer, maxRows: Int) throws -> DBResult {
    let columnCount = Int(sqlite3_column_count(statement))
    var result = DBResult()
    for i in 0..<columnCount {
      let name = String(cString: sqlite3_column_name(statement, Int32(i)))
      let declared = sqlite3_column_decltype(statement, Int32(i)).map { String(cString: $0) } ?? ""
      let table = sqlite3_column_table_name(statement, Int32(i)).map { String(cString: $0) }
      result.columns.append(DBColumn(name: name, typeName: declared.isEmpty ? "any" : declared.lowercased(), table: table))
    }
    let changesBefore = sqlite3_total_changes(db)
    var truncated = false
    while true {
      let rc = sqlite3_step(statement)
      if rc == SQLITE_DONE { break }
      guard rc == SQLITE_ROW else { throw SQLiteError(code: rc, message: String(cString: sqlite3_errmsg(db))) }
      if result.rows.count >= maxRows {
        truncated = true
        break
      }
      var row: [DBValue] = []
      row.reserveCapacity(columnCount)
      for i in 0..<Int32(columnCount) {
        switch sqlite3_column_type(statement, i) {
        case SQLITE_NULL: row.append(.null)
        case SQLITE_INTEGER: row.append(.int(sqlite3_column_int64(statement, i)))
        case SQLITE_FLOAT: row.append(.double(sqlite3_column_double(statement, i)))
        case SQLITE_BLOB:
          let count = Int(sqlite3_column_bytes(statement, i))
          if let pointer = sqlite3_column_blob(statement, i) {
            row.append(.bytes(Array(UnsafeRawBufferPointer(start: pointer, count: count))))
          } else {
            row.append(.bytes([]))
          }
        default:
          row.append(.text(String(cString: sqlite3_column_text(statement, i))))
        }
      }
      result.rows.append(row)
    }
    if columnCount == 0 || sqlite3_stmt_readonly(statement) == 0 {
      let changed = Int(sqlite3_total_changes(db) - changesBefore)
      if columnCount == 0 { result.affectedRows = changed }
    }
    if truncated { result.messages.append("Showing the first \(maxRows) rows") }
    return result
  }

  public var lastInsertRowID: Int64 { sqlite3_last_insert_rowid(handle) }
}
