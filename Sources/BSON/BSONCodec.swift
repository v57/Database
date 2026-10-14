import Foundation

public enum BSONError: Error, LocalizedError, Sendable, Equatable {
  case truncated
  case invalid(String)
  case parse(String, offset: Int)

  public var errorDescription: String? {
    switch self {
    case .truncated: "The BSON data ended too early."
    case .invalid(let detail): "Invalid BSON: \(detail)"
    case .parse(let detail, let offset): "\(detail) (at character \(offset + 1))"
    }
  }
}

extension BSONDocument {
  /// Binary encoding.
  public func encoded() -> [UInt8] {
    var out: [UInt8] = [0, 0, 0, 0]
    for element in elements { BSONCodec.write(element.key, element.value, into: &out) }
    out.append(0)
    BSONCodec.patchLength(&out, at: 0)
    return out
  }

  public init(bytes: [UInt8]) throws {
    var offset = 0
    self = try BSONCodec.readDocument(bytes, &offset)
  }
}

enum BSONCodec {
  static func patchLength(_ out: inout [UInt8], at start: Int) {
    let length = Int32(out.count - start).littleEndian
    withUnsafeBytes(of: length) { raw in
      for i in 0..<4 { out[start + i] = raw[i] }
    }
  }

  static func le<T: FixedWidthInteger>(_ value: T, into out: inout [UInt8]) {
    withUnsafeBytes(of: value.littleEndian) { out.append(contentsOf: $0) }
  }

  static func cstring(_ s: String, into out: inout [UInt8]) {
    out.append(contentsOf: s.utf8.filter { $0 != 0 })
    out.append(0)
  }

  static func string(_ s: String, into out: inout [UInt8]) {
    let bytes = Array(s.utf8)
    le(Int32(bytes.count + 1), into: &out)
    out.append(contentsOf: bytes)
    out.append(0)
  }

  static func typeByte(_ value: BSON) -> UInt8 {
    switch value {
    case .double: 0x01
    case .string: 0x02
    case .document: 0x03
    case .array: 0x04
    case .binary: 0x05
    case .undefined: 0x06
    case .objectId: 0x07
    case .bool: 0x08
    case .datetime: 0x09
    case .null: 0x0A
    case .regex: 0x0B
    case .dbPointer: 0x0C
    case .javascript: 0x0D
    case .symbol: 0x0E
    case .javascriptWithScope: 0x0F
    case .int32: 0x10
    case .timestamp: 0x11
    case .int64: 0x12
    case .decimal128: 0x13
    case .minKey: 0xFF
    case .maxKey: 0x7F
    }
  }

  static func write(_ key: String, _ value: BSON, into out: inout [UInt8]) {
    out.append(typeByte(value))
    cstring(key, into: &out)
    switch value {
    case .double(let d): le(d.bitPattern, into: &out)
    case .string(let s), .javascript(let s), .symbol(let s): string(s, into: &out)
    case .document(let doc): out.append(contentsOf: doc.encoded())
    case .array(let items):
      let start = out.count
      out.append(contentsOf: [0, 0, 0, 0])
      for (i, item) in items.enumerated() { write(String(i), item, into: &out) }
      out.append(0)
      patchLength(&out, at: start)
    case .binary(let subtype, let data):
      if subtype == 0x02 {
        le(Int32(data.count + 4), into: &out)
        out.append(subtype)
        le(Int32(data.count), into: &out)
      } else {
        le(Int32(data.count), into: &out)
        out.append(subtype)
      }
      out.append(contentsOf: data)
    case .undefined, .null, .minKey, .maxKey: break
    case .objectId(let id): out.append(contentsOf: id.bytes)
    case .bool(let b): out.append(b ? 1 : 0)
    case .datetime(let ms): le(ms, into: &out)
    case .regex(let pattern, let options):
      cstring(pattern, into: &out)
      cstring(String(options.sorted()), into: &out)
    case .dbPointer(let ns, let id):
      string(ns, into: &out)
      out.append(contentsOf: id.bytes)
    case .javascriptWithScope(let code, let scope):
      let start = out.count
      out.append(contentsOf: [0, 0, 0, 0])
      string(code, into: &out)
      out.append(contentsOf: scope.encoded())
      patchLength(&out, at: start)
    case .int32(let i): le(i, into: &out)
    case .timestamp(let t, let i):
      le(i, into: &out)
      le(t, into: &out)
    case .int64(let i): le(i, into: &out)
    case .decimal128(let d):
      le(d.low, into: &out)
      le(d.high, into: &out)
    }
  }

  // MARK: Decoding

  static func readLE<T: FixedWidthInteger>(_ b: [UInt8], _ o: inout Int) throws -> T {
    let size = MemoryLayout<T>.size
    guard o + size <= b.count else { throw BSONError.truncated }
    var value: T = 0
    for i in (0..<size).reversed() { value = value << 8 | T(truncatingIfNeeded: b[o + i]) }
    o += size
    return value
  }

  static func readCString(_ b: [UInt8], _ o: inout Int) throws -> String {
    guard let end = b[o...].firstIndex(of: 0) else { throw BSONError.truncated }
    defer { o = end + 1 }
    return String(decoding: b[o..<end], as: UTF8.self)
  }

  static func readString(_ b: [UInt8], _ o: inout Int) throws -> String {
    let length = Int(try readLE(b, &o) as Int32)
    guard length >= 1, o + length <= b.count else { throw BSONError.truncated }
    defer { o += length }
    return String(decoding: b[o..<o + length - 1], as: UTF8.self)
  }

  static func readDocument(_ b: [UInt8], _ o: inout Int) throws -> BSONDocument {
    let start = o
    let length = Int(try readLE(b, &o) as Int32)
    guard length >= 5, start + length <= b.count else { throw BSONError.truncated }
    var doc = BSONDocument()
    while o < start + length - 1 {
      let type = b[o]
      o += 1
      let key = try readCString(b, &o)
      doc.append(key, try readValue(type, b, &o))
    }
    o = start + length
    return doc
  }

  static func readValue(_ type: UInt8, _ b: [UInt8], _ o: inout Int) throws -> BSON {
    switch type {
    case 0x01: return .double(Double(bitPattern: try readLE(b, &o)))
    case 0x02: return .string(try readString(b, &o))
    case 0x03: return .document(try readDocument(b, &o))
    case 0x04: return .array(try readDocument(b, &o).values)
    case 0x05:
      var length = Int(try readLE(b, &o) as Int32)
      guard o < b.count else { throw BSONError.truncated }
      let subtype = b[o]
      o += 1
      if subtype == 0x02 && length >= 4 {
        length = Int(try readLE(b, &o) as Int32)
      }
      guard length >= 0, o + length <= b.count else { throw BSONError.truncated }
      defer { o += length }
      return .binary(subtype: subtype, data: Array(b[o..<o + length]))
    case 0x06: return .undefined
    case 0x07:
      guard o + 12 <= b.count else { throw BSONError.truncated }
      defer { o += 12 }
      return .objectId(ObjectID(bytes: Array(b[o..<o + 12])))
    case 0x08:
      guard o < b.count else { throw BSONError.truncated }
      defer { o += 1 }
      return .bool(b[o] != 0)
    case 0x09: return .datetime(try readLE(b, &o))
    case 0x0A: return .null
    case 0x0B: return .regex(pattern: try readCString(b, &o), options: try readCString(b, &o))
    case 0x0C:
      let ns = try readString(b, &o)
      guard o + 12 <= b.count else { throw BSONError.truncated }
      defer { o += 12 }
      return .dbPointer(namespace: ns, id: ObjectID(bytes: Array(b[o..<o + 12])))
    case 0x0D: return .javascript(try readString(b, &o))
    case 0x0E: return .symbol(try readString(b, &o))
    case 0x0F:
      _ = try readLE(b, &o) as Int32
      let code = try readString(b, &o)
      return .javascriptWithScope(code: code, scope: try readDocument(b, &o))
    case 0x10: return .int32(try readLE(b, &o))
    case 0x11:
      let increment: UInt32 = try readLE(b, &o)
      let time: UInt32 = try readLE(b, &o)
      return .timestamp(time: time, increment: increment)
    case 0x12: return .int64(try readLE(b, &o))
    case 0x13:
      let low: UInt64 = try readLE(b, &o)
      let high: UInt64 = try readLE(b, &o)
      return .decimal128(Decimal128(high: high, low: low))
    case 0xFF: return .minKey
    case 0x7F: return .maxKey
    default: throw BSONError.invalid("unknown type 0x\(String(type, radix: 16))")
    }
  }
}
