import Foundation

/// A BSON value.
public indirect enum BSON: Sendable, Hashable {
  case double(Double)
  case string(String)
  case document(BSONDocument)
  case array([BSON])
  case binary(subtype: UInt8, data: [UInt8])
  case undefined
  case objectId(ObjectID)
  case bool(Bool)
  /// Milliseconds since the Unix epoch.
  case datetime(Int64)
  case null
  case regex(pattern: String, options: String)
  case dbPointer(namespace: String, id: ObjectID)
  case javascript(String)
  case symbol(String)
  case javascriptWithScope(code: String, scope: BSONDocument)
  case int32(Int32)
  case timestamp(time: UInt32, increment: UInt32)
  case int64(Int64)
  case decimal128(Decimal128)
  case minKey
  case maxKey

  public static func date(_ date: Date) -> BSON { .datetime(Int64((date.timeIntervalSince1970 * 1000).rounded())) }

  /// The type name mongosh and Compass use.
  public var typeName: String {
    switch self {
    case .double: "Double"
    case .string: "String"
    case .document: "Object"
    case .array: "Array"
    case .binary(let subtype, _): subtype == 4 ? "UUID" : "Binary"
    case .undefined: "Undefined"
    case .objectId: "ObjectId"
    case .bool: "Boolean"
    case .datetime: "Date"
    case .null: "Null"
    case .regex: "RegExp"
    case .dbPointer: "DBPointer"
    case .javascript: "Code"
    case .symbol: "Symbol"
    case .javascriptWithScope: "Code"
    case .int32: "Int32"
    case .timestamp: "Timestamp"
    case .int64: "Int64"
    case .decimal128: "Decimal128"
    case .minKey: "MinKey"
    case .maxKey: "MaxKey"
    }
  }

  public var isContainer: Bool {
    switch self {
    case .document, .array: true
    default: false
    }
  }

  public var documentValue: BSONDocument? { if case .document(let d) = self { d } else { nil } }
  public var arrayValue: [BSON]? { if case .array(let a) = self { a } else { nil } }
  public var stringValue: String? { if case .string(let s) = self { s } else { nil } }
  public var boolValue: Bool? { if case .bool(let b) = self { b } else { nil } }

  public var intValue: Int? {
    switch self {
    case .int32(let i): Int(i)
    case .int64(let i): Int(i)
    case .double(let d): d.isFinite && d == d.rounded() ? Int(d) : nil
    default: nil
    }
  }

  public var doubleValue: Double? {
    switch self {
    case .int32(let i): Double(i)
    case .int64(let i): Double(i)
    case .double(let d): d
    case .decimal128(let d): Double(d.description)
    default: nil
    }
  }

  /// Field lookup through documents, then array indexes, by dotted path.
  public subscript(path path: String) -> BSON? {
    var current: BSON? = self
    for part in path.split(separator: ".", omittingEmptySubsequences: false) {
      switch current {
      case .document(let doc): current = doc[String(part)]
      case .array(let items):
        guard let index = Int(part), items.indices.contains(index) else { return nil }
        current = items[index]
      default: return nil
      }
    }
    return current
  }
}

/// A 12-byte ObjectId.
public struct ObjectID: Sendable, Hashable, CustomStringConvertible {
  public let bytes: [UInt8]

  public init(bytes: [UInt8]) {
    precondition(bytes.count == 12)
    self.bytes = bytes
  }

  public init?(_ hex: String) {
    guard hex.count == 24 else { return nil }
    var out: [UInt8] = []
    var index = hex.startIndex
    for _ in 0..<12 {
      let next = hex.index(index, offsetBy: 2)
      guard let byte = UInt8(hex[index..<next], radix: 16) else { return nil }
      out.append(byte)
      index = next
    }
    bytes = out
  }

  private static let process: [UInt8] = (0..<5).map { _ in UInt8.random(in: 0...255) }
  nonisolated(unsafe) private static var counter = UInt32.random(in: 0...0xFFFFFF)
  private static let lock = NSLock()

  /// A new id: 4-byte time, 5 random bytes per process, 3-byte counter.
  public static func generate(date: Date = Date()) -> ObjectID {
    lock.lock()
    counter = (counter &+ 1) & 0xFFFFFF
    let count = counter
    lock.unlock()
    let seconds = UInt32(date.timeIntervalSince1970)
    var b: [UInt8] = [
      UInt8(seconds >> 24), UInt8(seconds >> 16 & 0xFF), UInt8(seconds >> 8 & 0xFF), UInt8(seconds & 0xFF),
    ]
    b += process
    b += [UInt8(count >> 16 & 0xFF), UInt8(count >> 8 & 0xFF), UInt8(count & 0xFF)]
    return ObjectID(bytes: b)
  }

  public var hex: String { bytes.map { String(format: "%02x", $0) }.joined() }
  public var description: String { hex }

  public var date: Date {
    let seconds = UInt32(bytes[0]) << 24 | UInt32(bytes[1]) << 16 | UInt32(bytes[2]) << 8 | UInt32(bytes[3])
    return Date(timeIntervalSince1970: TimeInterval(seconds))
  }
}

/// An ordered BSON document.
public struct BSONDocument: Sendable, Hashable, Sequence, ExpressibleByDictionaryLiteral {
  public private(set) var elements: [(key: String, value: BSON)]

  public init() { elements = [] }
  public init(_ elements: [(String, BSON)]) { self.elements = elements.map { (key: $0.0, value: $0.1) } }
  public init(dictionaryLiteral pairs: (String, BSON)...) { self.init(pairs) }

  public var count: Int { elements.count }
  public var isEmpty: Bool { elements.isEmpty }
  public var keys: [String] { elements.map(\.key) }
  public var values: [BSON] { elements.map(\.value) }

  public func makeIterator() -> IndexingIterator<[(key: String, value: BSON)]> { elements.makeIterator() }

  public subscript(key: String) -> BSON? {
    get { elements.first { $0.key == key }?.value }
    set {
      if let index = elements.firstIndex(where: { $0.key == key }) {
        if let newValue { elements[index].value = newValue } else { elements.remove(at: index) }
      } else if let newValue {
        elements.append((key: key, value: newValue))
      }
    }
  }

  public mutating func append(_ key: String, _ value: BSON) { elements.append((key: key, value: value)) }

  public mutating func removeValue(forKey key: String) { self[key] = nil }

  /// Sets a value at a dotted path, creating documents along the way.
  public mutating func set(path: String, to value: BSON?) {
    let parts = path.split(separator: ".", maxSplits: 1).map(String.init)
    guard parts.count == 2 else {
      self[path] = value
      return
    }
    switch self[parts[0]] {
    case .document(var inner):
      inner.set(path: parts[1], to: value)
      self[parts[0]] = .document(inner)
    case .array(var items):
      let rest = parts[1].split(separator: ".", maxSplits: 1).map(String.init)
      if let index = Int(rest[0]), items.indices.contains(index) {
        if rest.count == 1 {
          if let value { items[index] = value }
        } else if case .document(var inner) = items[index] {
          inner.set(path: rest[1], to: value)
          items[index] = .document(inner)
        }
        self[parts[0]] = .array(items)
      }
    default:
      guard value != nil else { return }
      var inner = BSONDocument()
      inner.set(path: parts[1], to: value)
      self[parts[0]] = .document(inner)
    }
  }

  public static func == (a: BSONDocument, b: BSONDocument) -> Bool {
    a.elements.count == b.elements.count
      && zip(a.elements, b.elements).allSatisfy { $0.key == $1.key && $0.value == $1.value }
  }

  public func hash(into hasher: inout Hasher) {
    for element in elements {
      hasher.combine(element.key)
      hasher.combine(element.value)
    }
  }
}
