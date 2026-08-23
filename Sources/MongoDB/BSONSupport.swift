import Foundation
import MongoSwift

/// swift-bson 3.x (pulled in by mongo-swift-driver 1.3.1) renamed `Document` to
/// `BSONDocument`. This typealias keeps the module's `Document` API stable for
/// tests, the UI layer, and the helpers below — visible wherever MongoDB is imported.
public typealias Document = BSONDocument

/// JSON <-> BSON Document helpers for the UI layer and tests.
public enum BSONSupport {
  /// Parse a JSON string into a BSON `Document` (filter / update inputs from text fields).
  public static func document(fromJSON json: String) throws -> Document {
    do { return try Document(fromJSON: json) } catch {
      throw MongoDBError.invalidConfig("Invalid JSON: \(error.localizedDescription)")
    }
  }

  /// Single-line extended JSON of a document, for display.
  public static func json(_ doc: Document) -> String { doc.description }

  /// Human-readable single-line display of a BSON value (string as-is,
  /// numbers/booleans/nulls/dates/ObjectIds in their natural form).
  /// Containers (documents/arrays) render as empty — the UI expands those
  /// into nested rows instead.
  public static func displayString(_ bson: BSON) -> String {
    switch bson {
    case .string(let s): return s
    case .int32(let i): return String(i)
    case .int64(let i): return String(i)
    case .double(let d): return String(d)
    case .decimal128(let d): return d.description
    case .bool(let b): return b ? "true" : "false"
    case .datetime(let date): return dateFormatter.string(from: date)
    case .objectID(let oid): return oid.hex
    case .symbol(let s): return s.stringValue
    case .null: return "null"
    case .undefined: return "undefined"
    case .minKey: return "MinKey"
    case .maxKey: return "MaxKey"
    case .document, .array: return ""
    default: return String(describing: bson)
    }
  }

  /// ISO-8601 formatter for datetime display. Only touched from the
  /// MainActor UI and single-threaded tests, hence `nonisolated(unsafe)`.
  private nonisolated(unsafe) static let dateFormatter: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return f
  }()
}
