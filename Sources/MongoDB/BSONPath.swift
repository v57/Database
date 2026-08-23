import Foundation
import MongoSwift

/// One step on the path to a value inside a BSON document: a document key or
/// an array index. Used by the UI to address fields for display and editing,
/// e.g. `[.key("address"), .key("zip")]` or `[.key("tags"), .index(1)]`.
public enum BSONPathSegment: Hashable, Sendable, CustomStringConvertible {
  case key(String)
  case index(Int)

  public var description: String {
    switch self {
    case .key(let key): return key
    case .index(let i): return "[\(i)]"
    }
  }
}

/// Read/write helpers for values addressed by a `[BSONPathSegment]` path.
public enum BSONPath {
  /// Returns the value at `path` inside `document`, or `nil` when the path
  /// does not resolve (missing key, out-of-range index, type mismatch).
  public static func value(at path: [BSONPathSegment], in document: Document) -> BSON? {
    guard let first = path.first else { return nil }
    switch first {
    case .key(let key):
      guard let current = document[key] else { return nil }
      return path.count == 1 ? current : descend(current, remaining: Array(path.dropFirst()))
    case .index: return nil  // top-level paths always start with a key
    }
  }

  /// Returns a copy of `document` with the value at `path` replaced by
  /// `value`. Setting `nil` deletes the key (documents) or stores BSON null
  /// (array elements). No-op when the path does not resolve.
  public static func setting(_ value: BSON?, at path: [BSONPathSegment], in document: Document)
    -> Document
  {
    guard let first = path.first else { return document }
    var copy = document
    switch first {
    case .key(let key):
      if path.count == 1 {
        copy[key] = value
      } else if let current = copy[key] {
        copy[key] = replace(current, with: value, at: Array(path.dropFirst()))
      }
    case .index: break
    }
    return copy
  }

  // MARK: - Recursive traversal

  private static func descend(_ current: BSON, remaining: [BSONPathSegment]) -> BSON? {
    guard let first = remaining.first else { return current }
    switch first {
    case .key(let key):
      guard case .document(let doc) = current, let next = doc[key] else { return nil }
      return descend(next, remaining: Array(remaining.dropFirst()))
    case .index(let i):
      guard case .array(let items) = current, items.indices.contains(i) else { return nil }
      return descend(items[i], remaining: Array(remaining.dropFirst()))
    }
  }

  private static func replace(_ current: BSON, with value: BSON?, at remaining: [BSONPathSegment])
    -> BSON?
  {
    guard let first = remaining.first else { return value }
    switch first {
    case .key(let key):
      guard case .document(var doc) = current else { return current }
      if remaining.count == 1 {
        doc[key] = value
      } else if let next = doc[key] {
        doc[key] = replace(next, with: value, at: Array(remaining.dropFirst()))
      }
      return .document(doc)
    case .index(let i):
      guard case .array(var items) = current, items.indices.contains(i) else { return current }
      if remaining.count == 1 {
        items[i] = value ?? .null
      } else {
        items[i] = replace(items[i], with: value, at: Array(remaining.dropFirst())) ?? .null
      }
      return .array(items)
    }
  }
}
