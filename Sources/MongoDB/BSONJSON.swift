import Foundation

/// Strict JSON -> BSONDocument decoder used by `BSONSupport.document(fromJSON:)`
/// and `Document(fromJSON:)`. Accepts standard JSON (quoted keys/strings, numbers,
/// booleans, null, nested objects, arrays). Number resolution mirrors the BSON
/// driver's extended-JSON decoding: integers fit in Int32 become `.int32`,
/// larger integers become `.int64`, and any fractional/exponent number becomes
/// `.double`.
public struct BSONJSONDecoder {
  private let chars: [Character]
  private var pos = 0

  public init() {
    self.chars = []
    self.pos = 0
  }

  /// Decodes a JSON string into a BSONDocument.
  public func decode(_ json: String) throws -> BSONDocument {
    var p = BSONJSONParser(json)
    p.skipWhitespace()
    let value = try p.parseValue()
    p.skipWhitespace()
    guard p.isAtEnd else {
      throw BSONError.invalid("unexpected trailing content at column \(p.pos + 1)")
    }
    guard case .document(let doc) = value else {
      throw BSONError.invalid("top-level JSON value must be an object")
    }
    return doc
  }
}

/// The recursive-descent JSON parser backing `BSONJSONDecoder`.
struct BSONJSONParser {
  let chars: [Character]
  var pos = 0

  init(_ s: String) { self.chars = Array(s) }

  var isAtEnd: Bool { pos >= chars.count }

  func peek() -> Character? { pos < chars.count ? chars[pos] : nil }

  mutating func advance() -> Character? {
    defer { pos += 1 }
    return pos < chars.count ? chars[pos] : nil
  }

  mutating func skipWhitespace() {
    while let c = peek(), c.isWhitespace { pos += 1 }
  }

  func error(_ message: String) -> BSONError {
    .invalid("\(message) at column \(pos + 1)")
  }

  mutating func parseValue() throws -> BSON {
    skipWhitespace()
    guard let c = peek() else { throw error("expected value") }
    switch c {
    case "{": return .document(try parseObject())
    case "[": return .array(try parseArray())
    case "\"": return .string(try parseString())
    case "-", "0"..."9": return try parseNumber()
    default:
      if c.isLetter {
        let word = scanWord()
        switch word {
        case "true": return .bool(true)
        case "false": return .bool(false)
        case "null": return .null
        default: throw error("unexpected token \"\(word)\"")
        }
      }
      throw error("expected value")
    }
  }

  mutating func parseObject() throws -> BSONDocument {
    _ = advance()  // '{'
    skipWhitespace()
    var doc = BSONDocument()
    if peek() == "}" { _ = advance(); return doc }
    while true {
      // Keys must be quoted strings in strict JSON.
      guard peek() == "\"" else { throw error("expected \" to begin object key") }
      let key = try parseString()
      skipWhitespace()
      guard peek() == ":" else { throw error("expected ':' after key") }
      _ = advance()
      skipWhitespace()
      let value = try parseValue()
      doc[key] = value
      skipWhitespace()
      switch peek() {
      case ",": _ = advance(); skipWhitespace()
        if peek() == "}" { _ = advance(); return doc }
      case "}": _ = advance(); return doc
      default: throw error("expected ',' or '}'")
      }
    }
  }

  mutating func parseArray() throws -> [BSON] {
    _ = advance()  // '['
    skipWhitespace()
    var values: [BSON] = []
    if peek() == "]" { _ = advance(); return values }
    while true {
      values.append(try parseValue())
      skipWhitespace()
      switch peek() {
      case ",":
        _ = advance()
        skipWhitespace()
        if peek() == "]" { _ = advance(); return values }
      case "]": _ = advance(); return values
      default: throw error("expected ',' or ']'")
      }
    }
  }

  mutating func parseString() throws -> String {
    guard peek() == "\"" else { throw error("expected string") }
    _ = advance()
    var out = ""
    while let c = peek() {
      switch c {
      case "\"":
        _ = advance()
        return out
      case "\\":
        _ = advance()
        guard let escaped = advance() else { throw error("unterminated string") }
        switch escaped {
        case "\"": out.append("\"")
        case "\\": out.append("\\")
        case "/": out.append("/")
        case "b": out.append("\u{08}")
        case "f": out.append("\u{0C}")
        case "n": out.append("\n")
        case "r": out.append("\r")
        case "t": out.append("\t")
        case "u":
          var hex = ""
          for _ in 0..<4 {
            guard let h = advance() else { throw error("incomplete \\u escape") }
            hex.append(h)
          }
          guard let value = UInt32(hex, radix: 16).flatMap(UnicodeScalar.init) else {
            throw error("invalid \\u escape")
          }
          out.unicodeScalars.append(value)
        default: throw error("unknown escape '\\\(escaped)'")
        }
      default:
        out.append(c)
        pos += 1
      }
    }
    throw error("unterminated string")
  }

  mutating func parseNumber() throws -> BSON {
    var raw = ""
    if peek() == "-" { raw.append(advance()!) }
    var digitCount = 0
    while let c = peek(), c.isNumber {
      raw.append(c); pos += 1; digitCount += 1
    }
    guard digitCount > 0 else { throw error("invalid number") }
    var isFloat = false
    if peek() == "." {
      isFloat = true
      raw.append(advance()!)
      var frac = 0
      while let c = peek(), c.isNumber {
        raw.append(c); pos += 1; frac += 1
      }
      guard frac > 0 else { throw error("invalid number: expected digits after '.'") }
    }
    if let c = peek(), c == "e" || c == "E" {
      isFloat = true
      raw.append(advance()!)
      if let s = peek(), s == "+" || s == "-" { raw.append(advance()!) }
      var exp = 0
      while let c = peek(), c.isNumber {
        raw.append(c); pos += 1; exp += 1
      }
      guard exp > 0 else { throw error("invalid number: expected digits in exponent") }
    }
    // Must end at a structural boundary.
    if let next = peek(), !next.isWhitespace, next != ",", next != "}", next != "]" {
      throw error("invalid number near \"\(raw)\"")
    }
    if !isFloat {
      if let i32 = Int32(raw) { return .int32(i32) }
      if let i64 = Int64(raw) { return .int64(i64) }
    }
    guard let d = Double(raw) else { throw error("invalid number \"\(raw)\"") }
    return .double(d)
  }

  mutating func scanWord() -> String {
    var word = ""
    while let c = peek(), c.isLetter { word.append(c); pos += 1 }
    return word
  }
}

// MARK: - Document(fromJSON:) — keeps `Document(fromJSON: json)` (used by
// QueryParserTests) compiling unchanged with the own value type.

extension BSONDocument {
  /// Parses a strict JSON string into a BSON document.
  public init(fromJSON json: String) throws {
    self = try BSONJSONDecoder().decode(json)
  }
}
