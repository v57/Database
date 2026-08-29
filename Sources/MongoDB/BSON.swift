import Foundation

/// Errors thrown by the BSON value type, codec, and strict-JSON decoder.
/// Distinct from `MongoDBError` (connection/config/query-level errors) so callers
/// can distinguish "malformed BSON bytes / bad ObjectId / bad JSON number".
public enum BSONError: Error, LocalizedError, Equatable {
  case invalid(String)

  public var errorDescription: String? {
    switch self {
    case .invalid(let m): return "Invalid BSON: \(m)"
    }
  }
}

/// MongoDB's own BSON value type. A full value-typed model of the BSON spec,
/// replacing the swift-bson re-export so the module has zero remote
/// dependencies. Every BSON type maps to a case; containers box `BSONDocument`
/// (documents) and `[BSON]` (arrays).
///
/// Literal conformances mirror the BSON driver's defaults: integer literals
/// produce `.int64`, string literals `.string`, boolean literals `.bool`, so
/// `["age": 30]` yields an int64 and `["name": "ann"]` a string.
public enum BSON: Equatable, Sendable {
  case string(String)
  case int32(Int32)
  case int64(Int64)
  case double(Double)
  case bool(Bool)
  case objectID(BSONObjectID)
  case datetime(Date)
  case binary(BSONBinary)
  case symbol(BSONSymbol)
  case regex(BSONRegularExpression)
  case document(BSONDocument)
  case array([BSON])
  case null
  case undefined
  case minKey
  case maxKey
  case decimal128(Decimal128)
}

// MARK: - Literal conformances

extension BSON: ExpressibleByIntegerLiteral {
  public init(integerLiteral value: Int64) { self = .int64(value) }
}

extension BSON: ExpressibleByStringLiteral {
  public init(stringLiteral value: String) { self = .string(value) }
}

extension BSON: ExpressibleByBooleanLiteral {
  public init(booleanLiteral value: Bool) { self = .bool(value) }
}

extension BSON: ExpressibleByFloatLiteral {
  public init(floatLiteral value: Double) { self = .double(value) }
}

extension BSON: ExpressibleByArrayLiteral {
  public init(arrayLiteral elements: BSON...) { self = .array(elements) }
}

extension BSON: ExpressibleByDictionaryLiteral {
  public init(dictionaryLiteral elements: (String, BSON)...) {
    self = .document(BSONDocument(pairs: elements.map { (key: $0.0, value: $0.1) }))
  }
}
// MARK: - Symbol

/// BSON symbol element (deprecated in the driver but part of the spec).
public struct BSONSymbol: Equatable, Sendable, CustomStringConvertible {
  public let stringValue: String

  public init(_ stringValue: String) { self.stringValue = stringValue }

  public var description: String { stringValue }
}

// MARK: - Decimal128

/// IEEE 754-2008 decimal128 (16 bytes). Stored as raw wire bytes so encode /
/// decode round-trip losslessly; `description` renders a decimal string.
/// A portable big-unsigned decoder is used (no UInt128, which needs macOS 15).
public struct Decimal128: Equatable, Sendable, CustomStringConvertible {
  /// 16 bytes in BSON wire order.
  static let byteCount = 16
  let bytes: [UInt8]

  public init(bytes: [UInt8]) throws {
    guard bytes.count == Self.byteCount else {
      throw BSONError.invalid("decimal128 requires exactly 16 bytes")
    }
    self.bytes = bytes
  }

  /// A zero decimal128.
  public static let zero = try! Decimal128(bytes: [UInt8](repeating: 0, count: 16))

  public var description: String { Self.decodeString(bytes) }

  /// Decodes the 16-byte IEEE decimal128 to a decimal-string representation.
  private static func decodeString(_ b: [UInt8]) -> String {
    // Assemble the 128-bit value as a big-endian byte buffer (unsigned).
    let high = (UInt64(b[0]) << 56) | (UInt64(b[1]) << 48) | (UInt64(b[2]) << 40)
      | (UInt64(b[3]) << 32) | (UInt64(b[4]) << 24) | (UInt64(b[5]) << 16)
      | (UInt64(b[6]) << 8) | UInt64(b[7])
    let low = (UInt64(b[8]) << 56) | (UInt64(b[9]) << 48) | (UInt64(b[10]) << 40)
      | (UInt64(b[11]) << 32) | (UInt64(b[12]) << 24) | (UInt64(b[13]) << 16)
      | (UInt64(b[14]) << 8) | UInt64(b[15])

    let sign = (high >> 63) == 1
    // 5-bit combination field.
    let combo = UInt8((high >> 58) & 0x1F)
    let expCont = UInt16((high >> 50) & 0xFF)  // 8 bits from high, rest from low
    let exponentBits = (UInt16((high >> 50) & 0xFF) << 4) | UInt16((low >> 60) & 0x0F)
    _ = expCont

    // Special encodings: combination field's top two bits == 11.
    if (combo & 0b11000) == 0b11000 {
      // 0b11110 → Infinity, 0b11111 → NaN, other large forms → NaN.
      if combo == 0b11110 { return sign ? "-Infinity" : "Infinity" }
      return "NaN"
    }

    // Finite number: exponent MSBs come from combination bits [4..3], the
    // remaining 12 exponent bits from the continuation.
    let expMSBs = UInt16((combo >> 3) & 0b11)
    let biasedExp = Int((expMSBs << 12) | exponentBits)
    let exponent = biasedExp - 6176

    // Coefficient: 113-bit unsigned integer = top 3 bits (combo & 0b111) {
    // << 110 } | high bits 49..0 | low (64 bits).
    let coefTop3 = UInt64(combo & 0b111)
    let highBits49 = (high >> 1) & ((UInt64(1) << 49) - 1)

    // Build the coefficient as little-endian bytes (6 bytes from highBits49 +
    // top3, plus 8 bytes low).
    var coeffBytes: [UInt8] = []
    // low 64 bits, little-endian.
    var l = low
    for _ in 0..<8 { coeffBytes.append(UInt8(l & 0xFF)); l >>= 8 }
    // highBits49 (49 bits) + coefTop3 (3 bits) = 52 bits, little-endian:
    // bits 0..48 = highBits49, bits 49..51 = coefTop3.
    var h = highBits49 | (coefTop3 << 49)
    for _ in 0..<7 { coeffBytes.append(UInt8(h & 0xFF)); h >>= 8 }

    return renderDecimal(coeffBytes: coeffBytes, exponent: exponent, negative: sign)
  }

  /// `coeffBytes` is little-endian (least-significant byte first). Renders a
  /// decimal string scaled by 10^exponent.
  private static func renderDecimal(coeffBytes: [UInt8], exponent: Int, negative: Bool) -> String {
    let digits = bigToDecimal(coeffBytes)
    if digits == "0" {
      return negative && exponent == 0 ? "-0" : "0"
    }
    let n = digits.count
    var out = ""
    if negative { out += "-" }
    if exponent >= 0 {
      out += digits + String(repeating: "0", count: exponent)
    } else {
      let point = n + exponent
      if point <= 0 {
        out += "0." + String(repeating: "0", count: -point) + digits
      } else if point >= n {
        out += digits + String(repeating: "0", count: -exponent)
      } else {
        let idx = digits.index(digits.startIndex, offsetBy: point)
        out += digits[..<idx] + "." + digits[idx...]
      }
    }
    return out
  }

  /// Converts a little-endian byte array to a decimal string.
  private static func bigToDecimal(_ bytesLE: [UInt8]) -> String {
    // Strip leading excess zero bytes (high-order = end of little-endian array).
    var bytes = Array(bytesLE)
    while bytes.count > 1 && bytes.last == 0 { bytes.removeLast() }
    // Repeatedly divmod by 10.
    var result = ""
    var working = bytes
    while !(working.count == 1 && working[0] == 0) {
      var rem: UInt16 = 0
      for i in stride(from: working.count - 1, through: 0, by: -1) {
        let cur = (rem << 8) | UInt16(working[i])
        working[i] = UInt8(cur / 10)
        rem = cur % 10
      }
      result.append(Character(UnicodeScalar(UInt8(48) + UInt8(rem))))
      while working.count > 1 && working.last == 0 { working.removeLast() }
    }
    return result.isEmpty ? "0" : String(result.reversed())
  }
}


// MARK: - Extended-JSON rendering (display / `.description`)

extension BSON {
  /// Single-line extended JSON of a value.
  var jsonString: String {
    switch self {
    case .string(let s): return "\"\(s.escapedJSON)\""
    case .int32(let i): return String(i)
    case .int64(let i): return String(i)
    case .double(let d): return String(d)
    case .bool(let b): return b ? "true" : "false"
    case .null: return "null"
    case .undefined: return "{\"$undefined\": true}"
    case .document(let d): return d.description
    case .array(let a): return "[" + a.map(\.jsonString).joined(separator: ", ") + "]"
    case .objectID(let oid): return "{\"$oid\": \"\(oid.hex)\"}"
    case .datetime(let date): return "{\"$date\": \"\(ISO8601JSON.string(from: date))\"}"
    case .binary(let bin):
      let base64 = bin.data.base64EncodedString()
      let sub = String(format: "%02x", bin.subtype.rawValue)
      return "{\"$binary\": {\"base64\": \"\(base64)\", \"subType\": \"\(sub)\"}}"
    case .symbol(let s): return "{\"$symbol\": \"\(s.stringValue.escapedJSON)\"}"
    case .regex(let r): return "{\"$regularExpression\": {\"pattern\": \"\(r.pattern.escapedJSON)\", \"options\": \"\(r.options.escapedJSON)\"}}"
    case .decimal128(let d): return "{\"$numberDecimal\": \"\(d.description)\"}"
    case .minKey: return "{\"$minKey\": 1}"
    case .maxKey: return "{\"$maxKey\": 1}"
    }
  }
}

private nonisolated(unsafe) let ISO8601JSON: ISO8601DateFormatter = {
  let f = ISO8601DateFormatter()
  f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
  return f
}()

extension String {
  /// Minimal JSON string escaping (quotes, backslash, control characters).
  var escapedJSON: String {
    var out = ""
    for u in unicodeScalars {
      switch u {
      case "\u{08}": out += "\\b"
      case "\u{0C}": out += "\\f"
      case "\n": out += "\\n"
      case "\r": out += "\\r"
      case "\t": out += "\\t"
      case "\"": out += "\\\""
      case "\\": out += "\\\\"
      default:
        if u.value < 0x20 {
          out += String(format: "\\u%04x", u.value)
        } else {
          out.append(Character(u))
        }
      }
    }
    return out
  }
}
