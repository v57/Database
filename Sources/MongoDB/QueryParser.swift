import Foundation
import MongoSwift

/// Tolerant MongoDB query parser for filter input.
///
/// Accepts all three of these forms, interchangeably:
///   { "user": "some" }             — strict JSON
///   { user: "some" }               — JS style, unquoted keys
///   user: "some"                   — bare key/value pairs, no outer braces
///
/// Values may be quoted strings (single or double quotes, with JSON escapes),
/// numbers (int32/int64/double, matching the driver's extended-JSON number
/// resolution), booleans, `null`, nested objects, and arrays. Anything else
/// (e.g. an unquoted bare word as a value) is rejected with a column number.
public enum QueryParser {
  /// Parse a query string into a BSON `Document` filter.
  public static func parse(_ text: String) throws -> Document {
    var parser = Parser(Array(text))
    parser.skipWhitespace()
    guard !parser.isAtEnd else { throw parser.error("query is empty") }

    let document: Document
    switch parser.peek() {
    case "{": document = try parser.parseObject()
    case "[": throw parser.error("query must be key: value pairs or an object, not an array")
    default: document = try parser.parseBarePairs()
    }

    parser.skipWhitespace()
    guard parser.isAtEnd else { throw parser.error("unexpected trailing content") }
    return document
  }
}

extension BSONSupport {
  /// Parse a filter/query string in any supported form: strict JSON,
  /// JS-style unquoted keys, or bare `key: value` pairs (no braces).
  public static func document(fromQuery text: String) throws -> Document {
    try QueryParser.parse(text)
  }
}

// MARK: - Scanner

private struct Parser {
  /// Characters of the raw input; `pos` is the next unconsumed index.
  let chars: [Character]
  var pos = 0

  init(_ chars: [Character]) { self.chars = chars }

  var isAtEnd: Bool { pos >= chars.count }
  func peek() -> Character? { pos < chars.count ? chars[pos] : nil }

  mutating func advance() -> Character? {
    defer { pos += 1 }
    return pos < chars.count ? chars[pos] : nil
  }

  mutating func skipWhitespace() { while let c = peek(), c.isWhitespace { pos += 1 } }

  func error(_ message: String) -> MongoDBError { .invalidQuery("\(message) at column \(pos + 1)") }

  // MARK: Documents and pairs

  /// `{ ... }` — a full object, braces required.
  mutating func parseObject() throws -> Document {
    _ = advance()  // '{'
    skipWhitespace()
    var document = Document()
    if peek() == "}" {
      _ = advance()
      return document
    }
    while true {
      try parsePair(into: &document)
      skipWhitespace()
      switch peek() {
      case ",":
        _ = advance()
        skipWhitespace()
        if peek() == "}" {  // trailing comma, JSON5-style
          _ = advance()
          return document
        }
      case "}":
        _ = advance()
        return document
      default: throw error("expected ',' or '}'")
      }
    }
  }

  /// `key: value, key: value` — top-level pairs without braces.
  mutating func parseBarePairs() throws -> Document {
    var document = Document()
    while true {
      skipWhitespace()
      if isAtEnd { return document }
      try parsePair(into: &document)
      skipWhitespace()
      switch peek() {
      case ",": _ = advance()
      case nil: return document
      default: throw error("expected ',' or end of query")
      }
    }
  }

  mutating func parsePair(into document: inout Document) throws {
    let key = try parseKey()
    skipWhitespace()
    guard peek() == ":" else { throw error("expected ':' after key \"\(key)\"") }
    _ = advance()
    skipWhitespace()
    let value = try parseValue()
    document[key] = value
  }

  // MARK: Keys

  /// A quoted string key, or a bare key: letters, digits, `_`, `$`, `.`
  /// (e.g. `user`, `$gt`, `address.city`).
  mutating func parseKey() throws -> String {
    skipWhitespace()
    if let c = peek(), c == "\"" || c == "'" { return try parseString() }
    var key = ""
    while let c = peek(), c.isBareKeyCharacter {
      key.append(c)
      pos += 1
    }
    guard !key.isEmpty else { throw error("expected key") }
    return key
  }

  // MARK: Values

  mutating func parseValue() throws -> BSON {
    skipWhitespace()
    guard let c = peek() else { throw error("expected value") }
    switch c {
    case "\"", "'": return .string(try parseString())
    case "{": return .document(try parseObject())
    case "[": return .array(try parseArray())
    case "-", "0"..."9": return try parseNumber()
    default:
      if c.isLetter {
        let word = scanWord()
        switch word {
        case "true": return .bool(true)
        case "false": return .bool(false)
        case "null": return .null
        default: throw error("unexpected token \"\(word)\" — strings must be quoted")
        }
      }
      throw error("expected value")
    }
  }

  /// `[...]` — array of values.
  mutating func parseArray() throws -> [BSON] {
    _ = advance()  // '['
    skipWhitespace()
    var values: [BSON] = []
    if peek() == "]" {
      _ = advance()
      return values
    }
    while true {
      values.append(try parseValue())
      skipWhitespace()
      switch peek() {
      case ",":
        _ = advance()
        skipWhitespace()
        if peek() == "]" {  // trailing comma, JSON5-style
          _ = advance()
          return values
        }
      case "]":
        _ = advance()
        return values
      default: throw error("expected ',' or ']'")
      }
    }
  }

  /// Quoted string with JSON escapes. Accepted: `"..."` and `'...'`.
  mutating func parseString() throws -> String {
    guard let quote = advance() else { throw error("expected string") }
    var out = ""
    while let c = peek() {
      switch c {
      case quote:
        _ = advance()
        return out
      case "\\":
        _ = advance()
        guard let escaped = advance() else { throw error("unterminated string") }
        switch escaped {
        case "\"": out.append("\"")
        case "'": out.append("'")
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

  /// JSON number: `-?(digits)(.digits)?((e|E)(+|-)?digits)?`.
  /// Resolves int32 -> int64 -> double, mirroring the driver's
  /// extended-JSON decoding so strict and tolerant paths agree.
  mutating func parseNumber() throws -> BSON {
    var raw = ""
    if peek() == "-" { raw.append(advance()!) }
    var digitCount = 0
    while let c = peek(), c.isNumber {
      raw.append(c)
      pos += 1
      digitCount += 1
    }
    guard digitCount > 0 else { throw error("invalid number") }

    var isFloat = false
    if peek() == "." {
      isFloat = true
      raw.append(advance()!)
      var fractionDigits = 0
      while let c = peek(), c.isNumber {
        raw.append(c)
        pos += 1
        fractionDigits += 1
      }
      guard fractionDigits > 0 else { throw error("invalid number: expected digits after '.'") }
    }
    if let c = peek(), c == "e" || c == "E" {
      isFloat = true
      raw.append(advance()!)
      if let s = peek(), s == "+" || s == "-" { raw.append(advance()!) }
      var exponentDigits = 0
      while let c = peek(), c.isNumber {
        raw.append(c)
        pos += 1
        exponentDigits += 1
      }
      guard exponentDigits > 0 else { throw error("invalid number: expected digits in exponent") }
    }

    // The number must end at a structural boundary so `1abc` can't
    // silently become `1`.
    if let next = peek(), !next.isWhitespace, next != ",", next != "}", next != "]" {
      throw error("invalid number near \"\(raw)\"")
    }

    if !isFloat {
      if let int32 = Int32(raw) { return .int32(int32) }
      if let int64 = Int64(raw) { return .int64(int64) }
    }
    guard let double = Double(raw) else { throw error("invalid number \"\(raw)\"") }
    return .double(double)
  }

  /// Consumes a run of letters (used to detect `true` / `false` / `null`).
  mutating func scanWord() -> String {
    var word = ""
    while let c = peek(), c.isLetter {
      word.append(c)
      pos += 1
    }
    return word
  }
}

extension Character {
  /// Characters allowed in an unquoted key: `user`, `$gt`, `address.city`.
  fileprivate var isBareKeyCharacter: Bool {
    isLetter || isNumber || self == "_" || self == "$" || self == "."
  }
}
