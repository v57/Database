import Foundation

/// Points at something that holds items: a table, view, collection, or a Redis database.
public struct ObjectRef: Hashable, Sendable, Codable, Identifiable {
  public enum Kind: String, Sendable, Codable {
    case table, view, materializedView, collection, redisDatabase, file
  }

  /// Database, keyspace, Redis index or DuckDB catalog.
  public var database: String?
  public var schema: String?
  public var name: String
  public var kind: Kind

  public init(database: String? = nil, schema: String? = nil, name: String, kind: Kind = .table) {
    self.database = database
    self.schema = schema
    self.name = name
    self.kind = kind
  }

  public var id: String { [database, schema, name].compactMap { $0 }.joined(separator: ".") + "#\(kind.rawValue)" }

  /// "shop › public" style location.
  public var location: String { [database, schema].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " › ") }

  public var isWritable: Bool { kind == .table || kind == .collection || kind == .redisDatabase }
}

/// A row in the sidebar tree.
public struct TreeNode: Hashable, Sendable, Identifiable {
  public enum Kind: String, Sendable, Hashable {
    case database, schema, folder, table, view, collection, keyspace, redisDatabase, file, materializedView
  }

  public var id: String
  public var title: String
  /// A count or size, shown dimmed on the right.
  public var detail: String?
  public var kind: Kind
  public var database: String?
  public var schema: String?
  /// Set on nodes that open in the main pane.
  public var ref: ObjectRef?
  public var hasChildren: Bool

  public init(
    id: String, title: String, detail: String? = nil, kind: Kind, database: String? = nil, schema: String? = nil,
    ref: ObjectRef? = nil, hasChildren: Bool = false
  ) {
    self.id = id
    self.title = title
    self.detail = detail
    self.kind = kind
    self.database = database
    self.schema = schema
    self.ref = ref
    self.hasChildren = hasChildren
  }

  /// SF Symbol for the node.
  public var symbol: String {
    switch kind {
    case .database, .keyspace, .redisDatabase: "cylinder"
    case .schema, .folder: "folder"
    case .table: "tablecells"
    case .view, .materializedView: "eye"
    case .collection: "doc.on.doc"
    case .file: "doc"
    }
  }
}

/// Relationships pointing into or out of a table, for the inspector's "Related" section.
public struct Relation: Hashable, Sendable, Identifiable {
  public var id: String { "\(direction)-\(table.id)-\(column)-\(otherColumn)" }
  public enum Direction: String, Sendable { case outgoing, incoming }
  public var direction: Direction
  public var table: ObjectRef
  /// The column in this table.
  public var column: String
  /// The column in the other table.
  public var otherColumn: String
}
