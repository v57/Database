import BSON
import Foundation
import SSHTunnel

/// Sessions that may run over an SSH tunnel.
public protocol TunnelOwning {
  var tunnel: SSHTunnel? { get }
}

/// What the Redis key browser needs beyond the common session.
public protocol RedisBrowsing: DatabaseSession {
  func value(of key: String, in ref: ObjectRef, limit: Int) async throws -> (RedisValue, Int)
  func ttl(of key: String, in ref: ObjectRef) async throws -> Int64
  func mutate(_ mutation: RedisMutation, in ref: ObjectRef) async throws -> RedisUndo
  func undo(_ undo: RedisUndo, in ref: ObjectRef) async throws
  func create(key: String, type: String, first: [String], in ref: ObjectRef) async throws
}

/// MongoDB's aggregation pipeline.
public protocol DocumentAggregating: DatabaseSession {
  /// Runs the stages and returns a preview (up to `limit`) and the full count.
  func aggregate(_ ref: ObjectRef, stages: [BSONDocument], limit: Int) async throws -> (
    documents: [BSONDocument], count: Int?, elapsed: TimeInterval
  )
  func aggregateFull(_ ref: ObjectRef, stages: [BSONDocument], options: BSONDocument, limit: Int) async throws
    -> [BSONDocument]
  func explainAggregate(_ ref: ObjectRef, stages: [BSONDocument]) async throws -> BSONDocument
}

/// Cassandra and ScyllaDB: filters on non-key columns scan the whole table.
public protocol WideColumnFiltering: DatabaseSession {
  func requiresFullScan(_ request: BrowseRequest) async throws -> Bool
}

extension SQLSession: TunnelOwning {}
extension MongoSession: TunnelOwning, DocumentAggregating {}
extension RedisSession: TunnelOwning, RedisBrowsing {}
extension CQLSession: TunnelOwning, WideColumnFiltering {}

extension EngineKind {
  /// The filter conditions a field offers on this engine.
  public func filterOps(for field: FieldInfo) -> [FilterOp] {
    switch family {
    case .wideColumn: CQLSession.availableOps(for: field)
    case .keyValue: [.startsWith]
    default: FilterOp.available(for: field.category)
    }
  }

  /// Whether the search box can search this engine.
  public var supportsSearch: Bool { family != .wideColumn }
}

extension MongoSession {
  /// Types offered by the document field editor.
  public static var fieldTypes: [String] { editableTypes }
}

/// The BSON type names the document editor offers.
public let documentFieldTypes = MongoSession.editableTypes

/// BSON type name → value category.
public func valueCategory(forBSONType type: String) -> ValueCategory { MongoSession.category(forBSONType: type) }
