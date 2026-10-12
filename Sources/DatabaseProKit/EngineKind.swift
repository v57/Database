import Foundation

/// The ten engines Database Pro speaks.
public enum EngineKind: String, Codable, CaseIterable, Identifiable, Sendable {
  case postgres, mysql, mariadb, sqlserver, sqlite, duckdb, mongodb, redis, cassandra, scylla

  public var id: String { rawValue }

  public enum Family: Sendable { case sql, document, keyValue, wideColumn }

  public var family: Family {
    switch self {
    case .postgres, .mysql, .mariadb, .sqlserver, .sqlite, .duckdb: .sql
    case .mongodb: .document
    case .redis: .keyValue
    case .cassandra, .scylla: .wideColumn
    }
  }

  public var displayName: String {
    switch self {
    case .postgres: "PostgreSQL"
    case .mysql: "MySQL"
    case .mariadb: "MariaDB"
    case .sqlserver: "SQL Server"
    case .sqlite: "SQLite"
    case .duckdb: "DuckDB"
    case .mongodb: "MongoDB"
    case .redis: "Redis"
    case .cassandra: "Cassandra"
    case .scylla: "ScyllaDB"
    }
  }

  /// Two letters for the engine's tile.
  public var monogram: String {
    switch self {
    case .postgres: "Pg"
    case .mysql: "My"
    case .mariadb: "Ma"
    case .sqlserver: "SS"
    case .sqlite: "SL"
    case .duckdb: "Dk"
    case .mongodb: "Mg"
    case .redis: "Rd"
    case .cassandra: "Ca"
    case .scylla: "Sc"
    }
  }

  /// What kind of database it is, in plain words.
  public var kindLabel: String {
    switch self {
    case .postgres, .mysql, .mariadb, .sqlserver: "Relational"
    case .sqlite: "File"
    case .duckdb: "File · analytics"
    case .mongodb: "Documents"
    case .redis: "Keys & values"
    case .cassandra, .scylla: "Wide column"
    }
  }

  public var isFileBased: Bool { self == .sqlite || self == .duckdb }

  public var defaultPort: Int {
    switch self {
    case .postgres: 5432
    case .mysql, .mariadb: 3306
    case .sqlserver: 1433
    case .sqlite, .duckdb: 0
    case .mongodb: 27017
    case .redis: 6379
    case .cassandra, .scylla: 9042
    }
  }

  public var defaultUser: String {
    switch self {
    case .postgres: "postgres"
    case .mysql, .mariadb: "root"
    case .sqlserver: "sa"
    case .cassandra: "cassandra"
    default: ""
    }
  }

  /// The noun for one item in the main list.
  public var itemNoun: Noun {
    switch self {
    case .mongodb: Noun("document")
    case .redis: Noun("key")
    default: Noun("row")
    }
  }

  /// The noun for what holds items.
  public var collectionNoun: Noun {
    switch self {
    case .mongodb: Noun("collection")
    case .redis: Noun("key")
    default: Noun("table")
    }
  }

  /// What the levels of the sidebar tree are called, outermost first.
  public var path: [String] {
    switch self {
    case .postgres, .sqlserver: ["Server", "Database", "Schema", "Table"]
    case .mysql, .mariadb: ["Server", "Database", "Table"]
    case .sqlite: ["File", "Table"]
    case .duckdb: ["File", "Schema", "Table"]
    case .mongodb: ["Server", "Database", "Collection"]
    case .redis: ["Server", "Database 0–15", "Key group"]
    case .cassandra, .scylla: ["Cluster", "Keyspace", "Table"]
    }
  }

  /// The language the Query Editor speaks.
  public var queryLanguage: String {
    switch self {
    case .postgres, .mysql, .mariadb, .sqlite: "SQL"
    case .duckdb: "DuckDB SQL"
    case .sqlserver: "T-SQL"
    case .mongodb: "MongoDB Shell"
    case .redis: "Redis commands"
    case .cassandra, .scylla: "CQL"
    }
  }

  /// URL schemes that select this engine when a link is pasted.
  public var schemes: [String] {
    switch self {
    case .postgres: ["postgres", "postgresql"]
    case .mysql: ["mysql"]
    case .mariadb: ["mariadb"]
    case .sqlserver: ["sqlserver", "mssql", "jdbc:sqlserver"]
    case .sqlite: ["sqlite", "sqlite3"]
    case .duckdb: ["duckdb"]
    case .mongodb: ["mongodb", "mongodb+srv"]
    case .redis: ["redis", "rediss"]
    case .cassandra: ["cassandra", "cql"]
    case .scylla: ["scylla", "scylladb"]
    }
  }

  /// File extensions that open in this engine.
  public var fileExtensions: [String] {
    switch self {
    case .sqlite: ["sqlite", "sqlite3", "db", "db3"]
    case .duckdb: ["duckdb", "ddb", "parquet", "csv", "tsv", "json", "jsonl", "ndjson"]
    default: []
    }
  }

  /// Encrypted connections the drivers can make by themselves (TLS from the first byte).
  public var supportsDirectTLS: Bool {
    switch self {
    case .postgres, .mongodb, .redis, .cassandra, .scylla: true
    default: false
    }
  }
}

/// A countable noun with its plural.
public struct Noun: Sendable, Hashable {
  public let singular: String
  public let plural: String

  public init(_ singular: String, plural: String? = nil) {
    self.singular = singular
    self.plural = plural ?? singular + "s"
  }

  public func count(_ n: Int) -> String {
    "\(n.formatted()) \(n == 1 ? singular : plural)"
  }

  public var capitalized: String { singular.prefix(1).uppercased() + singular.dropFirst() }
  public var pluralCapitalized: String { plural.prefix(1).uppercased() + plural.dropFirst() }
}
