import Foundation

/// Text forms of BSON: mongosh-style shell syntax (for reading and editing) and
/// relaxed Extended JSON v2 (for export).
public enum BSONTextStyle: Sendable {
  case shell
  case extendedJSON
}

extension BSON {
  /// One line, or indented when `indent` is set.
  public func text(_ style: BSONTextStyle = .shell, indent: Int? = nil) -> String {
    var out = ""
    BSONPrinter(style: style, indent: indent).write(self, into: &out, level: 0)
    return out
  }
}

extension BSONDocument {
  public func text(_ style: BSONTextStyle = .shell, indent: Int? = nil) -> String {
    BSON.document(self).text(style, indent: indent)
  }

  /// Parses mongosh syntax or (Extended) JSON into a document.
  public init(parsing text: String) throws {
    let value = try BSONParser.parse(text)
    guard case .document(let doc) = value else { throw BSONError.parse("Expected a document like { … }", offset: 0) }
    self = doc
  }
}

extension BSON {
  public init(parsing text: String) throws { self = try BSONParser.parse(text) }
}

// MARK: - Printing

struct BSONPrinter {
  var style: BSONTextStyle
  var indent: Int?

  nonisolated(unsafe) static let isoFormatter: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return f
  }()

  static func iso(_ ms: Int64) -> String {
    isoFormatter.string(from: Date(timeIntervalSince1970: Double(ms) / 1000))
  }

  func quote(_ s: String) -> String {
    var out = "\""
    for scalar in s.unicodeScalars {
      switch scalar {
      case "\"": out += "\\\""
      case "\\": out += "\\\\"
      case "\n": out += "\\n"
      case "\r": out += "\\r"
      case "\t": out += "\\t"
      case "\u{08}": out += "\\b"
      case "\u{0C}": out += "\\f"
      default:
        if scalar.value < 0x20 {
          out += String(format: "\\u%04x", scalar.value)
        } else {
          out.unicodeScalars.append(scalar)
        }
      }
    }
    return out + "\""
  }

  func key(_ k: String) -> String {
    if style == .shell, k.range(of: "^[A-Za-z_$][A-Za-z0-9_$]*$", options: .regularExpression) != nil {
      return k
    }
    return quote(k)
  }

  func formatDouble(_ d: Double) -> String {
    if d.isNaN { return style == .shell ? "NaN" : "{\"$numberDouble\": \"NaN\"}" }
    if d.isInfinite {
      let text = d > 0 ? "Infinity" : "-Infinity"
      return style == .shell ? text : "{\"$numberDouble\": \"\(text)\"}"
    }
    if d == d.rounded() && abs(d) < 1e16 { return String(format: "%.1f", d) }
    return "\(d)"
  }

  func write(_ value: BSON, into out: inout String, level: Int) {
    let shell = style == .shell
    switch value {
    case .double(let d): out += formatDouble(d)
    case .string(let s): out += quote(s)
    case .document(let doc): writeDocument(doc, into: &out, level: level)
    case .array(let items):
      if items.isEmpty {
        out += "[]"
        return
      }
      out += "["
      for (i, item) in items.enumerated() {
        out += i == 0 ? "" : ","
        newline(&out, level + 1)
        write(item, into: &out, level: level + 1)
      }
      newline(&out, level)
      out += "]"
    case .binary(let subtype, let data):
      if subtype == 4 && data.count == 16 {
        let uuid = UUID(
          uuid: (
            data[0], data[1], data[2], data[3], data[4], data[5], data[6], data[7], data[8], data[9], data[10], data[11],
            data[12], data[13], data[14], data[15]
          )
        ).uuidString.lowercased()
        out += shell ? "UUID(\"\(uuid)\")" : "{\"$uuid\": \"\(uuid)\"}"
      } else {
        let b64 = Data(data).base64EncodedString()
        out +=
          shell
          ? "BinData(\(subtype), \"\(b64)\")"
          : "{\"$binary\": {\"base64\": \"\(b64)\", \"subType\": \"\(String(format: "%02x", subtype))\"}}"
      }
    case .undefined: out += shell ? "undefined" : "{\"$undefined\": true}"
    case .objectId(let id): out += shell ? "ObjectId(\"\(id.hex)\")" : "{\"$oid\": \"\(id.hex)\"}"
    case .bool(let b): out += b ? "true" : "false"
    case .datetime(let ms):
      out += shell ? "ISODate(\"\(Self.iso(ms))\")" : "{\"$date\": \"\(Self.iso(ms))\"}"
    case .null: out += "null"
    case .regex(let pattern, let options):
      out +=
        shell
        ? "/\(pattern.replacingOccurrences(of: "/", with: "\\/"))/\(options)"
        : "{\"$regularExpression\": {\"pattern\": \(quote(pattern)), \"options\": \"\(options)\"}}"
    case .dbPointer(let ns, let id):
      out += "{\"$dbPointer\": {\"$ref\": \(quote(ns)), \"$id\": {\"$oid\": \"\(id.hex)\"}}}"
    case .javascript(let code): out += shell ? "Code(\(quote(code)))" : "{\"$code\": \(quote(code))}"
    case .symbol(let s): out += shell ? quote(s) : "{\"$symbol\": \(quote(s))}"
    case .javascriptWithScope(let code, let scope):
      out += shell ? "Code(\(quote(code)), " : "{\"$code\": \(quote(code)), \"$scope\": "
      writeDocument(scope, into: &out, level: level)
      out += shell ? ")" : "}"
    case .int32(let i): out += String(i)
    case .timestamp(let t, let i):
      out += shell ? "Timestamp({ t: \(t), i: \(i) })" : "{\"$timestamp\": {\"t\": \(t), \"i\": \(i)}}"
    case .int64(let i): out += shell ? "NumberLong(\(i))" : "{\"$numberLong\": \"\(i)\"}"
    case .decimal128(let d): out += shell ? "NumberDecimal(\"\(d)\")" : "{\"$numberDecimal\": \"\(d)\"}"
    case .minKey: out += shell ? "MinKey()" : "{\"$minKey\": 1}"
    case .maxKey: out += shell ? "MaxKey()" : "{\"$maxKey\": 1}"
    }
  }

  func writeDocument(_ doc: BSONDocument, into out: inout String, level: Int) {
    if doc.isEmpty {
      out += "{}"
      return
    }
    out += "{"
    for (i, element) in doc.enumerated() {
      out += i == 0 ? "" : ","
      if indent == nil { out += " " } else { newline(&out, level + 1) }
      out += key(element.key) + ": "
      write(element.value, into: &out, level: level + 1)
    }
    if indent == nil { out += " }" } else {
      newline(&out, level)
      out += "}"
    }
  }

  func newline(_ out: inout String, _ level: Int) {
    guard let indent else { return }
    out += "\n" + String(repeating: " ", count: indent * level)
  }
}

// MARK: - Parsing

/// Parses mongosh-flavoured JSON: unquoted keys, single quotes, comments, trailing commas,
/// `ObjectId(…)`, `ISODate(…)`, `NumberLong(…)`, `/regex/`, and Extended JSON `$oid`-style wrappers.
public struct BSONParser {
  let scalars: [Unicode.Scalar]
  var i = 0

  init(_ text: String) { scalars = Array(text.unicodeScalars) }

  public static func parse(_ text: String) throws -> BSON {
    var parser = BSONParser(text)
    parser.skipSpace()
    let value = try parser.parseValue()
    parser.skipSpace()
    if parser.i < parser.scalars.count, parser.scalars[parser.i] == ";" { parser.i += 1 }
    parser.skipSpace()
    guard parser.i >= parser.scalars.count else { throw parser.error("Unexpected text after the value") }
    return value
  }

  /// Parses a comma-separated list of values, e.g. a pipeline's stages without the brackets.
  public static func parseList(_ text: String) throws -> [BSON] {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.isEmpty { return [] }
    if trimmed.hasPrefix("[") {
      guard case .array(let items) = try parse(trimmed) else { return [] }
      return items
    }
    guard case .array(let items) = try parse("[" + trimmed + "]") else { return [] }
    return items
  }

  func error(_ message: String) -> BSONError { .parse(message, offset: i) }

  var current: Unicode.Scalar? { i < scalars.count ? scalars[i] : nil }

  mutating func skipSpace() {
    while i < scalars.count {
      let c = scalars[i]
      if c == " " || c == "\n" || c == "\t" || c == "\r" || c == "\u{FEFF}" || c == "\u{00A0}" {
        i += 1
      } else if c == "/", i + 1 < scalars.count, scalars[i + 1] == "/" {
        while i < scalars.count, scalars[i] != "\n" { i += 1 }
      } else if c == "/", i + 1 < scalars.count, scalars[i + 1] == "*" {
        i += 2
        while i + 1 < scalars.count, !(scalars[i] == "*" && scalars[i + 1] == "/") { i += 1 }
        i += 2
      } else {
        return
      }
    }
  }

  mutating func expect(_ c: Unicode.Scalar) throws {
    skipSpace()
    guard current == c else { throw error("Expected \"\(c)\"") }
    i += 1
  }

  mutating func parseValue() throws -> BSON {
    skipSpace()
    guard let c = current else { throw error("Expected a value") }
    switch c {
    case "{": return try parseObject()
    case "[": return try parseArray()
    case "\"", "'": return .string(try parseString())
    case "/": return try parseRegex()
    case "-", "+", "0"..."9", ".":
      if c == "-", matches("-Infinity") {
        i += 9
        return .double(-.infinity)
      }
      return try parseNumber()
    default:
      if c.properties.isAlphabetic || c == "_" || c == "$" { return try parseWord() }
      throw error("Unexpected \"\(c)\"")
    }
  }

  func matches(_ word: String) -> Bool {
    let w = Array(word.unicodeScalars)
    guard i + w.count <= scalars.count else { return false }
    return Array(scalars[i..<i + w.count]) == w
  }

  mutating func parseObject() throws -> BSON {
    i += 1
    var doc = BSONDocument()
    while true {
      skipSpace()
      if current == "}" {
        i += 1
        break
      }
      let key = try parseKey()
      try expect(":")
      doc.append(key, try parseValue())
      skipSpace()
      if current == "," {
        i += 1
        continue
      }
      if current == "}" {
        i += 1
        break
      }
      throw error("Expected \",\" or \"}\"")
    }
    return Self.unwrapExtendedJSON(doc)
  }

  mutating func parseKey() throws -> String {
    skipSpace()
    guard let c = current else { throw error("Expected a field name") }
    if c == "\"" || c == "'" { return try parseString() }
    var key = ""
    while let c = current, c.properties.isAlphabetic || c.properties.numericType != nil || c == "_" || c == "$" || c == "."
      || c == "-"
    {
      key.unicodeScalars.append(c)
      i += 1
    }
    guard !key.isEmpty else { throw error("Expected a field name") }
    return key
  }

  mutating func parseArray() throws -> BSON {
    i += 1
    var items: [BSON] = []
    while true {
      skipSpace()
      if current == "]" {
        i += 1
        break
      }
      items.append(try parseValue())
      skipSpace()
      if current == "," {
        i += 1
        continue
      }
      if current == "]" {
        i += 1
        break
      }
      throw error("Expected \",\" or \"]\"")
    }
    return .array(items)
  }

  mutating func parseString() throws -> String {
    let quote = scalars[i]
    i += 1
    var out = String.UnicodeScalarView()
    while let c = current {
      i += 1
      if c == quote { return String(out) }
      if c == "\\" {
        guard let e = current else { break }
        i += 1
        switch e {
        case "n": out.append("\n")
        case "t": out.append("\t")
        case "r": out.append("\r")
        case "b": out.append("\u{08}")
        case "f": out.append("\u{0C}")
        case "0": out.append("\0")
        case "u":
          guard i + 4 <= scalars.count, let code = UInt32(String(String.UnicodeScalarView(scalars[i..<i + 4])), radix: 16)
          else { throw error("Bad \\u escape") }
          i += 4
          // Surrogate pairs.
          if (0xD800...0xDBFF).contains(code), matches("\\u"),
            let low = UInt32(String(String.UnicodeScalarView(scalars[(i + 2)..<min(i + 6, scalars.count)])), radix: 16),
            (0xDC00...0xDFFF).contains(low)
          {
            i += 6
            out.append(Unicode.Scalar(0x10000 + ((code - 0xD800) << 10) + (low - 0xDC00))!)
          } else if let scalar = Unicode.Scalar(code) {
            out.append(scalar)
          }
        default: out.append(e)
        }
      } else {
        out.append(c)
      }
    }
    throw error("Unterminated string")
  }

  mutating func parseRegex() throws -> BSON {
    i += 1
    var pattern = String.UnicodeScalarView()
    var inClass = false
    while let c = current {
      i += 1
      if c == "\\", let next = current {
        if next != "/" { pattern.append(c) }
        pattern.append(next)
        i += 1
        continue
      }
      if c == "[" { inClass = true }
      if c == "]" { inClass = false }
      if c == "/" && !inClass {
        var options = ""
        while let o = current, "imxsu".unicodeScalars.contains(o) {
          options.unicodeScalars.append(o)
          i += 1
        }
        return .regex(pattern: String(pattern), options: options)
      }
      pattern.append(c)
    }
    throw error("Unterminated regular expression")
  }

  mutating func parseNumber() throws -> BSON {
    let start = i
    if current == "-" || current == "+" { i += 1 }
    if matches("0x") || matches("0X") {
      i += 2
      let digitsStart = i
      while let c = current, c.properties.isASCIIHexDigit { i += 1 }
      guard let value = Int64(String(String.UnicodeScalarView(scalars[digitsStart..<i])), radix: 16) else {
        throw error("Bad hexadecimal number")
      }
      let negative = scalars[start] == "-"
      return Self.integer(negative ? -value : value)
    }
    var isFloat = false
    while let c = current {
      if c.properties.numericType != nil && c.isASCII {
        i += 1
      } else if c == "." || c == "e" || c == "E" {
        isFloat = true
        i += 1
        if (c == "e" || c == "E"), current == "-" || current == "+" { i += 1 }
      } else {
        break
      }
    }
    let text = String(String.UnicodeScalarView(scalars[start..<i]))
    if !isFloat, let value = Int64(text) { return Self.integer(value) }
    guard let d = Double(text) else { throw error("Bad number \"\(text)\"") }
    return .double(d)
  }

  static func integer(_ value: Int64) -> BSON {
    if let small = Int32(exactly: value) { return .int32(small) }
    return .int64(value)
  }

  mutating func parseWord() throws -> BSON {
    var word = ""
    while let c = current, c.properties.isAlphabetic || c.properties.numericType != nil || c == "_" || c == "$" {
      word.unicodeScalars.append(c)
      i += 1
    }
    switch word {
    case "true": return .bool(true)
    case "false": return .bool(false)
    case "null": return .null
    case "undefined": return .undefined
    case "Infinity": return .double(.infinity)
    case "NaN": return .double(.nan)
    case "new":
      skipSpace()
      return try parseWord()
    default: break
    }
    skipSpace()
    guard current == "(" else { throw error("Unknown word \"\(word)\"") }
    i += 1
    var args: [BSON] = []
    skipSpace()
    while current != ")" {
      args.append(try parseValue())
      skipSpace()
      if current == "," {
        i += 1
        skipSpace()
      } else if current != ")" {
        throw error("Expected \",\" or \")\"")
      }
    }
    i += 1
    return try Self.call(word, args, at: i, parser: self)
  }

  static func call(_ name: String, _ args: [BSON], at offset: Int, parser: BSONParser) throws -> BSON {
    func fail(_ message: String) -> BSONError { .parse(message, offset: offset) }
    let first = args.first
    switch name {
    case "ObjectId", "ObjectID":
      guard let first else { return .objectId(.generate()) }
      guard case .string(let hex) = first, let id = ObjectID(hex) else { throw fail("ObjectId needs 24 hex characters") }
      return .objectId(id)
    case "ISODate", "Date":
      switch first {
      case nil: return .date(Date())
      case .string(let s)?:
        guard let ms = parseISODate(s) else { throw fail("Couldn't read the date \"\(s)\"") }
        return .datetime(ms)
      case let number?:
        guard let ms = number.doubleValue else { throw fail("Date needs a string or milliseconds") }
        return .datetime(Int64(ms))
      }
    case "NumberLong", "Long", "Int64":
      switch first {
      case .string(let s)?: guard let v = Int64(s) else { throw fail("Bad NumberLong") }; return .int64(v)
      case let n?: guard let v = n.doubleValue else { throw fail("Bad NumberLong") }; return .int64(Int64(v))
      case nil: return .int64(0)
      }
    case "NumberInt", "Int32":
      switch first {
      case .string(let s)?: guard let v = Int32(s) else { throw fail("Bad NumberInt") }; return .int32(v)
      case let n?: guard let v = n.doubleValue else { throw fail("Bad NumberInt") }; return .int32(Int32(v))
      case nil: return .int32(0)
      }
    case "Double":
      guard let v = first?.doubleValue ?? first?.stringValue.flatMap(Double.init) else { throw fail("Bad Double") }
      return .double(v)
    case "NumberDecimal", "Decimal128":
      let text = first?.stringValue ?? first.map { $0.text() } ?? "0"
      guard let d = Decimal128(text) else { throw fail("Bad decimal \"\(text)\"") }
      return .decimal128(d)
    case "Timestamp":
      if case .document(let doc)? = first {
        return .timestamp(
          time: UInt32(doc["t"]?.intValue ?? 0), increment: UInt32(doc["i"]?.intValue ?? 0))
      }
      return .timestamp(
        time: UInt32(args.first?.intValue ?? 0), increment: UInt32(args.count > 1 ? args[1].intValue ?? 0 : 0))
    case "BinData":
      guard args.count == 2, let subtype = args[0].intValue, let b64 = args[1].stringValue,
        let data = Data(base64Encoded: b64)
      else { throw fail("BinData needs a subtype and base64 text") }
      return .binary(subtype: UInt8(clamping: subtype), data: [UInt8](data))
    case "HexData":
      guard args.count == 2, let subtype = args[0].intValue, let hex = args[1].stringValue else {
        throw fail("HexData needs a subtype and hex text")
      }
      return .binary(subtype: UInt8(clamping: subtype), data: hexBytes(hex))
    case "UUID":
      guard let text = first?.stringValue, let uuid = UUID(uuidString: text) else { throw fail("Bad UUID") }
      return .binary(subtype: 4, data: withUnsafeBytes(of: uuid.uuid) { Array($0) })
    case "MinKey": return .minKey
    case "MaxKey": return .maxKey
    case "RegExp":
      guard let pattern = first?.stringValue else { throw fail("RegExp needs a pattern") }
      return .regex(pattern: pattern, options: args.count > 1 ? args[1].stringValue ?? "" : "")
    case "Code":
      guard let code = first?.stringValue else { throw fail("Code needs a string") }
      if args.count > 1, case .document(let scope) = args[1] { return .javascriptWithScope(code: code, scope: scope) }
      return .javascript(code)
    default:
      throw fail("Unknown function \(name)()")
    }
  }

  static func hexBytes(_ hex: String) -> [UInt8] {
    var out: [UInt8] = []
    var index = hex.startIndex
    while index < hex.endIndex, let next = hex.index(index, offsetBy: 2, limitedBy: hex.endIndex) {
      if let byte = UInt8(hex[index..<next], radix: 16) { out.append(byte) }
      index = next
    }
    return out
  }

  /// ISO 8601 dates with or without time, fraction and zone (no zone = UTC).
  public static func parseISODate(_ text: String) -> Int64? {
    let s = text.trimmingCharacters(in: .whitespaces)
    let withFraction = ISO8601DateFormatter()
    withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    let plain = ISO8601DateFormatter()
    plain.formatOptions = [.withInternetDateTime]
    for candidate in [s, s + "Z", s.replacingOccurrences(of: " ", with: "T"), s.replacingOccurrences(of: " ", with: "T") + "Z"] {
      if let d = withFraction.date(from: candidate) ?? plain.date(from: candidate) {
        return Int64((d.timeIntervalSince1970 * 1000).rounded())
      }
    }
    let dateOnly = ISO8601DateFormatter()
    dateOnly.formatOptions = [.withFullDate]
    if let d = dateOnly.date(from: s) { return Int64(d.timeIntervalSince1970 * 1000) }
    return nil
  }

  /// `{"$oid": "…"}` and friends become their BSON values.
  static func unwrapExtendedJSON(_ doc: BSONDocument) -> BSON {
    guard let first = doc.elements.first, first.key.hasPrefix("$") else { return .document(doc) }
    let value = first.value
    switch (doc.count, first.key) {
    case (1, "$oid"):
      if let s = value.stringValue, let id = ObjectID(s) { return .objectId(id) }
    case (1, "$date"):
      if let s = value.stringValue, let ms = parseISODate(s) { return .datetime(ms) }
      if case .document(let inner) = value, let s = inner["$numberLong"]?.stringValue, let ms = Int64(s) {
        return .datetime(ms)
      }
      if let ms = value.doubleValue { return .datetime(Int64(ms)) }
    case (1, "$numberLong"):
      if let s = value.stringValue, let v = Int64(s) { return .int64(v) }
    case (1, "$numberInt"):
      if let s = value.stringValue, let v = Int32(s) { return .int32(v) }
    case (1, "$numberDouble"):
      if let s = value.stringValue {
        switch s {
        case "Infinity": return .double(.infinity)
        case "-Infinity": return .double(-.infinity)
        case "NaN": return .double(.nan)
        default: if let d = Double(s) { return .double(d) }
        }
      }
    case (1, "$numberDecimal"):
      if let s = value.stringValue, let d = Decimal128(s) { return .decimal128(d) }
    case (1, "$binary"):
      if case .document(let inner) = value, let b64 = inner["base64"]?.stringValue, let data = Data(base64Encoded: b64)
      {
        let subtype = UInt8(inner["subType"]?.stringValue ?? "0", radix: 16) ?? 0
        return .binary(subtype: subtype, data: [UInt8](data))
      }
    case (1, "$uuid"):
      if let s = value.stringValue, let uuid = UUID(uuidString: s) {
        return .binary(subtype: 4, data: withUnsafeBytes(of: uuid.uuid) { Array($0) })
      }
    case (1, "$regularExpression"):
      if case .document(let inner) = value, let pattern = inner["pattern"]?.stringValue {
        return .regex(pattern: pattern, options: inner["options"]?.stringValue ?? "")
      }
    case (1, "$timestamp"):
      if case .document(let inner) = value {
        return .timestamp(time: UInt32(inner["t"]?.intValue ?? 0), increment: UInt32(inner["i"]?.intValue ?? 0))
      }
    case (1, "$minKey"): return .minKey
    case (1, "$maxKey"): return .maxKey
    case (1, "$undefined"): return .undefined
    case (1, "$symbol"):
      if let s = value.stringValue { return .symbol(s) }
    case (1, "$code"):
      if let s = value.stringValue { return .javascript(s) }
    default: break
    }
    return .document(doc)
  }
}
