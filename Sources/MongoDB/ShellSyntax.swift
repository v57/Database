import Foundation

/// mongosh / JavaScript spelling of BSON values — the inverse of the shell
/// syntax `QueryParser` accepts. Used to write aggregation stages into the
/// builder's text fields and to export pipelines as `.js`, so every value
/// survives a render → parse round trip (`ObjectId("…")` stays an ObjectId
/// instead of becoming a `{ "$oid": … }` document).
public enum ShellSyntax {
  /// Lines longer than this break containers onto one entry per line.
  static let lineWidth = 72

  /// JavaScript literal for `value`. Short containers stay on one line
  /// (`{ $sum: 1 }`); longer ones are indented by two spaces per level.
  /// `indent` is the column the value's first line already starts at.
  public static func render(_ value: BSON, indent: Int = 0) -> String {
    render(value, indent: indent, column: indent)
  }

  private static func render(_ value: BSON, indent: Int, column: Int) -> String {
    let inline = self.inline(value)
    guard column + inline.count > lineWidth else { return inline }
    let pad = String(repeating: " ", count: indent + 2)
    switch value {
    case .document(let document) where !document.isEmpty:
      let entries = document.all.map { entry -> String in
        let key = self.key(entry.key)
        return pad + key + ": "
          + render(entry.value, indent: indent + 2, column: indent + 2 + key.count + 2)
      }
      return "{\n" + entries.joined(separator: ",\n") + "\n" + String(repeating: " ", count: indent) + "}"
    case .array(let items) where !items.isEmpty:
      let entries = items.map { pad + render($0, indent: indent + 2, column: indent + 2) }
      return "[\n" + entries.joined(separator: ",\n") + "\n" + String(repeating: " ", count: indent) + "]"
    default:
      return inline
    }
  }

  /// Single-line rendering.
  static func inline(_ value: BSON) -> String {
    switch value {
    case .document(let document):
      guard !document.isEmpty else { return "{}" }
      return "{ " + document.all.map { key($0.key) + ": " + inline($0.value) }
        .joined(separator: ", ") + " }"
    case .array(let items):
      return "[" + items.map(inline).joined(separator: ", ") + "]"
    case .string(let text): return "\"" + text.escapedJSON + "\""
    case .symbol(let symbol): return "\"" + symbol.stringValue.escapedJSON + "\""
    case .int32(let number): return String(number)
    case .int64(let number):
      // Past 2^53 a JavaScript number loses digits; the shell's Long keeps them.
      return number.magnitude <= 1 << 53 ? String(number) : "NumberLong(\"\(number)\")"
    case .double(let number):
      if number.isNaN { return "NaN" }
      if number.isInfinite { return number < 0 ? "-Infinity" : "Infinity" }
      return String(number)
    case .decimal128(let decimal): return "NumberDecimal(\"\(decimal.description)\")"
    case .bool(let flag): return flag ? "true" : "false"
    case .null: return "null"
    case .undefined: return "undefined"
    case .minKey: return "MinKey()"
    case .maxKey: return "MaxKey()"
    case .objectID(let id): return "ObjectId(\"\(id.hex)\")"
    case .datetime(let date): return "ISODate(\"\(dateString(date))\")"
    case .regex(let regex): return regexLiteral(regex)
    case .binary(let binary):
      if binary.subtype == .uuid, binary.data.count == 16 {
        return "UUID(\"\(UUID(uuid: uuidBytes(binary.data)).uuidString.lowercased())\")"
      }
      return "BinData(\(binary.subtype.rawValue), \"\(binary.data.base64EncodedString())\")"
    }
  }

  /// Keys that are JavaScript identifiers (`name`, `$match`, `_id`) stay
  /// bare; anything else (`address.city`, `first name`, `0`) is quoted.
  static func key(_ key: String) -> String {
    guard let first = key.first, first.isLetter || first == "_" || first == "$",
      key.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" || $0 == "$" })
    else { return "\"" + key.escapedJSON + "\"" }
    return key
  }

  /// `/pattern/flags`, with the delimiter escaped. A pattern with a line
  /// break can't be a literal, so it falls back to `RegExp("…", "…")`.
  private static func regexLiteral(_ regex: BSONRegularExpression) -> String {
    if regex.pattern.contains(where: \.isNewline) || regex.pattern.isEmpty {
      return "RegExp(\"\(regex.pattern.escapedJSON)\", \"\(regex.options.escapedJSON)\")"
    }
    var body = ""
    var escaping = false
    for c in regex.pattern {
      if escaping {
        body.append(c)
        escaping = false
      } else if c == "\\" {
        body.append(c)
        escaping = true
      } else if c == "/" {
        body += "\\/"
      } else {
        body.append(c)
      }
    }
    return "/" + body + "/" + regex.options
  }

  private static func uuidBytes(_ data: Data) -> uuid_t {
    let b = Array(data)
    return (b[0], b[1], b[2], b[3], b[4], b[5], b[6], b[7],
      b[8], b[9], b[10], b[11], b[12], b[13], b[14], b[15])
  }

  // MARK: - Dates

  private static func dateString(_ date: Date) -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter.string(from: date)
  }

  /// The date forms `ISODate` / `new Date` accept: full timestamps with or
  /// without fractional seconds and zone (no zone means UTC, as in mongosh),
  /// and bare dates.
  static func date(from text: String) -> Date? {
    let trimmed = text.trimmingCharacters(in: .whitespaces)
    let zoned: [ISO8601DateFormatter.Options] = [
      [.withInternetDateTime, .withFractionalSeconds], [.withInternetDateTime],
    ]
    let unzoned: [ISO8601DateFormatter.Options] = [
      [.withFullDate, .withTime, .withColonSeparatorInTime, .withFractionalSeconds],
      [.withFullDate, .withTime, .withColonSeparatorInTime], [.withFullDate],
    ]
    for options in zoned + unzoned {
      let formatter = ISO8601DateFormatter()
      formatter.formatOptions = options
      formatter.timeZone = TimeZone(identifier: "UTC")
      if let date = formatter.date(from: trimmed) { return date }
    }
    return nil
  }

  // MARK: - Shell type helpers

  /// A helper call the parser couldn't turn into a value.
  struct ConstructorError: Error {
    let message: String
  }

  /// Builds the value of a mongosh helper call such as `ObjectId("…")`.
  static func construct(_ name: String, _ arguments: [BSON]) throws -> BSON {
    func fail(_ message: String) -> ConstructorError { ConstructorError(message: message) }
    func text(_ index: Int) -> String? {
      guard arguments.indices.contains(index) else { return nil }
      switch arguments[index] {
      case .string(let s): return s
      case .int32(let n): return String(n)
      case .int64(let n): return String(n)
      case .double(let d): return String(d)
      default: return nil
      }
    }
    func number(_ index: Int) -> Double? {
      guard arguments.indices.contains(index) else { return nil }
      switch arguments[index] {
      case .int32(let n): return Double(n)
      case .int64(let n): return Double(n)
      case .double(let d): return d
      case .string(let s): return Double(s)
      default: return nil
      }
    }

    switch name {
    case "ObjectId", "ObjectID":
      guard !arguments.isEmpty else { return .objectID(BSONObjectID()) }
      guard case .string(let hex) = arguments[0], let id = try? BSONObjectID(hex) else {
        throw fail("\(name) needs a 24-character hex string")
      }
      return .objectID(id)
    case "ISODate", "Date":
      guard !arguments.isEmpty else { return .datetime(Date()) }
      if case .string(let s) = arguments[0] {
        guard let date = date(from: s) else { throw fail("\(name) can't read the date \"\(s)\"") }
        return .datetime(date)
      }
      guard let millis = number(0) else { throw fail("\(name) needs a date string or milliseconds") }
      return .datetime(Date(timeIntervalSince1970: millis / 1000))
    case "NumberInt", "Int32":
      guard let raw = text(0), let value = Int32(raw) ?? Double(raw).flatMap({ Int32(exactly: $0) })
      else { throw fail("\(name) needs a 32-bit integer") }
      return .int32(value)
    case "NumberLong", "Long", "Int64":
      guard let raw = text(0), let value = Int64(raw) ?? Double(raw).flatMap({ Int64(exactly: $0) })
      else { throw fail("\(name) needs a 64-bit integer") }
      return .int64(value)
    case "NumberDecimal", "Decimal128":
      guard let raw = text(0), let value = try? Decimal128(string: raw) else {
        throw fail("\(name) needs a decimal number string")
      }
      return .decimal128(value)
    case "Double":
      guard let value = number(0) else { throw fail("Double needs a number") }
      return .double(value)
    case "RegExp", "BSONRegExp":
      guard case .string(let pattern)? = arguments.first else {
        throw fail("\(name) needs a pattern string")
      }
      return .regex(BSONRegularExpression(pattern: pattern, options: text(1) ?? ""))
    case "UUID":
      guard !arguments.isEmpty else { return .binary(BSONBinary(data: uuidData(UUID()), subtype: .uuid)) }
      guard case .string(let raw) = arguments[0], let uuid = uuid(from: raw) else {
        throw fail("UUID needs a 32-hex-digit string")
      }
      return .binary(BSONBinary(data: uuidData(uuid), subtype: .uuid))
    case "BinData":
      guard let subtype = number(0), let byte = UInt8(exactly: subtype),
        case .string(let base64)? = arguments.dropFirst().first, let data = Data(base64Encoded: base64)
      else { throw fail("BinData needs a subtype and a base64 string") }
      return .binary(BSONBinary(data: data, subtype: BinarySubtype(byte)))
    case "MinKey": return .minKey
    case "MaxKey": return .maxKey
    case "Timestamp":
      throw fail("Timestamp values aren't supported")
    default:
      throw fail("unknown function \(name)()")
    }
  }

  private static func uuid(from text: String) -> UUID? {
    let hex = text.filter { $0 != "-" }
    guard hex.count == 32 else { return nil }
    var dashed = hex
    for offset in [8, 13, 18, 23] {
      dashed.insert("-", at: dashed.index(dashed.startIndex, offsetBy: offset))
    }
    return UUID(uuidString: dashed)
  }

  private static func uuidData(_ uuid: UUID) -> Data {
    withUnsafeBytes(of: uuid.uuid) { Data($0) }
  }
}

extension BSONObjectID {
  /// A new ObjectId: 4-byte big-endian seconds since 1970, then 8 random
  /// bytes (the spec's 5-byte random value + 3-byte counter, both random here,
  /// which keeps ids unique without process-wide counter state).
  public init() {
    let seconds = UInt32(truncatingIfNeeded: Int(Date().timeIntervalSince1970))
    var bytes = withUnsafeBytes(of: seconds.bigEndian) { Array($0) }
    bytes += (0..<8).map { _ in UInt8.random(in: 0...255) }
    try! self.init(bytes: bytes)
  }
}

extension Decimal128 {
  /// Parses a decimal string (`19.99`, `-1.5E+3`, `NaN`, `Infinity`) into its
  /// IEEE 754-2008 BID encoding — the inverse of `description`.
  public init(string: String) throws {
    var text = string.trimmingCharacters(in: .whitespaces)
    var negative = false
    if let sign = text.first, sign == "-" || sign == "+" {
      negative = sign == "-"
      text.removeFirst()
    }
    var high: UInt64
    var low: UInt64 = 0
    switch text.lowercased() {
    case "nan":
      high = 0x7C00_0000_0000_0000
    case "infinity", "inf":
      high = 0x7800_0000_0000_0000
    default:
      let parts = text.lowercased().split(separator: "e", maxSplits: 1, omittingEmptySubsequences: false)
      var exponent = 0
      if parts.count == 2 {
        guard let e = Int(parts[1]) else { throw BSONError.invalid("invalid decimal \"\(string)\"") }
        exponent = e
      }
      let mantissa = parts[0].split(separator: ".", maxSplits: 1, omittingEmptySubsequences: false)
      let whole = String(mantissa[0])
      let fraction = mantissa.count == 2 ? String(mantissa[1]) : ""
      var digits = whole + fraction
      guard !digits.isEmpty, digits.allSatisfy(\.isASCII), digits.allSatisfy(\.isNumber) else {
        throw BSONError.invalid("invalid decimal \"\(string)\"")
      }
      exponent -= fraction.count
      digits = String(digits.drop { $0 == "0" })
      if digits.isEmpty { digits = "0" }
      // More than 34 significant digits only fits when the excess is zeros.
      while digits.count > 34, digits.last == "0" {
        digits.removeLast()
        exponent += 1
      }
      guard digits.count <= 34 else {
        throw BSONError.invalid("decimal \"\(string)\" has more than 34 significant digits")
      }
      guard (-6176...6111).contains(exponent) else {
        throw BSONError.invalid("decimal \"\(string)\" is out of range")
      }
      var coefficientHigh: UInt64 = 0
      for digit in digits.compactMap(\.wholeNumberValue) {
        let product = low.multipliedFullWidth(by: 10)
        coefficientHigh = coefficientHigh &* 10 &+ product.high
        let (sum, overflow) = product.low.addingReportingOverflow(UInt64(digit))
        low = sum
        if overflow { coefficientHigh &+= 1 }
      }
      high = UInt64(exponent + 6176) << 49 | coefficientHigh
    }
    if negative { high |= 1 << 63 }
    var bytes: [UInt8] = []
    for word in [low, high] {
      for shift in stride(from: 0, to: 64, by: 8) { bytes.append(UInt8((word >> UInt64(shift)) & 0xFF)) }
    }
    try self.init(bytes: bytes)
  }
}
