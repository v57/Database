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
  let api: DuckDBAPI
  nonisolated(unsafe) private var database: duckdb_database?
  nonisolated(unsafe) private var connection: duckdb_connection?

  /// Opens (or creates) the file at `path`; `nil` opens an in-memory database. Throws `DuckDBError.notInstalled`
  /// until the library has been downloaded (see `DuckDBInstaller`).
  public init(path: String?, readOnly: Bool = false) throws {
    api = try DuckDBLibrary.api()
    self.path = path
    self.readOnly = readOnly
    var config: duckdb_config?
    guard api.create_config(&config) == DuckDBSuccess else { throw DuckDBError(message: "Couldn't configure DuckDB") }
    defer { api.destroy_config(&config) }
    if readOnly, path != nil { _ = api.set_config(config, "access_mode", "READ_ONLY") }
    var db: duckdb_database?
    var errorPointer: UnsafeMutablePointer<CChar>?
    let state = api.open_ext(Array((path ?? ":memory:").utf8CString), &db, config, &errorPointer)
    if state != DuckDBSuccess {
      let message = errorPointer.map { String(cString: $0) } ?? "Couldn't open the database"
      if let errorPointer { api.free(errorPointer) }
      throw DuckDBError(message: message)
    }
    var con: duckdb_connection?
    guard api.connect(db, &con) == DuckDBSuccess else {
      api.close(&db)
      throw DuckDBError(message: "Couldn't connect to DuckDB")
    }
    database = db
    connection = con
  }

  public func close() {
    if connection != nil { api.disconnect(&connection) }
    if database != nil { api.close(&database) }
  }

  deinit {
    if connection != nil { api.disconnect(&connection) }
    if database != nil { api.close(&database) }
  }

  public var isOpen: Bool { connection != nil }

  /// The loaded library's version ("1.5.6").
  public var libraryVersion: String { api.version }

  /// Runs SQL (several statements allowed) and returns the last statement's result.
  public func query(_ sql: String, maxRows: Int = 100_000) throws -> DBResult {
    guard let connection else { throw DuckDBError(message: "The database is closed") }
    var result = duckdb_result()
    let state = api.query(connection, Array(sql.utf8CString), &result)
    defer { api.destroy_result(&result) }
    if state != DuckDBSuccess {
      let message = api.result_error(&result).map { String(cString: $0) } ?? "Query failed"
      throw DuckDBError(message: message)
    }
    return DuckDBVectors(api: api).read(&result, maxRows: maxRows)
  }

  /// The SQL name of a type without parameters ("INTEGER", "LIST", "DECIMAL").
  static func typeName(_ type: duckdb_type) -> String {
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
    case DUCKDB_TYPE_DECIMAL: return "DECIMAL"
    default: return "TYPE \(type.rawValue)"
    }
  }
}
