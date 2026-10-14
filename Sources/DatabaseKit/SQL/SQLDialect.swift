import Foundation
import WireKit

/// What differs between the SQL engines: quoting, literals, paging and the catalog.
protocol SQLDialect: Sendable {
  var engine: EngineKind { get }

  func quote(_ identifier: String) -> String
  func qualified(_ ref: ObjectRef) -> String
  func stringLiteral(_ text: String) -> String
  func bytesLiteral(_ bytes: [UInt8]) -> String
  func boolLiteral(_ value: Bool) -> String
  /// Casts a column to text for LIKE matching.
  func textCast(_ expression: String) -> String
  /// Case-insensitive LIKE.
  var likeOperator: String { get }
  /// A quoted LIKE pattern (with its ESCAPE clause where needed).
  func likePattern(_ text: String, prefix: Bool, suffix: Bool) -> String
  func lastDays(_ column: String, _ days: Int) -> String
  /// SELECT with paging; `orderBy` may be empty.
  func select(columns: String, from: String, where condition: String?, orderBy: String?, limit: Int, offset: Int)
    -> String

  // Catalog. Each query returns rows in the documented column order.
  /// (name)
  var databasesQuery: String? { get }
  /// (name) — nil when the engine has no schemas.
  func schemasQuery(database: String) -> String?
  /// (name, kind, estimated rows or NULL); kind is "table", "view" or "materialized view".
  func tablesQuery(database: String?, schema: String?) -> String
  /// (name, type, nullable bool/int/text, default, primary key bool/int, generated bool/int)
  func columnsQuery(_ ref: ObjectRef) -> String
  /// (column, target database, target schema, target table, target column) for keys going out.
  func outgoingKeysQuery(_ ref: ObjectRef) -> String?
  /// (column here, source database, source schema, source table, source column) for keys coming in.
  func incomingKeysQuery(_ ref: ObjectRef) -> String?
  func explain(_ sql: String) -> [String]

  var beginTransaction: String { get }
  var commit: String { get }
  var rollback: String { get }

  /// How an INSERT returns its key: appended clause, or a follow-up query.
  func insert(into table: String, columns: [String], values: [String], returning keys: [String]) -> String
  /// Run after an INSERT to read generated keys when the INSERT itself can't return them.
  func lastInsertKeyQuery(keys: [String]) -> String?
}

extension SQLDialect {
  func literal(_ value: CellValue, category: ValueCategory) -> String {
    switch value {
    case .unset: return "NULL"
    case .bson(let b): return stringLiteral(b.text(.extendedJSON))
    case .db(let v):
      switch v {
      case .null: return "NULL"
      case .bool(let b): return boolLiteral(b)
      case .int(let i): return String(i)
      case .double(let d): return d.isFinite ? String(d) : stringLiteral(String(d))
      case .decimal(let s):
        return category.isNumeric && Double(s) != nil ? s : stringLiteral(s)
      case .bytes(let b): return bytesLiteral(b)
      case .uuid(let u): return stringLiteral(u.uuidString.lowercased())
      case .text(let s), .json(let s):
        switch category {
        case .integer, .decimal, .float:
          let trimmed = s.trimmingCharacters(in: .whitespaces)
          return Double(trimmed) != nil ? trimmed : stringLiteral(s)
        case .boolean:
          switch s.lowercased() {
          case "true", "t", "yes", "1": return boolLiteral(true)
          case "false", "f", "no", "0": return boolLiteral(false)
          default: return stringLiteral(s)
          }
        default: return stringLiteral(s)
        }
      case .list, .map: return stringLiteral(v.displayText)
      }
    }
  }

  func escapeLike(_ text: String) -> String {
    text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "%", with: "\\%")
      .replacingOccurrences(of: "_", with: "\\_")
  }

  func likePattern(_ text: String, prefix: Bool, suffix: Bool) -> String {
    stringLiteral((prefix ? "%" : "") + escapeLike(text) + (suffix ? "%" : "")) + " ESCAPE " + stringLiteral("\\")
  }

  func defaultSelect(columns: String, from: String, where condition: String?, orderBy: String?, limit: Int, offset: Int)
    -> String
  {
    var sql = "SELECT \(columns) FROM \(from)"
    if let condition, !condition.isEmpty { sql += " WHERE \(condition)" }
    if let orderBy, !orderBy.isEmpty { sql += " ORDER BY \(orderBy)" }
    sql += " LIMIT \(limit)"
    if offset > 0 { sql += " OFFSET \(offset)" }
    return sql
  }

  func doubleQuote(_ identifier: String) -> String {
    "\"" + identifier.replacingOccurrences(of: "\"", with: "\"\"") + "\""
  }

  func singleQuote(_ text: String) -> String {
    "'" + text.replacingOccurrences(of: "'", with: "''") + "'"
  }
}

// MARK: - PostgreSQL

struct PostgresDialect: SQLDialect {
  let engine = EngineKind.postgres
  func quote(_ identifier: String) -> String { doubleQuote(identifier) }
  func qualified(_ ref: ObjectRef) -> String {
    [ref.schema, ref.name].compactMap { $0 }.map(quote).joined(separator: ".")
  }
  func stringLiteral(_ text: String) -> String { singleQuote(text) }
  func bytesLiteral(_ bytes: [UInt8]) -> String { "'\\x\(bytes.hexString)'::bytea" }
  func boolLiteral(_ value: Bool) -> String { value ? "TRUE" : "FALSE" }
  func textCast(_ expression: String) -> String { "\(expression)::text" }
  let likeOperator = "ILIKE"
  func lastDays(_ column: String, _ days: Int) -> String { "\(column) >= now() - interval '\(days) days'" }
  func select(columns: String, from: String, where condition: String?, orderBy: String?, limit: Int, offset: Int)
    -> String
  { defaultSelect(columns: columns, from: from, where: condition, orderBy: orderBy, limit: limit, offset: offset) }

  let databasesQuery: String? =
    "SELECT datname FROM pg_database WHERE NOT datistemplate AND datallowconn ORDER BY datname"
  func schemasQuery(database: String) -> String? {
    """
    SELECT nspname FROM pg_namespace
    WHERE nspname NOT LIKE 'pg\\_%' ESCAPE '\\' AND nspname <> 'information_schema' ORDER BY nspname = 'public' DESC, nspname
    """
  }
  func tablesQuery(database: String?, schema: String?) -> String {
    """
    SELECT c.relname, CASE c.relkind WHEN 'v' THEN 'view' WHEN 'm' THEN 'materialized view' ELSE 'table' END,
      CASE WHEN c.reltuples < 0 THEN NULL ELSE c.reltuples::bigint END
    FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE n.nspname = \(stringLiteral(schema ?? "public")) AND c.relkind IN ('r', 'v', 'm', 'p', 'f')
      AND NOT c.relispartition
    ORDER BY c.relname
    """
  }
  func regclass(_ ref: ObjectRef) -> String { stringLiteral(qualified(ref)) + "::regclass" }
  func columnsQuery(_ ref: ObjectRef) -> String {
    """
    SELECT a.attname, format_type(a.atttypid, a.atttypmod), NOT a.attnotnull, pg_get_expr(d.adbin, d.adrelid),
      COALESCE((SELECT true FROM pg_index i WHERE i.indrelid = a.attrelid AND i.indisprimary AND a.attnum = ANY(i.indkey)), false),
      (a.attidentity <> '' OR a.attgenerated <> '' OR COALESCE(pg_get_expr(d.adbin, d.adrelid), '') LIKE 'nextval(%')
    FROM pg_attribute a LEFT JOIN pg_attrdef d ON d.adrelid = a.attrelid AND d.adnum = a.attnum
    WHERE a.attrelid = \(regclass(ref)) AND a.attnum > 0 AND NOT a.attisdropped ORDER BY a.attnum
    """
  }
  func outgoingKeysQuery(_ ref: ObjectRef) -> String? {
    """
    SELECT a.attname, current_database(), fn.nspname, fc.relname, fa.attname
    FROM pg_constraint c
    CROSS JOIN LATERAL unnest(c.conkey, c.confkey) AS k(col, fcol)
    JOIN pg_attribute a ON a.attrelid = c.conrelid AND a.attnum = k.col
    JOIN pg_class fc ON fc.oid = c.confrelid JOIN pg_namespace fn ON fn.oid = fc.relnamespace
    JOIN pg_attribute fa ON fa.attrelid = c.confrelid AND fa.attnum = k.fcol
    WHERE c.contype = 'f' AND c.conrelid = \(regclass(ref))
    """
  }
  func incomingKeysQuery(_ ref: ObjectRef) -> String? {
    """
    SELECT fa.attname, current_database(), sn.nspname, sc.relname, a.attname
    FROM pg_constraint c
    CROSS JOIN LATERAL unnest(c.conkey, c.confkey) AS k(col, fcol)
    JOIN pg_attribute a ON a.attrelid = c.conrelid AND a.attnum = k.col
    JOIN pg_class sc ON sc.oid = c.conrelid JOIN pg_namespace sn ON sn.oid = sc.relnamespace
    JOIN pg_attribute fa ON fa.attrelid = c.confrelid AND fa.attnum = k.fcol
    WHERE c.contype = 'f' AND c.confrelid = \(regclass(ref))
    """
  }
  func explain(_ sql: String) -> [String] { ["EXPLAIN \(sql)"] }
  let beginTransaction = "BEGIN"
  let commit = "COMMIT"
  let rollback = "ROLLBACK"
  func insert(into table: String, columns: [String], values: [String], returning keys: [String]) -> String {
    var sql = "INSERT INTO \(table) "
    sql += columns.isEmpty ? "DEFAULT VALUES" : "(\(columns.joined(separator: ", "))) VALUES (\(values.joined(separator: ", ")))"
    if !keys.isEmpty { sql += " RETURNING \(keys.map(quote).joined(separator: ", "))" }
    return sql
  }
  func lastInsertKeyQuery(keys: [String]) -> String? { nil }
}

// MARK: - MySQL and MariaDB

struct MySQLDialect: SQLDialect {
  let engine: EngineKind
  func quote(_ identifier: String) -> String { "`" + identifier.replacingOccurrences(of: "`", with: "``") + "`" }
  func qualified(_ ref: ObjectRef) -> String {
    [ref.database, ref.name].compactMap { $0 }.filter { !$0.isEmpty }.map(quote).joined(separator: ".")
  }
  func stringLiteral(_ text: String) -> String {
    "'" + text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "'", with: "''") + "'"
  }
  func bytesLiteral(_ bytes: [UInt8]) -> String { bytes.isEmpty ? "''" : "X'\(bytes.hexString)'" }
  func boolLiteral(_ value: Bool) -> String { value ? "TRUE" : "FALSE" }
  func textCast(_ expression: String) -> String { "CAST(\(expression) AS CHAR)" }
  let likeOperator = "LIKE"
  func lastDays(_ column: String, _ days: Int) -> String { "\(column) >= NOW() - INTERVAL \(days) DAY" }
  func select(columns: String, from: String, where condition: String?, orderBy: String?, limit: Int, offset: Int)
    -> String
  { defaultSelect(columns: columns, from: from, where: condition, orderBy: orderBy, limit: limit, offset: offset) }
  /// MySQL wants the escape character itself written as '\\'.
  func likePattern(_ text: String, prefix: Bool, suffix: Bool) -> String {
    stringLiteral((prefix ? "%" : "") + escapeLike(text) + (suffix ? "%" : ""))
  }

  let databasesQuery: String? = "SELECT SCHEMA_NAME FROM information_schema.SCHEMATA ORDER BY SCHEMA_NAME"
  func schemasQuery(database: String) -> String? { nil }
  func tablesQuery(database: String?, schema: String?) -> String {
    """
    SELECT TABLE_NAME, CASE WHEN TABLE_TYPE = 'VIEW' THEN 'view' ELSE 'table' END, TABLE_ROWS
    FROM information_schema.TABLES WHERE TABLE_SCHEMA = \(stringLiteral(database ?? "")) ORDER BY TABLE_NAME
    """
  }
  func columnsQuery(_ ref: ObjectRef) -> String {
    """
    SELECT COLUMN_NAME, COLUMN_TYPE, IS_NULLABLE = 'YES', COLUMN_DEFAULT, COLUMN_KEY = 'PRI',
      EXTRA LIKE '%auto_increment%' OR EXTRA LIKE '%GENERATED%'
    FROM information_schema.COLUMNS
    WHERE TABLE_SCHEMA = \(stringLiteral(ref.database ?? "")) AND TABLE_NAME = \(stringLiteral(ref.name))
    ORDER BY ORDINAL_POSITION
    """
  }
  func outgoingKeysQuery(_ ref: ObjectRef) -> String? {
    """
    SELECT COLUMN_NAME, REFERENCED_TABLE_SCHEMA, NULL, REFERENCED_TABLE_NAME, REFERENCED_COLUMN_NAME
    FROM information_schema.KEY_COLUMN_USAGE
    WHERE TABLE_SCHEMA = \(stringLiteral(ref.database ?? "")) AND TABLE_NAME = \(stringLiteral(ref.name))
      AND REFERENCED_TABLE_NAME IS NOT NULL
    """
  }
  func incomingKeysQuery(_ ref: ObjectRef) -> String? {
    """
    SELECT REFERENCED_COLUMN_NAME, TABLE_SCHEMA, NULL, TABLE_NAME, COLUMN_NAME
    FROM information_schema.KEY_COLUMN_USAGE
    WHERE REFERENCED_TABLE_SCHEMA = \(stringLiteral(ref.database ?? "")) AND REFERENCED_TABLE_NAME = \(stringLiteral(ref.name))
    """
  }
  func explain(_ sql: String) -> [String] { [engine == .mysql ? "EXPLAIN FORMAT=TREE \(sql)" : "EXPLAIN \(sql)"] }
  let beginTransaction = "START TRANSACTION"
  let commit = "COMMIT"
  let rollback = "ROLLBACK"
  func insert(into table: String, columns: [String], values: [String], returning keys: [String]) -> String {
    var sql = "INSERT INTO \(table) (\(columns.joined(separator: ", "))) VALUES (\(values.joined(separator: ", ")))"
    if engine == .mariadb, !keys.isEmpty { sql += " RETURNING \(keys.map(quote).joined(separator: ", "))" }
    return sql
  }
  func lastInsertKeyQuery(keys: [String]) -> String? {
    engine == .mysql && keys.count == 1 ? "SELECT LAST_INSERT_ID() AS \(quote(keys[0]))" : nil
  }
}

// MARK: - SQL Server

struct SQLServerDialect: SQLDialect {
  let engine = EngineKind.sqlserver
  func quote(_ identifier: String) -> String { "[" + identifier.replacingOccurrences(of: "]", with: "]]") + "]" }
  func qualified(_ ref: ObjectRef) -> String {
    [ref.database, ref.schema ?? "dbo", ref.name].compactMap { $0 }.filter { !$0.isEmpty }.map(quote)
      .joined(separator: ".")
  }
  func stringLiteral(_ text: String) -> String { "N" + singleQuote(text) }
  func bytesLiteral(_ bytes: [UInt8]) -> String { "0x" + bytes.hexString.uppercased() }
  func boolLiteral(_ value: Bool) -> String { value ? "1" : "0" }
  func textCast(_ expression: String) -> String { "CAST(\(expression) AS NVARCHAR(MAX))" }
  let likeOperator = "LIKE"
  func lastDays(_ column: String, _ days: Int) -> String { "\(column) >= DATEADD(day, -\(days), SYSDATETIME())" }
  func likePattern(_ text: String, prefix: Bool, suffix: Bool) -> String {
    // SQL Server has no backslash escaping in LIKE by default; bracket the wildcards.
    let escaped = text.replacingOccurrences(of: "[", with: "[[]").replacingOccurrences(of: "%", with: "[%]")
      .replacingOccurrences(of: "_", with: "[_]")
    return stringLiteral((prefix ? "%" : "") + escaped + (suffix ? "%" : ""))
  }
  func select(columns: String, from: String, where condition: String?, orderBy: String?, limit: Int, offset: Int)
    -> String
  {
    var sql = "SELECT \(columns) FROM \(from)"
    if let condition, !condition.isEmpty { sql += " WHERE \(condition)" }
    sql += " ORDER BY \(orderBy?.isEmpty == false ? orderBy! : "(SELECT NULL)")"
    sql += " OFFSET \(offset) ROWS FETCH NEXT \(limit) ROWS ONLY"
    return sql
  }

  let databasesQuery: String? = "SELECT name FROM sys.databases WHERE state = 0 ORDER BY CASE WHEN database_id > 4 THEN 0 ELSE 1 END, name"
  func schemasQuery(database: String) -> String? {
    let db = quote(database)
    return """
      SELECT s.name FROM \(db).sys.schemas s
      WHERE s.name = 'dbo' OR EXISTS (SELECT 1 FROM \(db).sys.objects o WHERE o.schema_id = s.schema_id AND o.type IN ('U', 'V'))
      ORDER BY CASE WHEN s.name = 'dbo' THEN 0 ELSE 1 END, s.name
      """
  }
  func tablesQuery(database: String?, schema: String?) -> String {
    let db = quote(database ?? "master")
    return """
      SELECT o.name, CASE o.type WHEN 'V' THEN 'view' ELSE 'table' END,
        (SELECT SUM(p.rows) FROM \(db).sys.partitions p WHERE p.object_id = o.object_id AND p.index_id IN (0, 1))
      FROM \(db).sys.objects o JOIN \(db).sys.schemas s ON s.schema_id = o.schema_id
      WHERE s.name = \(stringLiteral(schema ?? "dbo")) AND o.type IN ('U', 'V') AND o.is_ms_shipped = 0
      ORDER BY o.name
      """
  }
  func columnsQuery(_ ref: ObjectRef) -> String {
    let db = quote(ref.database ?? "master")
    return """
      SELECT c.name,
        t.name + CASE
          WHEN t.name IN ('varchar', 'char', 'varbinary', 'binary') THEN '(' + CASE WHEN c.max_length = -1 THEN 'max' ELSE CAST(c.max_length AS varchar(10)) END + ')'
          WHEN t.name IN ('nvarchar', 'nchar') THEN '(' + CASE WHEN c.max_length = -1 THEN 'max' ELSE CAST(c.max_length / 2 AS varchar(10)) END + ')'
          WHEN t.name IN ('decimal', 'numeric') THEN '(' + CAST(c.precision AS varchar(5)) + ',' + CAST(c.scale AS varchar(5)) + ')'
          ELSE '' END,
        c.is_nullable, dc.definition,
        CASE WHEN EXISTS (SELECT 1 FROM \(db).sys.index_columns ic JOIN \(db).sys.indexes i
          ON i.object_id = ic.object_id AND i.index_id = ic.index_id
          WHERE i.is_primary_key = 1 AND ic.object_id = c.object_id AND ic.column_id = c.column_id) THEN 1 ELSE 0 END,
        CASE WHEN c.is_identity = 1 OR c.is_computed = 1 OR t.name = 'timestamp' THEN 1 ELSE 0 END
      FROM \(db).sys.columns c
      JOIN \(db).sys.types t ON t.user_type_id = c.user_type_id
      LEFT JOIN \(db).sys.default_constraints dc ON dc.object_id = c.default_object_id
      WHERE c.object_id = OBJECT_ID(\(stringLiteral(qualified(ref))))
      ORDER BY c.column_id
      """
  }
  func outgoingKeysQuery(_ ref: ObjectRef) -> String? {
    let db = quote(ref.database ?? "master")
    return """
      SELECT pc.name, \(stringLiteral(ref.database ?? "")), rs.name, rt.name, rc.name
      FROM \(db).sys.foreign_key_columns fkc
      JOIN \(db).sys.columns pc ON pc.object_id = fkc.parent_object_id AND pc.column_id = fkc.parent_column_id
      JOIN \(db).sys.tables rt ON rt.object_id = fkc.referenced_object_id
      JOIN \(db).sys.schemas rs ON rs.schema_id = rt.schema_id
      JOIN \(db).sys.columns rc ON rc.object_id = fkc.referenced_object_id AND rc.column_id = fkc.referenced_column_id
      WHERE fkc.parent_object_id = OBJECT_ID(\(stringLiteral(qualified(ref))))
      """
  }
  func incomingKeysQuery(_ ref: ObjectRef) -> String? {
    let db = quote(ref.database ?? "master")
    return """
      SELECT rc.name, \(stringLiteral(ref.database ?? "")), ps.name, pt.name, pc.name
      FROM \(db).sys.foreign_key_columns fkc
      JOIN \(db).sys.columns pc ON pc.object_id = fkc.parent_object_id AND pc.column_id = fkc.parent_column_id
      JOIN \(db).sys.tables pt ON pt.object_id = fkc.parent_object_id
      JOIN \(db).sys.schemas ps ON ps.schema_id = pt.schema_id
      JOIN \(db).sys.columns rc ON rc.object_id = fkc.referenced_object_id AND rc.column_id = fkc.referenced_column_id
      WHERE fkc.referenced_object_id = OBJECT_ID(\(stringLiteral(qualified(ref))))
      """
  }
  func explain(_ sql: String) -> [String] { ["SET SHOWPLAN_TEXT ON", sql, "SET SHOWPLAN_TEXT OFF"] }
  let beginTransaction = "BEGIN TRANSACTION"
  let commit = "COMMIT"
  let rollback = "ROLLBACK"
  func insert(into table: String, columns: [String], values: [String], returning keys: [String]) -> String {
    let output = keys.isEmpty ? "" : " OUTPUT " + keys.map { "INSERTED.\(quote($0))" }.joined(separator: ", ")
    if columns.isEmpty { return "INSERT INTO \(table)\(output) DEFAULT VALUES" }
    return "INSERT INTO \(table) (\(columns.joined(separator: ", ")))\(output) VALUES (\(values.joined(separator: ", ")))"
  }
  func lastInsertKeyQuery(keys: [String]) -> String? { nil }
}

// MARK: - SQLite

struct SQLiteDialect: SQLDialect {
  let engine = EngineKind.sqlite
  func quote(_ identifier: String) -> String { doubleQuote(identifier) }
  func qualified(_ ref: ObjectRef) -> String { quote(ref.name) }
  func stringLiteral(_ text: String) -> String { singleQuote(text) }
  func bytesLiteral(_ bytes: [UInt8]) -> String { "X'\(bytes.hexString)'" }
  func boolLiteral(_ value: Bool) -> String { value ? "1" : "0" }
  func textCast(_ expression: String) -> String { "CAST(\(expression) AS TEXT)" }
  let likeOperator = "LIKE"
  func lastDays(_ column: String, _ days: Int) -> String { "\(column) >= datetime('now', '-\(days) days')" }
  func select(columns: String, from: String, where condition: String?, orderBy: String?, limit: Int, offset: Int)
    -> String
  { defaultSelect(columns: columns, from: from, where: condition, orderBy: orderBy, limit: limit, offset: offset) }
  let databasesQuery: String? = nil
  func schemasQuery(database: String) -> String? { nil }
  func tablesQuery(database: String?, schema: String?) -> String {
    "SELECT name, type, NULL FROM sqlite_schema WHERE type IN ('table', 'view') AND name NOT LIKE 'sqlite\\_%' ESCAPE '\\' ORDER BY name"
  }
  func columnsQuery(_ ref: ObjectRef) -> String {
    // pk > 0 marks key columns; hidden 2/3 are generated columns.
    "SELECT name, type, \"notnull\" = 0, dflt_value, pk > 0, hidden IN (2, 3) FROM pragma_table_xinfo(\(stringLiteral(ref.name)))"
  }
  func outgoingKeysQuery(_ ref: ObjectRef) -> String? {
    "SELECT \"from\", NULL, NULL, \"table\", \"to\" FROM pragma_foreign_key_list(\(stringLiteral(ref.name)))"
  }
  func incomingKeysQuery(_ ref: ObjectRef) -> String? {
    """
    SELECT f."to", NULL, NULL, m.name, f."from" FROM sqlite_schema m, pragma_foreign_key_list(m.name) f
    WHERE m.type = 'table' AND f."table" = \(stringLiteral(ref.name))
    """
  }
  func explain(_ sql: String) -> [String] { ["EXPLAIN QUERY PLAN \(sql)"] }
  let beginTransaction = "BEGIN"
  let commit = "COMMIT"
  let rollback = "ROLLBACK"
  func insert(into table: String, columns: [String], values: [String], returning keys: [String]) -> String {
    var sql = "INSERT INTO \(table) "
    sql += columns.isEmpty ? "DEFAULT VALUES" : "(\(columns.joined(separator: ", "))) VALUES (\(values.joined(separator: ", ")))"
    if !keys.isEmpty { sql += " RETURNING \(keys.map(quote).joined(separator: ", "))" }
    return sql
  }
  func lastInsertKeyQuery(keys: [String]) -> String? { nil }
}

// MARK: - DuckDB

struct DuckDBDialect: SQLDialect {
  let engine = EngineKind.duckdb
  func quote(_ identifier: String) -> String { doubleQuote(identifier) }
  func qualified(_ ref: ObjectRef) -> String {
    if ref.kind == .file { return Self.fileSource(ref.name) }
    return [ref.database, ref.schema, ref.name].compactMap { $0 }.filter { !$0.isEmpty }.map(quote).joined(separator: ".")
  }
  /// Data files are read in place.
  static func fileSource(_ path: String) -> String {
    let quoted = "'" + path.replacingOccurrences(of: "'", with: "''") + "'"
    switch (path as NSString).pathExtension.lowercased() {
    case "parquet": return "read_parquet(\(quoted))"
    case "csv", "tsv": return "read_csv_auto(\(quoted))"
    case "json", "jsonl", "ndjson": return "read_json_auto(\(quoted))"
    default: return quoted
    }
  }
  func stringLiteral(_ text: String) -> String { singleQuote(text) }
  func bytesLiteral(_ bytes: [UInt8]) -> String { "'" + bytes.map { String(format: "\\x%02X", $0) }.joined() + "'::BLOB" }
  func boolLiteral(_ value: Bool) -> String { value ? "TRUE" : "FALSE" }
  func textCast(_ expression: String) -> String { "CAST(\(expression) AS VARCHAR)" }
  let likeOperator = "ILIKE"
  func lastDays(_ column: String, _ days: Int) -> String { "\(column) >= now() - INTERVAL \(days) DAY" }
  func select(columns: String, from: String, where condition: String?, orderBy: String?, limit: Int, offset: Int)
    -> String
  { defaultSelect(columns: columns, from: from, where: condition, orderBy: orderBy, limit: limit, offset: offset) }
  let databasesQuery: String? =
    "SELECT database_name FROM duckdb_databases() WHERE NOT internal ORDER BY database_name"
  func schemasQuery(database: String) -> String? {
    """
    SELECT schema_name FROM duckdb_schemas() WHERE database_name = \(stringLiteral(database)) AND NOT internal
    ORDER BY schema_name = 'main' DESC, schema_name
    """
  }
  func tablesQuery(database: String?, schema: String?) -> String {
    let db = stringLiteral(database ?? "memory")
    let s = stringLiteral(schema ?? "main")
    return """
      SELECT table_name, 'table', estimated_size FROM duckdb_tables() WHERE database_name = \(db) AND schema_name = \(s)
      UNION ALL
      SELECT view_name, 'view', NULL FROM duckdb_views() WHERE database_name = \(db) AND schema_name = \(s) AND NOT internal
      ORDER BY 1
      """
  }
  func columnsQuery(_ ref: ObjectRef) -> String {
    if ref.kind == .file {
      return "SELECT column_name, column_type, true, NULL, false, false FROM (DESCRIBE SELECT * FROM \(qualified(ref)))"
    }
    let db = stringLiteral(ref.database ?? "memory")
    let s = stringLiteral(ref.schema ?? "main")
    let t = stringLiteral(ref.name)
    return """
      SELECT c.column_name, c.data_type, c.is_nullable, c.column_default,
        EXISTS (SELECT 1 FROM duckdb_constraints() k WHERE k.database_name = \(db) AND k.schema_name = \(s)
          AND k.table_name = \(t) AND k.constraint_type = 'PRIMARY KEY' AND list_contains(k.constraint_column_names, c.column_name)),
        false
      FROM duckdb_columns() c WHERE c.database_name = \(db) AND c.schema_name = \(s) AND c.table_name = \(t)
      ORDER BY c.column_index
      """
  }
  func outgoingKeysQuery(_ ref: ObjectRef) -> String? { nil }
  func incomingKeysQuery(_ ref: ObjectRef) -> String? { nil }
  func explain(_ sql: String) -> [String] { ["EXPLAIN \(sql)"] }
  let beginTransaction = "BEGIN TRANSACTION"
  let commit = "COMMIT"
  let rollback = "ROLLBACK"
  func insert(into table: String, columns: [String], values: [String], returning keys: [String]) -> String {
    var sql = "INSERT INTO \(table) "
    sql += columns.isEmpty ? "DEFAULT VALUES" : "(\(columns.joined(separator: ", "))) VALUES (\(values.joined(separator: ", ")))"
    if !keys.isEmpty { sql += " RETURNING \(keys.map(quote).joined(separator: ", "))" }
    return sql
  }
  func lastInsertKeyQuery(keys: [String]) -> String? { nil }
}
