import Foundation

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
///
/// mongosh syntax is accepted too, so text copied from a shell script or an
/// exported pipeline parses as-is: `//` and `/* */` comments, regex literals
/// (`/^a/i`), `undefined`, `NaN`, `Infinity`, and the shell's type helpers —
/// `ObjectId("…")`, `ISODate("…")`, `new Date(…)`, `NumberInt`, `NumberLong`,
/// `NumberDecimal`, `UUID("…")`, `BinData(…)`, `RegExp(…)`, `MinKey`/`MaxKey`.
/// `ShellSyntax.render` writes the same spellings back.
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

  /// Parse any single value — an object, array, string, number, shell helper
  /// call… — e.g. an aggregation stage's argument (`{ _id: "$city" }`,
  /// `10`, `"$tags"`). Bare `key: value` pairs without braces still parse, as
  /// a document, like the query bar's Filter text.
  public static func parseValue(_ text: String) throws -> BSON {
    var parser = Parser(Array(text))
    parser.skipWhitespace()
    guard !parser.isAtEnd else { throw parser.error("value is empty") }
    let startsAsValue = parser.peek().map { "{[\"'-/0123456789".contains($0) } ?? false
    do {
      let value = try parser.parseValue()
      parser.skipWhitespace()
      guard parser.isAtEnd else { throw parser.error("unexpected trailing content") }
      return value
    } catch let valueError {
      // `status: "A"` reads as bare pairs; report whichever reading the text
      // looked like it meant.
      do { return .document(try parse(text)) } catch {
        throw startsAsValue ? valueError : error
      }
    }
  }

  /// Finds the pipeline array in JavaScript source: the argument of a
  /// `….aggregate([…])` call (mongosh, Compass, driver snippets), else the
  /// first array literal (`const pipeline = […]`, a bare `[…]`, JSON). Also
  /// returns the collection the call names (`db.orders`, `db["orders"]`,
  /// `db.getCollection("orders")`) when there is one.
  static func pipelineSource(_ text: String) throws -> (stages: [BSON], collection: String?) {
    var scanner = Parser(Array(text))
    let call = scanner.findAggregateCall()
    let start: Int
    if let call, let array = call.arrayStart {
      start = array
    } else if let first = Parser(Array(text)).firstArrayStart() {
      start = first
    } else {
      throw MongoDBError.invalidQuery(
        "No pipeline found — expected db.collection.aggregate([...]) or an array of stages")
    }
    var parser = Parser(Array(text))
    parser.pos = start
    let stages = try parser.parseArray()
    let collection = call.flatMap { collectionName(beforeCall: String(text.prefix($0.dotIndex))) }
    return (stages, collection)
  }

  /// `db.orders`, `db["orders"]` or `db.getCollection("orders")` at the end of
  /// the text before `.aggregate(`.
  private static func collectionName(beforeCall prefix: String) -> String? {
    let patterns = [
      #"getCollection\(\s*(["'])(.*?)\1\s*\)\s*$"#,
      #"\[\s*(["'])(.*?)\1\s*\]\s*$"#,
      #"db\.()([A-Za-z_$][\w$.]*)\s*$"#,
    ]
    let range = NSRange(prefix.startIndex..., in: prefix)
    for pattern in patterns {
      guard let regex = try? NSRegularExpression(pattern: pattern),
        let match = regex.firstMatch(in: prefix, range: range),
        let name = Range(match.range(at: 2), in: prefix)
      else { continue }
      return String(prefix[name])
    }
    return nil
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

  /// Skips whitespace and JavaScript comments (`// …` to end of line, `/* … */`).
  /// A regex literal can never start with `//` or `/*`, so this is unambiguous.
  mutating func skipWhitespace() {
    while let c = peek() {
      if c.isWhitespace {
        pos += 1
      } else if c == "/", pos + 1 < chars.count, chars[pos + 1] == "/" {
        while let c = peek(), !c.isNewline { pos += 1 }
      } else if c == "/", pos + 1 < chars.count, chars[pos + 1] == "*" {
        pos += 2
        while pos < chars.count, !(chars[pos] == "*" && pos + 1 < chars.count && chars[pos + 1] == "/") {
          pos += 1
        }
        pos = min(pos + 2, chars.count)
      } else {
        return
      }
    }
  }

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
    case "/": return .regex(try parseRegexLiteral())
    case "-" where pos + 1 < chars.count && chars[pos + 1] == "I":
      pos += 1
      guard scanWord() == "Infinity" else { throw error("invalid number") }
      return .double(-.infinity)
    case "-", "0"..."9": return try parseNumber()
    default:
      guard c.isLetter || c == "_" || c == "$" else { throw error("expected value") }
      let start = pos
      let word = scanIdentifier()
      switch word {
      case "true": return .bool(true)
      case "false": return .bool(false)
      case "null": return .null
      case "undefined": return .undefined
      case "NaN": return .double(.nan)
      case "Infinity": return .double(.infinity)
      case "new":
        skipWhitespace()
        let type = scanIdentifier()
        guard !type.isEmpty else { throw error("expected a type after 'new'") }
        return try parseCall(type)
      default:
        skipWhitespace()
        if peek() == "(" { return try parseCall(word) }
        if word == "MinKey" { return .minKey }
        if word == "MaxKey" { return .maxKey }
        pos = start
        throw error("unexpected token \"\(word)\" — strings must be quoted")
      }
    }
  }

  /// `Name(arg, …)` — a mongosh type helper such as `ObjectId("…")`.
  mutating func parseCall(_ name: String) throws -> BSON {
    skipWhitespace()
    guard peek() == "(" else { throw error("expected '(' after \(name)") }
    let start = pos
    _ = advance()
    var arguments: [BSON] = []
    skipWhitespace()
    if peek() == ")" {
      _ = advance()
    } else {
      arguments: while true {
        arguments.append(try parseValue())
        skipWhitespace()
        switch peek() {
        case ",": _ = advance()
        case ")":
          _ = advance()
          break arguments
        default: throw error("expected ',' or ')'")
        }
      }
    }
    do {
      return try ShellSyntax.construct(name, arguments)
    } catch let failure as ShellSyntax.ConstructorError {
      pos = start
      throw error(failure.message)
    }
  }

  /// `/pattern/flags`. `\/` ends up as `/` in the pattern (it only escapes the
  /// delimiter); every other escape is kept for the regex engine. A `/` inside
  /// a `[…]` class doesn't end the literal, as in JavaScript.
  mutating func parseRegexLiteral() throws -> BSONRegularExpression {
    _ = advance()  // '/'
    var pattern = ""
    var inClass = false
    while true {
      guard let c = advance(), !c.isNewline else { throw error("unterminated regular expression") }
      switch c {
      case "\\":
        guard let escaped = advance(), !escaped.isNewline else {
          throw error("unterminated regular expression")
        }
        if escaped != "/" { pattern.append("\\") }
        pattern.append(escaped)
        continue
      case "[": inClass = true
      case "]": inClass = false
      case "/" where !inClass:
        var options = ""
        while let flag = peek(), flag.isLetter {
          options.append(flag)
          pos += 1
        }
        return BSONRegularExpression(pattern: pattern, options: options)
      default: break
      }
      pattern.append(c)
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
    if let next = peek(), !next.isWhitespace, next != ",", next != "}", next != "]",
      next != ")", next != "/"
    {
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

  /// Consumes a JavaScript identifier: `ObjectId`, `NumberLong`, `Int32`.
  mutating func scanIdentifier() -> String {
    var word = ""
    while let c = peek(), c.isLetter || c == "_" || c == "$" || (c.isNumber && !word.isEmpty) {
      word.append(c)
      pos += 1
    }
    return word
  }

  // MARK: Locating a pipeline in a script

  /// The next position past a string literal or comment starting at `pos`, or
  /// nil when none starts there. Used to skip code that only looks like code.
  private func skippingLiteral(at index: Int) -> Int? {
    let c = chars[index]
    if c == "\"" || c == "'" || c == "`" {
      var i = index + 1
      while i < chars.count, chars[i] != c {
        i += chars[i] == "\\" ? 2 : 1
      }
      return i + 1
    }
    if c == "/", index + 1 < chars.count, chars[index + 1] == "/" {
      var i = index
      while i < chars.count, !chars[i].isNewline { i += 1 }
      return i
    }
    if c == "/", index + 1 < chars.count, chars[index + 1] == "*" {
      var i = index + 2
      while i + 1 < chars.count, !(chars[i] == "*" && chars[i + 1] == "/") { i += 1 }
      return i + 2
    }
    return nil
  }

  /// The first `.aggregate(` call: where its `.` is, and where its array
  /// argument starts (nil when the argument is a variable, not `[…]`).
  mutating func findAggregateCall() -> (dotIndex: Int, arrayStart: Int?)? {
    let name = Array(".aggregate")
    var i = 0
    while i < chars.count {
      if let next = skippingLiteral(at: i) {
        i = next
        continue
      }
      if chars[i] == ".", i + name.count <= chars.count,
        Array(chars[i..<(i + name.count)]) == name
      {
        pos = i + name.count
        skipWhitespace()
        if peek() == "(" {
          _ = advance()
          skipWhitespace()
          return (i, peek() == "[" ? pos : nil)
        }
      }
      i += 1
    }
    return nil
  }

  /// The first `[` outside strings and comments.
  func firstArrayStart() -> Int? {
    var i = 0
    while i < chars.count {
      if let next = skippingLiteral(at: i) {
        i = next
        continue
      }
      if chars[i] == "[" { return i }
      i += 1
    }
    return nil
  }
}

extension Character {
  /// Characters allowed in an unquoted key: `user`, `$gt`, `address.city`.
  fileprivate var isBareKeyCharacter: Bool {
    isLetter || isNumber || self == "_" || self == "$" || self == "."
  }
}
