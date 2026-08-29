import Foundation

/// A BSON wire codec. Encodes a `BSON` value (document or array) to its BSON
/// binary representation and decodes BSON bytes back to a `BSON` value, covering
/// the full BSON spec (documents, arrays, string, double, int32, int64, bool,
/// null, ObjectId, datetime, binary, regex, symbol, decimal128, min/max key,
/// undefined — and the JS code types for documents/arrays).
public enum BSONCodec {
  // MARK: - Element type bytes (from the BSON spec)
  private enum ElementType: UInt8 {
    case double = 0x01
    case string = 0x02
    case document = 0x03
    case array = 0x04
    case binary = 0x05
    case undefined = 0x06
    case objectId = 0x07
    case boolean = 0x08
    case datetime = 0x09
    case null = 0x0A
    case regex = 0x0B
    case symbol = 0x0E
    case int32 = 0x10
    case timestamp = 0x11
    case int64 = 0x12
    case decimal128 = 0x13
    case minKey = 0xFF
    case maxKey = 0x7F
  }

  private enum Writer {
    static func append<T: FixedWidthInteger>(_ value: T, to data: inout Data) {
      var le = value.littleEndian
      withUnsafeBytes(of: &le) { data.append(contentsOf: $0) }
    }

    static func appendFloat(_ value: Double, to data: inout Data) {
      var le = value.bitPattern.littleEndian
      withUnsafeBytes(of: &le) { data.append(contentsOf: $0) }
    }

    static func appendCString(_ s: String, to data: inout Data) {
      data.append(contentsOf: Array(s.utf8))
      data.append(0)
    }
  }

  private enum Reader {
    static func read<T: FixedWidthInteger>(_ data: Data, at offset: inout Int, _ type: T.Type) -> T? {
      let size = MemoryLayout<T>.size
      guard offset + size <= data.count else { return nil }
      let raw = data.subdata(in: offset..<(offset + size))
      let value = raw.withUnsafeBytes { $0.load(as: T.self) }
      offset += size
      return T(littleEndian: value)
    }

    static func readFloat(_ data: Data, at offset: inout Int) -> Double? {
      let size = MemoryLayout<Double>.size
      guard offset + size <= data.count else { return nil }
      let raw = data.subdata(in: offset..<(offset + size))
      let bits = raw.withUnsafeBytes { $0.load(as: UInt64.self) }
      offset += size
      return Double(bitPattern: UInt64(littleEndian: bits))
    }

    static func readCString(_ data: Data, at offset: inout Int) -> String? {
      guard offset < data.count else { return nil }
      guard let end = data[offset...].firstIndex(of: 0) else { return nil }
      let bytes = data[offset..<end]
      offset = end + 1
      return String(bytes: bytes, encoding: .utf8)
    }

    static func readLength(_ data: Data, at offset: inout Int) -> Int? {
      guard let l = read(data, at: &offset, Int32.self) else { return nil }
      return Int(l)
    }
  }

  // MARK: - Public API

  /// Encodes a BSON document to its wire representation.
  public static func encode(_ value: BSON) -> Data {
    switch value {
    case .document(let doc): return encodeDocument(doc)
    case .array(let items): return encodeDocument(arrayToDocument(items))
    default:
      // A bare scalar has no top-level document form; wrap it so it is still
      // valid BSON (single-key doc). Callers use documents/arrays in practice.
      return encodeDocument(BSONDocument(dictionaryLiteral: ("value", value)))
    }
  }

  /// Decodes BSON bytes into a BSON value.
  public static func decode(_ data: Data) throws -> BSON {
    var offset = 0
    let doc = try decodeDocument(data, offset: &offset)
    return .document(doc)
  }

  /// Decodes BSON bytes into a BSONDocument (the common case).
  public static func decodeDocument(_ data: Data) throws -> BSONDocument {
    var offset = 0
    return try decodeDocument(data, offset: &offset)
  }

  // MARK: - Document encode

  @inline(__always) private static func keyBytes(_ key: String) -> [UInt8] {
    var k = Array(key.utf8)
    k.append(0)
    return k
  }

  private static func encodeDocument(_ doc: BSONDocument) -> Data {
    var body = Data()
    for (key, value) in doc.all {
      switch value {
      case .double(let d):
        body.append(ElementType.double.rawValue)
        body.append(contentsOf: keyBytes(key))
        Writer.appendFloat(d, to: &body)
      case .string(let s):
        body.append(ElementType.string.rawValue)
        body.append(contentsOf: keyBytes(key))
        let utf8 = Array(s.utf8)
        Writer.append(Int32(utf8.count + 1), to: &body)
        body.append(contentsOf: utf8)
        body.append(0)
      case .document(let sub):
        body.append(ElementType.document.rawValue)
        body.append(contentsOf: keyBytes(key))
        // encodeDocument emits its own 4-byte length prefix + trailing NUL.
        body.append(contentsOf: encodeDocument(sub))
      case .array(let items):
        body.append(ElementType.array.rawValue)
        body.append(contentsOf: keyBytes(key))
        // Arrays are stored as a document with "0".."n" keys (already length-prefixed).
        body.append(contentsOf: encodeDocument(arrayToDocument(items)))
      case .binary(let bin):
        body.append(ElementType.binary.rawValue)
        body.append(contentsOf: keyBytes(key))
        Writer.append(Int32(bin.data.count), to: &body)
        body.append(bin.subtype.rawValue)
        body.append(contentsOf: bin.data)
      case .undefined:
        body.append(ElementType.undefined.rawValue)
        body.append(contentsOf: keyBytes(key))
      case .objectID(let oid):
        body.append(ElementType.objectId.rawValue)
        body.append(contentsOf: keyBytes(key))
        body.append(contentsOf: oid.bytes)
      case .bool(let b):
        body.append(ElementType.boolean.rawValue)
        body.append(contentsOf: keyBytes(key))
        body.append(b ? 1 : 0)
      case .datetime(let date):
        body.append(ElementType.datetime.rawValue)
        body.append(contentsOf: keyBytes(key))
        Writer.append(Int64(date.timeIntervalSince1970 * 1000), to: &body)
      case .null:
        body.append(ElementType.null.rawValue)
        body.append(contentsOf: keyBytes(key))
      case .regex(let re):
        body.append(ElementType.regex.rawValue)
        body.append(contentsOf: keyBytes(key))
        Writer.appendCString(re.pattern, to: &body)
        Writer.appendCString(re.options, to: &body)
      case .symbol(let sym):
        body.append(ElementType.symbol.rawValue)
        body.append(contentsOf: keyBytes(key))
        let utf8 = Array(sym.stringValue.utf8)
        Writer.append(Int32(utf8.count + 1), to: &body)
        body.append(contentsOf: utf8)
        body.append(0)
      case .int32(let i):
        body.append(ElementType.int32.rawValue)
        body.append(contentsOf: keyBytes(key))
        Writer.append(i, to: &body)
      case .int64(let i):
        body.append(ElementType.int64.rawValue)
        body.append(contentsOf: keyBytes(key))
        Writer.append(i, to: &body)
      case .decimal128(let dec):
        body.append(ElementType.decimal128.rawValue)
        body.append(contentsOf: keyBytes(key))
        body.append(contentsOf: dec.bytes)
      case .minKey:
        body.append(ElementType.minKey.rawValue)
        body.append(contentsOf: keyBytes(key))
      case .maxKey:
        body.append(ElementType.maxKey.rawValue)
        body.append(contentsOf: keyBytes(key))
      }
    }
    var out = Data()
    Writer.append(Int32(body.count + 5), to: &out)
    out.append(body)
    out.append(0)
    return out
  }

  /// Maps an array to a document with "0"..."n" keys.
  private static func arrayToDocument(_ items: [BSON]) -> BSONDocument {
    var doc = BSONDocument()
    for (i, item) in items.enumerated() {
      doc[String(i)] = item
    }
    return doc
  }

  // MARK: - Document decode

  private static func decodeDocument(_ data: Data, offset: inout Int) throws -> BSONDocument {
    guard let length = Reader.readLength(data, at: &offset) else {
      throw BSONError.invalid("document length header truncated")
    }
    // length includes itself (4), body, and the trailing NULL.
    guard offset + length - 4 - 1 <= data.count else {
      throw BSONError.invalid("document length exceeds buffer")
    }
    let end = offset + length - 4 - 1  // exclusive of trailing NULL; absolute
    var doc = BSONDocument()
    while offset < end {
      guard let typeByte = Reader.read(data, at: &offset, UInt8.self) else {
        throw BSONError.invalid("element type byte truncated")
      }
      guard let key = Reader.readCString(data, at: &offset) else {
        throw BSONError.invalid("element key truncated")
      }
      let value = try decodeValue(data, type: typeByte, offset: &offset)
      doc[key] = value
    }
    // Skip trailing NUL.
    if offset < data.count, data[offset] == 0 { offset += 1 }
    return doc
  }

  private static func decodeValue(_ data: Data, type: UInt8, offset: inout Int) throws -> BSON {
    guard let t = ElementType(rawValue: type) else {
      throw BSONError.invalid("unsupported element type \(type)")
    }
    switch t {
    case .double:
      guard let d = Reader.readFloat(data, at: &offset) else {
        throw BSONError.invalid("double truncated")
      }
      return .double(d)
    case .string, .symbol:
      guard let len = Reader.readLength(data, at: &offset) else {
        throw BSONError.invalid("string length truncated")
      }
      guard len >= 1, offset + len - 1 <= data.count else {
        throw BSONError.invalid("string exceeds buffer")
      }
      let strData = data[offset..<(offset + len - 1)]
      offset += len
      guard let s = String(bytes: strData, encoding: .utf8) else {
        throw BSONError.invalid("string not valid UTF-8")
      }
      return t == .string ? .string(s) : .symbol(BSONSymbol(s))
    case .document:
      let sub = try decodeDocument(data, offset: &offset)
      return .document(sub)
    case .array:
      // Arrays are encoded as a document with "0".."n" keys.
      let subDoc = try decodeDocument(data, offset: &offset)
      let ordered = subDoc.elements.sorted { Int($0.key) ?? 0 < Int($1.key) ?? 0 }
      let items = ordered.map(\.value)
      return .array(items)
    case .binary:
      guard let len = Reader.readLength(data, at: &offset) else {
        throw BSONError.invalid("binary length truncated")
      }
      guard let subtypeByte = Reader.read(data, at: &offset, UInt8.self) else {
        throw BSONError.invalid("binary subtype truncated")
      }
      guard offset + len <= data.count else {
        throw BSONError.invalid("binary exceeds buffer")
      }
      let binData = data[offset..<(offset + len)]
      offset += len
      return .binary(BSONBinary(data: Data(binData), subtype: BinarySubtype(subtypeByte)))
    case .undefined:
      return .undefined
    case .objectId:
      guard offset + BSONObjectID.byteCount <= data.count else {
        throw BSONError.invalid("objectId truncated")
      }
      let raw = Array(data[offset..<(offset + BSONObjectID.byteCount)])
      offset += BSONObjectID.byteCount
      return .objectID(try BSONObjectID(bytes: raw))
    case .boolean:
      guard let b = Reader.read(data, at: &offset, UInt8.self) else {
        throw BSONError.invalid("boolean truncated")
      }
      return .bool(b != 0)
    case .datetime:
      guard let ms = Reader.read(data, at: &offset, Int64.self) else {
        throw BSONError.invalid("datetime truncated")
      }
      return .datetime(Date(timeIntervalSince1970: Double(ms) / 1000))
    case .null:
      return .null
    case .regex:
      guard let pattern = Reader.readCString(data, at: &offset) else {
        throw BSONError.invalid("regex pattern truncated")
      }
      guard let options = Reader.readCString(data, at: &offset) else {
        throw BSONError.invalid("regex options truncated")
      }
      return .regex(BSONRegularExpression(pattern: pattern, options: options))
    case .int32:
      guard let i = Reader.read(data, at: &offset, Int32.self) else {
        throw BSONError.invalid("int32 truncated")
      }
      return .int32(i)
    case .timestamp:
      // Timestamp = 8 bytes (increment then time). We don't model it as a
      // first-class case; it appears inside internal docs. Store as int64.
      guard let inc = Reader.read(data, at: &offset, UInt32.self),
            let time = Reader.read(data, at: &offset, UInt32.self) else {
        throw BSONError.invalid("timestamp truncated")
      }
      return .int64(Int64(UInt64(time) << 32 | UInt64(inc)))
    case .int64:
      guard let i = Reader.read(data, at: &offset, Int64.self) else {
        throw BSONError.invalid("int64 truncated")
      }
      return .int64(i)
    case .decimal128:
      guard offset + Decimal128.byteCount <= data.count else {
        throw BSONError.invalid("decimal128 truncated")
      }
      let raw = Array(data[offset..<(offset + Decimal128.byteCount)])
      offset += Decimal128.byteCount
      return .decimal128(try Decimal128(bytes: raw))
    case .minKey:
      return .minKey
    case .maxKey:
      return .maxKey
    }
  }
}
