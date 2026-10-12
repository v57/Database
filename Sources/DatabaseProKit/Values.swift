import BSON
import Foundation
import WireKit

/// One value as the browser shows and edits it: a table cell or a BSON value.
public enum CellValue: Hashable, Sendable {
  case db(DBValue)
  case bson(BSON)
  /// "Remove this field" in a document edit.
  case unset

  public static let null = CellValue.db(.null)

  public var isNull: Bool {
    switch self {
    case .db(let v): v.isNull
    case .bson(let b): b == .null || b == .undefined
    case .unset: true
    }
  }

  /// Single-line text for a grid cell.
  public var displayText: String {
    switch self {
    case .db(let v):
      let text = v.displayText
      return text.count > 300 ? String(text.prefix(300)) + "…" : text.replacingOccurrences(of: "\n", with: " ")
    case .bson(let b): return Self.shortText(b)
    case .unset: return "(removed)"
    }
  }

  /// Full text for the inspector or an editor.
  public var fullText: String {
    switch self {
    case .db(let v):
      if case .json(let json) = v, let data = json.data(using: .utf8),
        let object = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]),
        let pretty = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .fragmentsAllowed])
      {
        return String(decoding: pretty, as: UTF8.self)
      }
      return v.displayText
    case .bson(let b):
      if case .string(let s) = b { return s }
      return b.text(.shell, indent: 2)
    case .unset: return ""
    }
  }

  /// The text that goes into an editor field (strings without quotes).
  public var editingText: String {
    switch self {
    case .db(let v):
      switch v {
      case .null: ""
      case .bytes(let b): "0x" + b.hexString.uppercased()
      default: fullText
      }
    case .bson(let b):
      switch b {
      case .string(let s): s
      case .null: ""
      default: b.text(.shell, indent: 2)
      }
    case .unset: ""
    }
  }

  /// The type label shown next to a field (BSON types; SQL cells use their column type).
  public var typeBadge: String? {
    if case .bson(let b) = self { return b.typeName }
    return nil
  }

  public var bsonValue: BSON? { if case .bson(let b) = self { b } else { nil } }
  public var dbValue: DBValue? { if case .db(let v) = self { v } else { nil } }

  static func shortText(_ b: BSON) -> String {
    switch b {
    case .string(let s): return s.count > 300 ? String(s.prefix(300)) + "…" : s.replacingOccurrences(of: "\n", with: " ")
    case .document(let d): return d.isEmpty ? "{}" : "{ \(d.count) field\(d.count == 1 ? "" : "s") }"
    case .array(let a): return a.isEmpty ? "[]" : "[\(a.count) item\(a.count == 1 ? "" : "s")]"
    case .objectId(let id): return id.hex
    case .datetime(let ms): return CellValue.dateFormatter.string(from: Date(timeIntervalSince1970: Double(ms) / 1000))
    case .double(let d): return d == d.rounded() && abs(d) < 1e15 ? String(format: "%.1f", d) : String(d)
    case .int32(let i): return String(i)
    case .int64(let i): return String(i)
    case .decimal128(let d): return d.description
    case .bool(let v): return v ? "true" : "false"
    case .null: return "null"
    default: return b.text(.shell)
    }
  }

  nonisolated(unsafe) static let dateFormatter: DateFormatter = {
    let f = DateFormatter()
    f.dateStyle = .medium
    f.timeStyle = .short
    return f
  }()
}

/// What kind of value a column holds, for choosing an editor and writing literals.
public enum ValueCategory: String, Sendable, Codable, CaseIterable {
  case text, integer, decimal, float, boolean, date, time, dateTime, json, binary, uuid, list, document, other

  public static func infer(typeName raw: String) -> ValueCategory {
    let t = raw.lowercased()
    if t.hasSuffix("[]") || t.hasPrefix("list<") || t.hasPrefix("set<") || t.hasPrefix("_") || t == "array" { return .list }
    if t.hasPrefix("map<") || t.hasPrefix("struct") || t == "map" { return .document }
    if t.contains("bool") || t == "bit" { return .boolean }
    if t.contains("uuid") || t == "uniqueidentifier" || t == "timeuuid" { return .uuid }
    if t.contains("json") { return .json }
    if t.contains("timestamp") || t.contains("datetime") || t == "smalldatetime" { return .dateTime }
    if t == "date" { return .date }
    if t.hasPrefix("time") { return .time }
    if t.contains("interval") || t == "duration" { return .text }
    if t.contains("blob") || t.contains("bytea") || t.contains("binary") || t == "image" { return .binary }
    if t.contains("int") || t == "serial" || t == "bigserial" || t == "smallserial" || t == "oid" || t == "counter"
      || t == "varint" || t == "year"
    {
      return .integer
    }
    if t.hasPrefix("decimal") || t.hasPrefix("numeric") || t.contains("money") { return .decimal }
    if t.contains("float") || t.contains("double") || t == "real" { return .float }
    if t.contains("char") || t.contains("text") || t.contains("string") || t == "name" || t == "ascii" || t == "xml"
      || t == "citext" || t.hasPrefix("enum") || t == "inet" || t == "cidr"
    {
      return .text
    }
    return .other
  }

  public var isNumeric: Bool { self == .integer || self == .decimal || self == .float }
  public var isTemporal: Bool { self == .date || self == .time || self == .dateTime }
}

/// A column or document field, as far as the browser knows it.
public struct FieldInfo: Hashable, Sendable, Identifiable {
  public var id: String { name }
  public var name: String
  public var typeName: String
  public var category: ValueCategory
  public var isPrimaryKey: Bool
  public var isNullable: Bool
  /// Filled in by the server (identity, serial, computed, rowid…).
  public var isGenerated: Bool
  public var defaultValue: String?
  /// CQL: partition or clustering key.
  public var keyRole: KeyRole?
  /// Where a foreign key points.
  public var references: ForeignKey?
  /// Documents: share of sampled documents that have it.
  public var presence: Double?

  public enum KeyRole: String, Sendable, Hashable { case partition, clustering }

  public init(
    name: String, typeName: String, category: ValueCategory? = nil, isPrimaryKey: Bool = false, isNullable: Bool = true,
    isGenerated: Bool = false, defaultValue: String? = nil, keyRole: KeyRole? = nil, references: ForeignKey? = nil,
    presence: Double? = nil
  ) {
    self.name = name
    self.typeName = typeName
    self.category = category ?? ValueCategory.infer(typeName: typeName)
    self.isPrimaryKey = isPrimaryKey
    self.isNullable = isNullable
    self.isGenerated = isGenerated
    self.defaultValue = defaultValue
    self.keyRole = keyRole
    self.references = references
    self.presence = presence
  }
}

public struct ForeignKey: Hashable, Sendable {
  public var target: ObjectRef
  public var column: String
  public init(target: ObjectRef, column: String) {
    self.target = target
    self.column = column
  }
}
