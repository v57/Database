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

  /// Decodes the 16-byte IEEE decimal128 (BID encoding) to a decimal string.
  /// BSON stores it little-endian: bytes 0–7 are the low 64 bits, bytes 8–15
  /// the high 64 bits. Reading them big-endian turned 19.99 into a number
  /// thousands of digits long.
  private static func decodeString(_ b: [UInt8]) -> String {
    func word(at offset: Int) -> UInt64 {
      (0..<8).reduce(UInt64(0)) { $0 | (UInt64(b[offset + $1]) << (8 * UInt64($1))) }
    }
    let low = word(at: 0)
    let high = word(at: 8)
    let negative = (high >> 63) == 1
    let combination = (high >> 58) & 0b11111

    let exponent: Int
    let coefficientHigh: UInt64
    var coefficientLow = low
    if (high >> 61) & 0b11 == 0b11 {
      // Bits 62–61 set: Infinity / NaN, or a coefficient too large for 34
      // digits, which the spec says to treat as zero.
      if combination == 0b11110 { return negative ? "-Infinity" : "Infinity" }
      if combination == 0b11111 { return "NaN" }
      exponent = Int((high >> 47) & 0x3FFF) - 6176
      coefficientHigh = 0
      coefficientLow = 0
    } else {
      // 14-bit exponent in bits 62–49; 113-bit coefficient = high bits 48–0
      // followed by the 64 low bits.
      exponent = Int((high >> 49) & 0x3FFF) - 6176
      coefficientHigh = high & ((UInt64(1) << 49) - 1)
    }

    // Coefficient as little-endian bytes: 8 low bytes, then 7 high bytes.
    var coeffBytes: [UInt8] = []
    var l = coefficientLow
    for _ in 0..<8 { coeffBytes.append(UInt8(l & 0xFF)); l >>= 8 }
    var h = coefficientHigh
    for _ in 0..<7 { coeffBytes.append(UInt8(h & 0xFF)); h >>= 8 }

    return renderDecimal(coeffBytes: coeffBytes, exponent: exponent, negative: negative)
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
