import BSON
import Foundation
import WireKit

/// One result of running something in the Query Editor.
public enum QueryOutput: Sendable {
  case table(fields: [FieldInfo], rows: [[CellValue]], note: String?)
  case documents([BSONDocument], note: String?)
  case text(String)
  case message(String)
}

/// One statement's outcome with timing, for the Results / Messages tabs.
public struct QueryRun: Sendable {
  public var outputs: [QueryOutput]
  public var elapsed: TimeInterval
  public var statement: String
}

/// Where a query runs: the database, schema or collection picked in the sidebar.
public struct QueryContext: Hashable, Sendable {
  public var database: String?
  public var schema: String?
  public var collection: String?
  public init(database: String? = nil, schema: String? = nil, collection: String? = nil) {
    self.database = database
    self.schema = schema
    self.collection = collection
  }
}

/// A suggestion in the Query Editor.
public struct Completion: Hashable, Sendable, Identifiable {
  public enum Kind: String, Sendable { case keyword, table, column, function, field, command }
  public var id: String { "\(kind.rawValue):\(text)" }
  public var text: String
  public var detail: String
  public var kind: Kind
  public init(text: String, detail: String = "", kind: Kind) {
    self.text = text
    self.detail = detail
    self.kind = kind
  }
}

/// A live connection to one server or file, whatever the engine.
public protocol DatabaseSession: AnyObject, Sendable {
  var profile: ConnectionProfile { get }
  /// "PostgreSQL 18.0", "MongoDB 8.0.4"…
  var serverDescription: String { get async }

  func close() async

  /// Children of a tree node; `nil` asks for the top level.
  func children(of node: TreeNode?) async throws -> [TreeNode]

  func fields(of ref: ObjectRef) async throws -> [FieldInfo]
  func browse(_ request: BrowseRequest) async throws -> BrowsePage
  /// Exact count for the request's filters (may be slow on big tables).
  func count(_ request: BrowseRequest) async throws -> Int

  func relations(of ref: ObjectRef) async throws -> [Relation]

  /// Turns typed text into a value for the field, or explains what's wrong.
  func parseInput(_ text: String, isNull: Bool, for field: FieldInfo) throws -> CellValue
  /// What would run, for the review sheet.
  func statements(for edits: [RecordEdit]) throws -> [String]
  /// Writes the edits together where the engine allows it.
  func apply(_ edits: [RecordEdit]) async throws -> ApplyOutcome

  func run(_ text: String, context: QueryContext) async throws -> [QueryRun]
  func explain(_ text: String, context: QueryContext) async throws -> String
  func completions(context: QueryContext) async -> [Completion]
}

extension DatabaseSession {
  public func relations(of ref: ObjectRef) async throws -> [Relation] { [] }
}

/// Times an async operation.
func timed<T>(_ body: () async throws -> T) async rethrows -> (T, TimeInterval) {
  let start = Date()
  let value = try await body()
  return (value, Date().timeIntervalSince(start))
}
