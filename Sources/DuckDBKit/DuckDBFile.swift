import Cduckdb
import Foundation
import WireKit

public struct DuckDBError: Error, LocalizedError, Sendable {
  public var message: String
  public var errorDescription: String? { message }
}

/// An embedded DuckDB database: a `.duckdb` file, or an in-memory one for reading
/// Parquet, CSV and JSON files directly.
public actor DuckDBFile {
  public let path: String?
  public let readOnly: Bool
  nonisolated(unsafe) private var database: duckdb_database?
  nonisolated(unsafe) private var connection: duckdb_connection?

  /// Opens (or creates) the file at `path`; `nil` opens an in-memory database.
  public init(path: String?, readOnly: Bool = false) throws {
    self.path = path
    self.readOnly = readOnly
    var config: duckdb_config?
    guard duckdb_create_config(&config) == DuckDBSuccess else { throw DuckDBError(message: "Couldn't configure DuckDB") }
    defer { duckdb_destroy_config(&config) }
    if readOnly, path != nil { duckdb_set_config(config, "access_mode", "READ_ONLY") }
    var db: duckdb_database?
    var errorPointer: UnsafeMutablePointer<CChar>?
    let state = (path ?? ":memory:").withCString { duckdb_open_ext($0, &db, config, &errorPointer) }
    if state != DuckDBSuccess {
      let message = errorPointer.map { String(cString: $0) } ?? "Couldn't open the database"
      if let errorPointer { duckdb_free(errorPointer) }
      throw DuckDBError(message: message)
    }
    var con: duckdb_connection?
    guard duckdb_connect(db, &con) == DuckDBSuccess else {
      duckdb_close(&db)
      throw DuckDBError(message: "Couldn't connect to DuckDB")
    }
    database = db
    connection = con
  }

  public func close() {
    if connection != nil { duckdb_disconnect(&connection) }
    if database != nil { duckdb_close(&database) }
  }

  deinit {
    if connection != nil { duckdb_disconnect(&connection) }
    if database != nil { duckdb_close(&database) }
  }

  public var isOpen: Bool { connection != nil }

  /// Runs SQL (several statements allowed) and returns the last statement's result.
  public func query(_ sql: String, maxRows: Int = 100_000) throws -> DBResult {
    guard let connection else { throw DuckDBError(message: "The database is closed") }
    var result = duckdb_result()
    let state = sql.withCString { duckdb_query(connection, $0, &result) }
    defer { duckdb_destroy_result(&result) }
    if state != DuckDBSuccess {
      let message = duckdb_result_error(&result).map { String(cString: $0) } ?? "Query failed"
      throw DuckDBError(message: message)
    }
    return DuckDBVectors.read(&result, maxRows: maxRows)
  }

  static func read(_ result: inout duckdb_result, maxRows: Int) -> DBResult {
    let columnCount = Int(duckdb_column_count(&result))
    let rowCount = Int(duckdb_row_count(&result))
    var columns: [DBColumn] = []
    var types: [duckdb_type] = []
    for c in 0..<columnCount {
      let name = duckdb_column_name(&result, idx_t(c)).map { String(cString: $0) } ?? "?"
      let type = duckdb_column_type(&result, idx_t(c))
      var logical = duckdb_column_logical_type(&result, idx_t(c))
      let typeName = typeName(type, logical: logical)
      duckdb_destroy_logical_type(&logical)
      columns.append(DBColumn(name: name, typeName: typeName))
      types.append(type)
    }
    var out = DBResult(columns: columns)
    // A statement without a result set (or an empty column set) reports changed rows.
    let isChange = columnCount == 1 && columns.first?.name == "Count" && types.first == DUCKDB_TYPE_BIGINT
    for row in 0..<min(rowCount, maxRows) {
      var values: [DBValue] = []
      values.reserveCapacity(columnCount)
      for c in 0..<columnCount {
        values.append(value(&result, column: c, row: row, type: types[c]))
      }
      out.rows.append(values)
    }
    let changed = Int(duckdb_rows_changed(&result))
    if isChange || changed > 0 {
      out.affectedRows = isChange ? Int(out.rows.first?.first?.intValue ?? Int64(changed)) : changed
    }
    if rowCount > maxRows { out.messages.append("Showing the first \(maxRows) of \(rowCount) rows") }
    return out
  }

  static func value(_ result: inout duckdb_result, column: Int, row: Int, type: duckdb_type) -> DBValue {
    let c = idx_t(column)
    let r = idx_t(row)
    if duckdb_value_is_null(&result, c, r) { return .null }
    switch type {
    case DUCKDB_TYPE_BOOLEAN: return .bool(duckdb_value_boolean(&result, c, r))
    case DUCKDB_TYPE_TINYINT, DUCKDB_TYPE_SMALLINT, DUCKDB_TYPE_INTEGER, DUCKDB_TYPE_BIGINT, DUCKDB_TYPE_UTINYINT,
      DUCKDB_TYPE_USMALLINT, DUCKDB_TYPE_UINTEGER:
      return .int(duckdb_value_int64(&result, c, r))
    case DUCKDB_TYPE_FLOAT, DUCKDB_TYPE_DOUBLE: return .double(duckdb_value_double(&result, c, r))
    case DUCKDB_TYPE_UBIGINT, DUCKDB_TYPE_HUGEINT, DUCKDB_TYPE_UHUGEINT, DUCKDB_TYPE_DECIMAL:
      return .decimal(varchar(&result, c, r))
    case DUCKDB_TYPE_BLOB:
      let blob = duckdb_value_blob(&result, c, r)
      defer { duckdb_free(blob.data) }
      guard let data = blob.data else { return .bytes([]) }
      return .bytes(Array(UnsafeRawBufferPointer(start: data, count: Int(blob.size))))
    case DUCKDB_TYPE_UUID:
      let text = varchar(&result, c, r)
      return UUID(uuidString: text).map(DBValue.uuid) ?? .text(text)
    default:
      return .text(varchar(&result, c, r))
    }
  }

  static func varchar(_ result: inout duckdb_result, _ c: idx_t, _ r: idx_t) -> String {
    guard let pointer = duckdb_value_varchar(&result, c, r) else { return "" }
    defer { duckdb_free(pointer) }
    return String(cString: pointer)
  }

  static func typeName(_ type: duckdb_type, logical: duckdb_logical_type?) -> String {
    switch type {
    case DUCKDB_TYPE_BOOLEAN: return "BOOLEAN"
    case DUCKDB_TYPE_TINYINT: return "TINYINT"
    case DUCKDB_TYPE_SMALLINT: return "SMALLINT"
    case DUCKDB_TYPE_INTEGER: return "INTEGER"
    case DUCKDB_TYPE_BIGINT: return "BIGINT"
    case DUCKDB_TYPE_UTINYINT: return "UTINYINT"
    case DUCKDB_TYPE_USMALLINT: return "USMALLINT"
    case DUCKDB_TYPE_UINTEGER: return "UINTEGER"
    case DUCKDB_TYPE_UBIGINT: return "UBIGINT"
    case DUCKDB_TYPE_HUGEINT: return "HUGEINT"
    case DUCKDB_TYPE_UHUGEINT: return "UHUGEINT"
    case DUCKDB_TYPE_FLOAT: return "FLOAT"
    case DUCKDB_TYPE_DOUBLE: return "DOUBLE"
    case DUCKDB_TYPE_TIMESTAMP: return "TIMESTAMP"
    case DUCKDB_TYPE_TIMESTAMP_TZ: return "TIMESTAMPTZ"
    case DUCKDB_TYPE_DATE: return "DATE"
    case DUCKDB_TYPE_TIME: return "TIME"
    case DUCKDB_TYPE_INTERVAL: return "INTERVAL"
    case DUCKDB_TYPE_VARCHAR: return "VARCHAR"
    case DUCKDB_TYPE_BLOB: return "BLOB"
    case DUCKDB_TYPE_UUID: return "UUID"
    case DUCKDB_TYPE_ENUM: return "ENUM"
    case DUCKDB_TYPE_LIST: return "LIST"
    case DUCKDB_TYPE_STRUCT: return "STRUCT"
    case DUCKDB_TYPE_MAP: return "MAP"
    case DUCKDB_TYPE_ARRAY: return "ARRAY"
    case DUCKDB_TYPE_UNION: return "UNION"
    case DUCKDB_TYPE_BIT: return "BIT"
    case DUCKDB_TYPE_DECIMAL:
      guard let logical else { return "DECIMAL" }
      return "DECIMAL(\(duckdb_decimal_width(logical)),\(duckdb_decimal_scale(logical)))"
    default: return "TYPE \(type.rawValue)"
    }
  }
}
