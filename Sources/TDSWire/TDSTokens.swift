import Foundation
import WireKit

/// What a server reply contained.
struct TokenOutcome {
  var results: [DBResult] = []
  var errors: [DBServerError] = []
  var messages: [String] = []
  var envChanges: [(UInt8, [UInt8])] = []
  var loggedIn = false
  var serverName = ""
  var serverVersion = ""
}

/// One column's type information from COLMETADATA.
struct TDSColumn {
  var name: String
  var type: UInt8
  var maxLength: Int = 0
  var precision: UInt8 = 0
  var scale: UInt8 = 0
  var collation: [UInt8] = []
  var isPLP = false
  var udtName: String?

  var typeName: String {
    switch type {
    case 0x30: "tinyint"
    case 0x32, 0x68: "bit"
    case 0x34: "smallint"
    case 0x38: "int"
    case 0x7F: "bigint"
    case 0x26:
      switch maxLength {
      case 1: "tinyint"
      case 2: "smallint"
      case 4: "int"
      default: "bigint"
      }
    case 0x3B: "real"
    case 0x3E: "float"
    case 0x6D: maxLength == 4 ? "real" : "float"
    case 0x3C, 0x7A, 0x6E: maxLength == 4 ? "smallmoney" : "money"
    case 0x3D, 0x3A, 0x6F: maxLength == 4 ? "smalldatetime" : "datetime"
    case 0x37, 0x6A: "decimal(\(precision),\(scale))"
    case 0x3F, 0x6C: "numeric(\(precision),\(scale))"
    case 0x24: "uniqueidentifier"
    case 0x28: "date"
    case 0x29: "time"
    case 0x2A: "datetime2"
    case 0x2B: "datetimeoffset"
    case 0xA7, 0x27: isPLP ? "varchar(max)" : "varchar(\(maxLength))"
    case 0xAF, 0x2F: "char(\(maxLength))"
    case 0xE7: isPLP ? "nvarchar(max)" : "nvarchar(\(maxLength / 2))"
    case 0xEF: "nchar(\(maxLength / 2))"
    case 0xA5, 0x25: isPLP ? "varbinary(max)" : "varbinary(\(maxLength))"
    case 0xAD, 0x2D: "binary(\(maxLength))"
    case 0x23: "text"
    case 0x63: "ntext"
    case 0x22: "image"
    case 0xF1: "xml"
    case 0x62: "sql_variant"
    case 0xF0: udtName ?? "udt"
    default: "type 0x\(String(type, radix: 16))"
    }
  }

  /// Non-Unicode text uses the collation's code page; UTF-8 collations set bit 26.
  var stringEncoding: String.Encoding {
    guard collation.count >= 4 else { return .windowsCP1252 }
    let info = UInt32(collation[0]) | UInt32(collation[1]) << 8 | UInt32(collation[2]) << 16 | UInt32(collation[3]) << 24
    if info & 0x0400_0000 != 0 { return .utf8 }
    switch info & 0xFFFFF {
    case 0x0411: return .shiftJIS
    case 0x0419, 0x0422, 0x0423: return .windowsCP1251
    case 0x0405, 0x0415, 0x040E: return .windowsCP1250
    case 0x0408: return .windowsCP1253
    case 0x041F: return .windowsCP1254
    default: return .windowsCP1252
    }
  }
}

/// Parses the token stream of one server reply.
struct TokenStream {
  var r: ByteReader
  private var columns: [TDSColumn] = []
  private var current: DBResult?

  init(bytes: [UInt8]) { r = ByteReader(bytes) }

  mutating func parse() throws -> TokenOutcome {
    var outcome = TokenOutcome()
    while !r.isAtEnd {
      let token = try r.readByte()
      switch token {
      case 0x81:  // COLMETADATA
        try readColumnMetadata()
      case 0xD1:  // ROW
        try readRow(nullBitmap: false)
      case 0xD2:  // NBCROW
        try readRow(nullBitmap: true)
      case 0xFD, 0xFE, 0xFF:  // DONE, DONEPROC, DONEINPROC
        let status = try r.readLE(UInt16.self)
        _ = try r.readLE(UInt16.self)
        let count = try r.readLE(UInt64.self)
        let hasCount = status & 0x10 != 0
        if var result = current {
          if hasCount && !result.hasRows { result.affectedRows = Int(count) }
          result.messages = outcome.messages
          outcome.messages = []
          outcome.results.append(result)
          current = nil
          columns = []
        } else if hasCount && token == 0xFD {
          outcome.results.append(DBResult(affectedRows: Int(count), messages: outcome.messages))
          outcome.messages = []
        }
      case 0xAA, 0xAB:  // ERROR, INFO
        let length = Int(try r.readLE(UInt16.self))
        var inner = ByteReader(try r.readBytes(length))
        let number = try inner.readLE(Int32.self)
        let state = try inner.readByte()
        let severity = try inner.readByte()
        let message = try Self.usVarchar(&inner)
        _ = try Self.bVarchar(&inner)  // server
        _ = try Self.bVarchar(&inner)  // procedure
        let line = (try? inner.readLE(Int32.self)) ?? 0
        if token == 0xAA && severity > 10 {
          outcome.errors.append(
            DBServerError(
              engine: "SQL Server", code: String(number), message: message,
              detail: line > 0 ? "line \(line), state \(state)" : nil))
        } else {
          outcome.messages.append(message)
        }
      case 0xAD:  // LOGINACK
        let length = Int(try r.readLE(UInt16.self))
        var inner = ByteReader(try r.readBytes(length))
        _ = try inner.readByte()
        _ = try inner.readLE(UInt32.self)
        outcome.serverName = try Self.bVarchar(&inner)
        let v = try inner.readBytes(4)
        outcome.serverVersion = "\(v[0]).\(v[1]).\(Int(v[2]) << 8 | Int(v[3]))"
        outcome.loggedIn = true
      case 0xE3:  // ENVCHANGE
        let length = Int(try r.readLE(UInt16.self))
        var inner = ByteReader(try r.readBytes(length))
        let type = try inner.readByte()
        let newLength: Int
        let isBytes = [7, 8, 9, 10, 11, 12, 15, 16, 17, 18].contains(type)
        if type == 20 {
          outcome.envChanges.append((type, inner.readRest()))
          continue
        }
        newLength = Int(try inner.readByte())
        let value = try inner.readBytes(isBytes ? newLength : newLength * 2)
        outcome.envChanges.append((type, value))
      case 0x79:  // RETURNSTATUS
        _ = try r.readLE(Int32.self)
      case 0xA9, 0xA5, 0xA4, 0xED:  // ORDER, COLINFO, TABNAME, SSPI
        try r.skip(Int(try r.readLE(UInt16.self)))
      case 0xAE:  // FEATUREEXTACK
        while try r.readByte() != 0xFF { try r.skip(Int(try r.readLE(UInt32.self))) }
      case 0xAC:  // RETURNVALUE: only from RPC calls, which aren't used
        throw WireError.unsupported("output parameters")
      default:
        throw WireError.protocolViolation("unknown TDS token 0x\(String(token, radix: 16))")
      }
    }
    if let result = current { outcome.results.append(result) }
    return outcome
  }

  // MARK: Metadata

  private mutating func readColumnMetadata() throws {
    let count = Int(try r.readLE(UInt16.self))
    columns = []
    if count == 0xFFFF { return }
    for _ in 0..<count {
      _ = try r.readLE(UInt32.self)  // user type
      _ = try r.readLE(UInt16.self)  // flags
      let type = try r.readByte()
      var column = TDSColumn(name: "", type: type)
      switch type {
      case 0x1F, 0x30, 0x32, 0x34, 0x38, 0x3A, 0x3B, 0x3C, 0x3D, 0x3E, 0x7A, 0x7F:
        column.maxLength = Self.fixedLength(type)
      case 0x24, 0x26, 0x68, 0x6D, 0x6E, 0x6F, 0x2F, 0x27, 0x2D, 0x25:
        column.maxLength = Int(try r.readByte())
      case 0x37, 0x3F, 0x6A, 0x6C:
        column.maxLength = Int(try r.readByte())
        column.precision = try r.readByte()
        column.scale = try r.readByte()
      case 0x28:
        column.maxLength = 3
      case 0x29, 0x2A, 0x2B:
        column.scale = try r.readByte()
      case 0xA5, 0xAD:
        column.maxLength = Int(try r.readLE(UInt16.self))
        column.isPLP = column.maxLength == 0xFFFF
      case 0xA7, 0xAF, 0xE7, 0xEF:
        column.maxLength = Int(try r.readLE(UInt16.self))
        column.isPLP = column.maxLength == 0xFFFF
        column.collation = try r.readBytes(5)
      case 0x22, 0x23, 0x63:
        column.maxLength = Int(try r.readLE(UInt32.self))
        if type != 0x22 { column.collation = try r.readBytes(5) }
        let parts = Int(try r.readByte())
        for _ in 0..<parts { _ = try Self.usVarchar(&r) }
      case 0xF1:
        column.isPLP = true
        if try r.readByte() == 1 {
          _ = try Self.bVarchar(&r)
          _ = try Self.bVarchar(&r)
          _ = try Self.usVarchar(&r)
        }
      case 0x62:
        column.maxLength = Int(try r.readLE(UInt32.self))
      case 0xF0:
        column.maxLength = Int(try r.readLE(UInt16.self))
        _ = try Self.bVarchar(&r)
        _ = try Self.bVarchar(&r)
        column.udtName = try Self.bVarchar(&r)
        _ = try Self.usVarchar(&r)
        column.isPLP = true
      default:
        throw WireError.unsupported("SQL Server column type 0x\(String(type, radix: 16))")
      }
      column.name = try Self.bVarchar(&r)
      columns.append(column)
    }
    current = DBResult(columns: columns.map { DBColumn(name: $0.name, typeName: $0.typeName) })
  }

  static func fixedLength(_ type: UInt8) -> Int {
    switch type {
    case 0x1F: 0
    case 0x30, 0x32: 1
    case 0x34: 2
    case 0x38, 0x3A, 0x3B, 0x7A: 4
    default: 8
    }
  }

  // MARK: Rows

  private mutating func readRow(nullBitmap: Bool) throws {
    var nulls = [Bool](repeating: false, count: columns.count)
    if nullBitmap {
      let bitmap = try r.readBytes((columns.count + 7) / 8)
      for i in columns.indices { nulls[i] = bitmap[i / 8] & (1 << (i % 8)) != 0 }
    }
    var row: [DBValue] = []
    row.reserveCapacity(columns.count)
    for (i, column) in columns.enumerated() {
      if nulls[i] {
        row.append(.null)
      } else {
        row.append(try readValue(column))
      }
    }
    if current == nil { current = DBResult(columns: columns.map { DBColumn(name: $0.name, typeName: $0.typeName) }) }
    current?.rows.append(row)
  }

  private mutating func readValue(_ c: TDSColumn) throws -> DBValue {
    switch c.type {
    case 0x1F: return .null
    case 0x30, 0x32, 0x34, 0x38, 0x3A, 0x3B, 0x3C, 0x3D, 0x3E, 0x7A, 0x7F:
      return try TDSValues.decodeFixed(type: c.type, bytes: try r.readBytes(Self.fixedLength(c.type)))
    case 0x26, 0x68, 0x6D, 0x6E, 0x6F, 0x24, 0x37, 0x3F, 0x6A, 0x6C, 0x28, 0x29, 0x2A, 0x2B, 0x2F, 0x27, 0x2D, 0x25:
      let length = Int(try r.readByte())
      if length == 0 && c.type != 0x2F && c.type != 0x27 && c.type != 0x2D && c.type != 0x25 { return .null }
      let bytes = try r.readBytes(length)
      return try TDSValues.decodeVariable(column: c, bytes: bytes)
    case 0xA5, 0xAD, 0xA7, 0xAF, 0xE7, 0xEF, 0xF1, 0xF0:
      let bytes: [UInt8]?
      if c.isPLP {
        bytes = try readPLP()
      } else {
        let length = Int(try r.readLE(UInt16.self))
        bytes = length == 0xFFFF ? nil : try r.readBytes(length)
      }
      guard let bytes else { return .null }
      return TDSValues.decodeBytes(column: c, bytes: bytes)
    case 0x22, 0x23, 0x63:
      let pointerLength = Int(try r.readByte())
      if pointerLength == 0 { return .null }
      try r.skip(pointerLength + 8)
      let length = Int(try r.readLE(UInt32.self))
      return TDSValues.decodeBytes(column: c, bytes: try r.readBytes(length))
    case 0x62:
      let length = Int(try r.readLE(UInt32.self))
      if length == 0 { return .null }
      return try TDSValues.decodeVariant(try r.readBytes(length))
    default:
      throw WireError.unsupported("SQL Server value type 0x\(String(c.type, radix: 16))")
    }
  }

  private mutating func readPLP() throws -> [UInt8]? {
    let total = try r.readLE(UInt64.self)
    if total == 0xFFFF_FFFF_FFFF_FFFF { return nil }
    var out: [UInt8] = []
    if total != 0xFFFF_FFFF_FFFF_FFFE { out.reserveCapacity(Int(min(total, 1 << 24))) }
    while true {
      let chunk = Int(try r.readLE(UInt32.self))
      if chunk == 0 { break }
      out += try r.readBytes(chunk)
    }
    return out
  }

  // MARK: Strings

  static func bVarchar(_ r: inout ByteReader) throws -> String {
    let length = Int(try r.readByte())
    return String(decoding: try r.readBytes(length * 2), as: UTF16.self, littleEndian: true)
  }

  static func usVarchar(_ r: inout ByteReader) throws -> String {
    let length = Int(try r.readLE(UInt16.self))
    return String(decoding: try r.readBytes(length * 2), as: UTF16.self, littleEndian: true)
  }
}

/// Value decoding for the TDS type system.
enum TDSValues {
  static func int(_ bytes: [UInt8]) -> Int64 {
    var r = ByteReader(bytes)
    switch bytes.count {
    case 1: return Int64(bytes[0])
    case 2: return Int64((try? r.readLE(Int16.self)) ?? 0)
    case 4: return Int64((try? r.readLE(Int32.self)) ?? 0)
    default: return (try? r.readLE(Int64.self)) ?? 0
    }
  }

  static func decodeFixed(type: UInt8, bytes: [UInt8]) throws -> DBValue {
    var r = ByteReader(bytes)
    switch type {
    case 0x30, 0x34, 0x38, 0x7F: return .int(int(bytes))
    case 0x32: return .bool(bytes[0] != 0)
    case 0x3B: return .double(Double(try r.readFloatLE()))
    case 0x3E: return .double(try r.readDoubleLE())
    case 0x3C, 0x7A: return .decimal(money(bytes))
    case 0x3D, 0x3A: return .text(datetime(bytes))
    default: throw WireError.unsupported("fixed type 0x\(String(type, radix: 16))")
    }
  }

  static func decodeVariable(column c: TDSColumn, bytes: [UInt8]) throws -> DBValue {
    var r = ByteReader(bytes)
    switch c.type {
    case 0x26: return .int(int(bytes))
    case 0x68: return .bool(bytes.first != 0)
    case 0x6D: return bytes.count == 4 ? .double(Double(try r.readFloatLE())) : .double(try r.readDoubleLE())
    case 0x6E: return .decimal(money(bytes))
    case 0x6F: return .text(datetime(bytes))
    case 0x24: return .uuid(guid(bytes))
    case 0x37, 0x3F, 0x6A, 0x6C: return .decimal(decimal(bytes, scale: Int(c.scale)))
    case 0x28: return .text(date(bytes))
    case 0x29: return .text(time(bytes, scale: Int(c.scale)))
    case 0x2A:
      let timeLength = bytes.count - 3
      return .text(date(Array(bytes[timeLength...])) + " " + time(Array(bytes[..<timeLength]), scale: Int(c.scale)))
    case 0x2B:
      let timeLength = bytes.count - 5
      let offsetBytes = Array(bytes[(bytes.count - 2)...])
      let offset = Int(Int16(bitPattern: UInt16(offsetBytes[0]) | UInt16(offsetBytes[1]) << 8))
      // Stored in UTC; show local wall time with the offset, like SQL Server does.
      let utcDate = Array(bytes[timeLength..<(timeLength + 3)])
      let utcTime = Array(bytes[..<timeLength])
      return .text(datetimeOffset(dateBytes: utcDate, timeBytes: utcTime, scale: Int(c.scale), offsetMinutes: offset))
    case 0x2F, 0x27: return .text(String(data: Data(bytes), encoding: c.stringEncoding) ?? "")
    case 0x2D, 0x25: return .bytes(bytes)
    default: throw WireError.unsupported("type 0x\(String(c.type, radix: 16))")
    }
  }

  static func decodeBytes(column c: TDSColumn, bytes: [UInt8]) -> DBValue {
    switch c.type {
    case 0xE7, 0xEF, 0x63, 0xF1:
      let text = String(decoding: bytes, as: UTF16.self, littleEndian: true)
      return .text(text)
    case 0xA7, 0xAF, 0x23:
      return .text(String(data: Data(bytes), encoding: c.stringEncoding) ?? String(decoding: bytes, as: UTF8.self))
    default:
      return .bytes(bytes)
    }
  }

  static func decodeVariant(_ bytes: [UInt8]) throws -> DBValue {
    var r = ByteReader(bytes)
    let base = try r.readByte()
    let propLength = Int(try r.readByte())
    let props = try r.readBytes(propLength)
    let data = r.readRest()
    var column = TDSColumn(name: "", type: base)
    switch base {
    case 0x37, 0x3F, 0x6A, 0x6C:
      column.precision = props.first ?? 0
      column.scale = props.count > 1 ? props[1] : 0
    case 0x29, 0x2A, 0x2B:
      column.scale = props.first ?? 7
    case 0xA7, 0xAF, 0xE7, 0xEF:
      column.collation = Array(props.prefix(5))
      return decodeBytes(column: column, bytes: data)
    case 0xA5, 0xAD:
      return .bytes(data)
    default: break
    }
    if [0x30, 0x32, 0x34, 0x38, 0x3A, 0x3B, 0x3C, 0x3D, 0x3E, 0x7A, 0x7F].contains(base) {
      return try decodeFixed(type: base, bytes: data)
    }
    return try decodeVariable(column: column, bytes: data)
  }

  static func money(_ bytes: [UInt8]) -> String {
    var r = ByteReader(bytes)
    let units: Int64
    if bytes.count == 4 {
      units = Int64((try? r.readLE(Int32.self)) ?? 0)
    } else {
      let high = Int64((try? r.readLE(Int32.self)) ?? 0)
      let low = Int64((try? r.readLE(UInt32.self)) ?? 0)
      units = high << 32 | low
    }
    let negative = units < 0
    let magnitude = units.magnitude
    let text = "\(magnitude / 10000).\(String(format: "%04d", magnitude % 10000))"
    return negative ? "-" + text : text
  }

  static let calendar: Calendar = {
    var c = Calendar(identifier: .gregorian)
    c.timeZone = TimeZone(identifier: "UTC")!
    return c
  }()

  static func ymd(daysSince1900 days: Int) -> String {
    let base = calendar.date(from: DateComponents(year: 1900, month: 1, day: 1))!
    let d = calendar.date(byAdding: .day, value: days, to: base)!
    let c = calendar.dateComponents([.year, .month, .day], from: d)
    return String(format: "%04d-%02d-%02d", c.year!, c.month!, c.day!)
  }

  static func datetime(_ bytes: [UInt8]) -> String {
    var r = ByteReader(bytes)
    if bytes.count == 4 {
      let days = Int((try? r.readLE(UInt16.self)) ?? 0)
      let minutes = Int((try? r.readLE(UInt16.self)) ?? 0)
      return ymd(daysSince1900: days) + String(format: " %02d:%02d:00", minutes / 60, minutes % 60)
    }
    let days = Int((try? r.readLE(Int32.self)) ?? 0)
    let ticks = Int((try? r.readLE(UInt32.self)) ?? 0)  // 1/300 s
    let ms = Int((Double(ticks) * 10 / 3).rounded())
    let seconds = ms / 1000
    return ymd(daysSince1900: days)
      + String(format: " %02d:%02d:%02d.%03d", seconds / 3600, seconds / 60 % 60, seconds % 60, ms % 1000)
  }

  static func dayNumber(_ bytes: [UInt8]) -> Int {
    Int(bytes[0]) | Int(bytes[1]) << 8 | Int(bytes[2]) << 16
  }

  /// DATE: days since 0001-01-01.
  static func date(_ bytes: [UInt8]) -> String {
    let (y, m, d) = civilFromDays(dayNumber(bytes) - 719_162)  // shift to 1970-01-01
    return String(format: "%04d-%02d-%02d", y, m, d)
  }

  /// Howard Hinnant's days-from-civil inverse; days relative to 1970-01-01.
  static func civilFromDays(_ z0: Int) -> (Int, Int, Int) {
    let z = z0 + 719_468
    let era = (z >= 0 ? z : z - 146_096) / 146_097
    let doe = z - era * 146_097
    let yoe = (doe - doe / 1460 + doe / 36524 - doe / 146_096) / 365
    let y = yoe + era * 400
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100)
    let mp = (5 * doy + 2) / 153
    let d = doy - (153 * mp + 2) / 5 + 1
    let m = mp < 10 ? mp + 3 : mp - 9
    return (m <= 2 ? y + 1 : y, m, d)
  }

  static func timeUnits(_ bytes: [UInt8]) -> UInt64 {
    var value: UInt64 = 0
    for (i, b) in bytes.enumerated() { value |= UInt64(b) << (8 * UInt64(i)) }
    return value
  }

  static func time(_ bytes: [UInt8], scale: Int) -> String {
    let units = timeUnits(bytes)
    var divisor: UInt64 = 1
    for _ in 0..<scale { divisor *= 10 }
    let seconds = units / divisor
    let fraction = units % divisor
    var text = String(format: "%02d:%02d:%02d", seconds / 3600, seconds / 60 % 60, seconds % 60)
    text += fractionText(fraction, scale: scale)
    return text
  }

  /// ".25" for a quarter second; nothing for whole seconds.
  static func fractionText(_ fraction: UInt64, scale: Int) -> String {
    guard scale > 0, fraction > 0 else { return "" }
    var digits = String(format: "%0\(scale)llu", fraction)
    while digits.hasSuffix("0") { digits.removeLast() }
    return "." + digits
  }

  static func datetimeOffset(dateBytes: [UInt8], timeBytes: [UInt8], scale: Int, offsetMinutes: Int) -> String {
    var divisor: UInt64 = 1
    for _ in 0..<scale { divisor *= 10 }
    let units = timeUnits(timeBytes)
    var seconds = Int(units / divisor) + offsetMinutes * 60
    var days = dayNumber(dateBytes) - 719_162
    while seconds < 0 {
      seconds += 86400
      days -= 1
    }
    while seconds >= 86400 {
      seconds -= 86400
      days += 1
    }
    let (y, m, d) = civilFromDays(days)
    var text = String(format: "%04d-%02d-%02d %02d:%02d:%02d", y, m, d, seconds / 3600, seconds / 60 % 60, seconds % 60)
    text += fractionText(units % divisor, scale: scale)
    let sign = offsetMinutes < 0 ? "-" : "+"
    text += String(format: " %@%02d:%02d", sign, abs(offsetMinutes) / 60, abs(offsetMinutes) % 60)
    return text
  }

  static func guid(_ b: [UInt8]) -> UUID {
    guard b.count == 16 else { return UUID() }
    let ordered: [UInt8] = [b[3], b[2], b[1], b[0], b[5], b[4], b[7], b[6]] + Array(b[8..<16])
    return UUID(
      uuid: (
        ordered[0], ordered[1], ordered[2], ordered[3], ordered[4], ordered[5], ordered[6], ordered[7],
        ordered[8], ordered[9], ordered[10], ordered[11], ordered[12], ordered[13], ordered[14], ordered[15]
      ))
  }

  /// Sign byte, then a little-endian unsigned integer of up to 16 bytes, scaled.
  static func decimal(_ bytes: [UInt8], scale: Int) -> String {
    guard let sign = bytes.first else { return "0" }
    var magnitude = Array(bytes.dropFirst().reversed())  // big-endian
    var digits: [UInt8] = []
    while magnitude.contains(where: { $0 != 0 }) {
      var remainder = 0
      for i in magnitude.indices {
        let value = remainder << 8 | Int(magnitude[i])
        magnitude[i] = UInt8(value / 10)
        remainder = value % 10
      }
      digits.append(UInt8(remainder))
    }
    while digits.count <= scale { digits.append(0) }
    var text = String(digits.reversed().map { Character(String($0)) })
    if scale > 0 { text.insert(".", at: text.index(text.endIndex, offsetBy: -scale)) }
    return sign == 0 ? "-" + text : text
  }
}
