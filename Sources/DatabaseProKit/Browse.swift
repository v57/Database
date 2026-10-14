import BSON
import Foundation

/// A condition in the simple filter bar, in plain words.
public enum FilterOp: String, CaseIterable, Codable, Sendable, Identifiable {
  case equals, notEquals, contains, notContains, startsWith, endsWith
  case greater, greaterOrEqual, less, lessOrEqual
  case isEmpty, isNotEmpty, inLastDays

  public var id: String { rawValue }

  public func label(for category: ValueCategory) -> String {
    let temporal = category.isTemporal
    switch self {
    case .equals: return "is"
    case .notEquals: return "is not"
    case .contains: return "contains"
    case .notContains: return "doesn't contain"
    case .startsWith: return "starts with"
    case .endsWith: return "ends with"
    case .greater: return temporal ? "is after" : "is greater than"
    case .greaterOrEqual: return temporal ? "is on or after" : "is at least"
    case .less: return temporal ? "is before" : "is less than"
    case .lessOrEqual: return temporal ? "is on or before" : "is at most"
    case .isEmpty: return "is empty"
    case .isNotEmpty: return "isn't empty"
    case .inLastDays: return "is in the last"
    }
  }

  public var needsValue: Bool { self != .isEmpty && self != .isNotEmpty }

  /// Which conditions make sense for a kind of value.
  public static func available(for category: ValueCategory) -> [FilterOp] {
    switch category {
    case .text, .other, .json, .uuid:
      [.equals, .notEquals, .contains, .notContains, .startsWith, .endsWith, .isEmpty, .isNotEmpty]
    case .integer, .decimal, .float:
      [.equals, .notEquals, .greater, .greaterOrEqual, .less, .lessOrEqual, .isEmpty, .isNotEmpty]
    case .date, .dateTime:
      [.equals, .notEquals, .greater, .greaterOrEqual, .less, .lessOrEqual, .inLastDays, .isEmpty, .isNotEmpty]
    case .time:
      [.equals, .notEquals, .greater, .less, .isEmpty, .isNotEmpty]
    case .boolean:
      [.equals, .notEquals, .isEmpty, .isNotEmpty]
    case .binary, .list, .document:
      [.isEmpty, .isNotEmpty]
    }
  }
}

public struct Filter: Identifiable, Hashable, Codable, Sendable {
  public var id = UUID()
  public var field: String
  public var op: FilterOp
  public var value: String
  public var isEnabled = true

  public init(field: String, op: FilterOp, value: String = "", isEnabled: Bool = true) {
    self.field = field
    self.op = op
    self.value = value
    self.isEnabled = isEnabled
  }

  /// "status is shipped", "created_at is in the last 7 days".
  public func summary(category: ValueCategory = .text) -> String {
    let op = self.op.label(for: category)
    switch self.op {
    case .isEmpty, .isNotEmpty: return "\(field) \(op)"
    case .inLastDays: return "\(field) \(op) \(value) day\(value == "1" ? "" : "s")"
    default: return "\(field) \(op) \(value)"
    }
  }
}

public struct SortKey: Hashable, Codable, Sendable {
  public var field: String
  public var ascending: Bool
  public init(field: String, ascending: Bool = true) {
    self.field = field
    self.ascending = ascending
  }
}

/// What the item list asks the engine for.
public struct BrowseRequest: Hashable, Sendable {
  public var ref: ObjectRef
  public var search: String = ""
  public var filters: [Filter] = []
  public var sort: [SortKey] = []
  /// Fields left out of the result (documents: a projection; tables: columns not selected).
  public var hiddenFields: Set<String> = []
  public var offset: Int = 0
  public var limit: Int = 50
  /// Redis: only keys of this type.
  public var keyType: String?

  public init(ref: ObjectRef, limit: Int = 50) {
    self.ref = ref
    self.limit = limit
  }

  public var activeFilters: [Filter] { filters.filter { $0.isEnabled && (!$0.op.needsValue || !$0.value.isEmpty) } }
}

/// Identifies one item so it can be changed or deleted.
public struct RecordKey: Hashable, Sendable {
  public struct Part: Hashable, Sendable {
    public var field: String
    public var value: CellValue
    public init(field: String, value: CellValue) {
      self.field = field
      self.value = value
    }
  }

  public var parts: [Part]
  public init(_ parts: [Part]) { self.parts = parts }

  public var summary: String { parts.map { $0.value.displayText }.joined(separator: ", ") }
}

/// One row, document or key in the list.
public struct Record: Hashable, Sendable, Identifiable {
  public var id: String
  /// Nil when the item can't be addressed (no primary key): such rows are read-only.
  public var key: RecordKey?
  public var values: [String: CellValue]
  /// The original document, for document engines.
  public var document: BSONDocument?

  public init(id: String, key: RecordKey?, values: [String: CellValue], document: BSONDocument? = nil) {
    self.id = id
    self.key = key
    self.values = values
    self.document = document
  }

  public subscript(field: String) -> CellValue? { values[field] }
}

/// One page of items, plus what produced it.
public struct BrowsePage: Sendable {
  public var fields: [FieldInfo]
  public var records: [Record]
  /// Exact or estimated total for the current filters, when cheap enough to know.
  public var total: Int?
  public var totalIsEstimate: Bool
  public var hasMore: Bool
  /// The statement that was run, for the Query Editor.
  public var query: String
  public var elapsed: TimeInterval
  public var notes: [String]

  public init(
    fields: [FieldInfo], records: [Record], total: Int? = nil, totalIsEstimate: Bool = false, hasMore: Bool = false,
    query: String = "", elapsed: TimeInterval = 0, notes: [String] = []
  ) {
    self.fields = fields
    self.records = records
    self.total = total
    self.totalIsEstimate = totalIsEstimate
    self.hasMore = hasMore
    self.query = query
    self.elapsed = elapsed
    self.notes = notes
  }
}
