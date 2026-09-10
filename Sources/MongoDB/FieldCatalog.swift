import Foundation

/// What the filter UI knows about one field of the loaded documents.
/// `FieldKind` itself lives in Sources/MongoDB/FilterRules.swift.
public struct FieldInfo: Equatable, Sendable {
  public let name: String
  public let kind: FieldKind
  /// Distinct scalar values seen so far, most frequent first, capped.
  public let values: [BSON]
}

/// Derives the filterable field list from the documents currently loaded in the
/// list. Suggestions are page-local: a field that only exists on an unloaded
/// page won't be offered until it is paged in.
public enum FieldCatalog {
  /// Fields in first-seen order, with kind and up to `valueLimit` distinct
  /// scalar values (most frequent first, ties in first-seen order).
  public static func fields(in documents: [Document], valueLimit: Int = 50) -> [FieldInfo] {
    var order: [String] = []
    var kinds: [String: FieldKind] = [:]
    // field -> display text -> (value, occurrences, firstSeen)
    var buckets: [String: [String: (value: BSON, count: Int, first: Int)]] = [:]
    var seen = 0

    for doc in documents {
      for (key, value) in doc.all {
        if kinds[key] == nil { order.append(key) }
        kinds[key] = merge(kinds[key], kind(of: value))
        guard value.isScalar else { continue }
        seen += 1
        let text = BSONSupport.displayString(value)
        if let existing = buckets[key]?[text] {
          buckets[key]?[text] = (existing.value, existing.count + 1, existing.first)
        } else {
          buckets[key, default: [:]][text] = (value, 1, seen)
        }
      }
    }

    return order.map { key in
      let bucket = buckets[key] ?? [:]
      let ordered = bucket.values.sorted { a, b in
        a.count == b.count ? a.first < b.first : a.count > b.count
      }
      return FieldInfo(
        name: key, kind: kinds[key] ?? .empty,
        values: Array(ordered.prefix(valueLimit)).map(\.value))
    }
  }

  /// Names of the text-typed fields, for the "search all text fields" box.
  /// Capped because each name becomes one `$or` branch.
  public static func textFields(in documents: [Document], limit: Int = 6) -> [String] {
    Array(
      fields(in: documents, valueLimit: 0).filter { $0.kind == .string }.map(\.name).prefix(limit))
  }

  /// Kinds are merged across documents; `.empty` (only nulls so far) yields to
  /// any concrete kind, and incompatible kinds become `.mixed`.
  static func merge(_ existing: FieldKind?, _ new: FieldKind) -> FieldKind {
    guard let existing, existing != new else { return existing ?? new }
    if existing == .empty { return new }
    if new == .empty { return existing }
    return .mixed
  }

  static func kind(of value: BSON) -> FieldKind {
    switch value {
    case .string: return .string
    case .int32, .int64, .double, .decimal128: return .number
    case .bool: return .boolean
    case .datetime: return .date
    case .objectID: return .objectID
    case .document, .array: return .container
    case .null, .undefined: return .empty
    default: return .scalar
    }
  }
}

extension BSON {
  /// True for single values (everything the suggestions list can hold).
  public var isScalar: Bool {
    switch self {
    case .document, .array: return false
    default: return true
    }
  }
}
