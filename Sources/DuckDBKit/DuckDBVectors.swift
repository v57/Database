import Cduckdb
import Foundation
import WireKit

/// Reads result values straight from DuckDB's column vectors, including nested types
/// (LIST, STRUCT, MAP, UNION) that the row-at-a-time value API can't render.
enum DuckDBVectors {
  static func read(_ result: inout duckdb_result, maxRows: Int) -> DBResult {
    let columnCount = Int(duckdb_column_count(&result))
    var columns: [DBColumn] = []
    var types: [duckdb_logical_type?] = []
    for c in 0..<columnCount {
      let name = duckdb_column_name(&result, idx_t(c)).map { String(cString: $0) } ?? "?"
      let logical = duckdb_column_logical_type(&result, idx_t(c))
      columns.append(DBColumn(name: name, typeName: typeName(logical)))
      types.append(logical)
    }
    defer {
      for var type in types { duckdb_destroy_logical_type(&type) }
    }
    var out = DBResult(columns: columns)
    var total = 0
    while let fetched = duckdb_fetch_chunk(result) {
      var chunk: duckdb_data_chunk? = fetched
      defer { duckdb_destroy_data_chunk(&chunk) }
      let size = Int(duckdb_data_chunk_get_size(chunk))
      total += size
      guard out.rows.count < maxRows else { continue }
      let vectors = (0..<columnCount).map { duckdb_data_chunk_get_vector(chunk, idx_t($0)) }
      for row in 0..<size where out.rows.count < maxRows {
        var values: [DBValue] = []
        values.reserveCapacity(columnCount)
        for c in 0..<columnCount {
          guard let vector = vectors[c], let type = types[c] else {
            values.append(.null)
            continue
          }
          values.append(decode(vector, type, row))
        }
        out.rows.append(values)
      }
    }
    if total > maxRows { out.messages.append("Showing the first \(maxRows) of \(total) rows") }
    // INSERT/UPDATE/DELETE answer with a single "Count" column.
    if columnCount == 1, columns[0].name == "Count", out.rows.count == 1, let n = out.rows[0][0].intValue {
      out.affectedRows = Int(n)
    }
    return out
  }

  static func decode(_ vector: duckdb_vector, _ type: duckdb_logical_type, _ row: Int) -> DBValue {
    if let validity = duckdb_vector_get_validity(vector), !duckdb_validity_row_is_valid(validity, idx_t(row)) {
      return .null
    }
    let id = duckdb_get_type_id(type)
    // Struct and union vectors keep their values in child vectors and have no data of their own.
    if id == DUCKDB_TYPE_STRUCT || id == DUCKDB_TYPE_UNION { return decodeComposite(vector, type, row, id: id) }
    guard let data = duckdb_vector_get_data(vector) else { return .null }
    switch id {
    case DUCKDB_TYPE_BOOLEAN: return .bool(data.load(fromByteOffset: row, as: Bool.self))
    case DUCKDB_TYPE_TINYINT: return .int(Int64(data.load(fromByteOffset: row, as: Int8.self)))
    case DUCKDB_TYPE_SMALLINT: return .int(Int64(data.load(fromByteOffset: row * 2, as: Int16.self)))
    case DUCKDB_TYPE_INTEGER: return .int(Int64(data.load(fromByteOffset: row * 4, as: Int32.self)))
    case DUCKDB_TYPE_BIGINT: return .int(data.load(fromByteOffset: row * 8, as: Int64.self))
    case DUCKDB_TYPE_UTINYINT: return .int(Int64(data.load(fromByteOffset: row, as: UInt8.self)))
    case DUCKDB_TYPE_USMALLINT: return .int(Int64(data.load(fromByteOffset: row * 2, as: UInt16.self)))
    case DUCKDB_TYPE_UINTEGER: return .int(Int64(data.load(fromByteOffset: row * 4, as: UInt32.self)))
    case DUCKDB_TYPE_UBIGINT:
      let value = data.load(fromByteOffset: row * 8, as: UInt64.self)
      return Int64(exactly: value).map(DBValue.int) ?? .decimal(String(value))
    case DUCKDB_TYPE_FLOAT: return .double(Double(data.load(fromByteOffset: row * 4, as: Float.self)))
    case DUCKDB_TYPE_DOUBLE: return .double(data.load(fromByteOffset: row * 8, as: Double.self))
    case DUCKDB_TYPE_HUGEINT:
      let h = data.load(fromByteOffset: row * 16, as: duckdb_hugeint.self)
      return .decimal(int128String(upper: h.upper, lower: h.lower))
    case DUCKDB_TYPE_UHUGEINT:
      let h = data.load(fromByteOffset: row * 16, as: duckdb_uhugeint.self)
      return .decimal(uint128String(upper: h.upper, lower: h.lower))
    case DUCKDB_TYPE_DECIMAL:
      let scale = Int(duckdb_decimal_scale(type))
      let digits: String
      switch duckdb_decimal_internal_type(type) {
      case DUCKDB_TYPE_SMALLINT: digits = String(data.load(fromByteOffset: row * 2, as: Int16.self))
      case DUCKDB_TYPE_INTEGER: digits = String(data.load(fromByteOffset: row * 4, as: Int32.self))
      case DUCKDB_TYPE_BIGINT: digits = String(data.load(fromByteOffset: row * 8, as: Int64.self))
      default:
        let h = data.load(fromByteOffset: row * 16, as: duckdb_hugeint.self)
        digits = int128String(upper: h.upper, lower: h.lower)
      }
      return .decimal(scaled(digits, scale: scale))
    case DUCKDB_TYPE_VARCHAR, DUCKDB_TYPE_BLOB, DUCKDB_TYPE_BIT:
      var string = data.load(fromByteOffset: row * 16, as: duckdb_string_t.self)
      let length = Int(duckdb_string_t_length(string))
      guard let pointer = duckdb_string_t_data(&string) else { return .text("") }
      let bytes = Array(UnsafeRawBufferPointer(start: pointer, count: length))
      return id == DUCKDB_TYPE_VARCHAR ? .text(String(decoding: bytes, as: UTF8.self)) : .bytes(bytes)
    case DUCKDB_TYPE_DATE:
      return .text(date(Int64(data.load(fromByteOffset: row * 4, as: Int32.self))))
    case DUCKDB_TYPE_TIME:
      return .text(time(micros: data.load(fromByteOffset: row * 8, as: Int64.self)))
    case DUCKDB_TYPE_TIMESTAMP:
      return .text(timestamp(micros: data.load(fromByteOffset: row * 8, as: Int64.self)))
    case DUCKDB_TYPE_TIMESTAMP_TZ:
      return .text(timestamp(micros: data.load(fromByteOffset: row * 8, as: Int64.self)) + "+00")
    case DUCKDB_TYPE_TIMESTAMP_S:
      return .text(timestamp(micros: data.load(fromByteOffset: row * 8, as: Int64.self) * 1_000_000))
    case DUCKDB_TYPE_TIMESTAMP_MS:
      return .text(timestamp(micros: data.load(fromByteOffset: row * 8, as: Int64.self) * 1000))
    case DUCKDB_TYPE_TIMESTAMP_NS:
      return .text(timestamp(micros: data.load(fromByteOffset: row * 8, as: Int64.self) / 1000))
    case DUCKDB_TYPE_INTERVAL:
      let i = data.load(fromByteOffset: row * 16, as: duckdb_interval.self)
      return .text(interval(months: i.months, days: i.days, micros: i.micros))
    case DUCKDB_TYPE_UUID:
      let h = data.load(fromByteOffset: row * 16, as: duckdb_hugeint.self)
      let upper = UInt64(bitPattern: h.upper) ^ (1 << 63)
      var bytes: [UInt8] = []
      for shift in stride(from: 56, through: 0, by: -8) { bytes.append(UInt8(truncatingIfNeeded: upper >> UInt64(shift))) }
      for shift in stride(from: 56, through: 0, by: -8) { bytes.append(UInt8(truncatingIfNeeded: h.lower >> UInt64(shift))) }
      return .uuid(
        UUID(
          uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7], bytes[8], bytes[9],
            bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]
          )))
    case DUCKDB_TYPE_ENUM:
      let index: Int
      switch duckdb_enum_internal_type(type) {
      case DUCKDB_TYPE_UTINYINT: index = Int(data.load(fromByteOffset: row, as: UInt8.self))
      case DUCKDB_TYPE_USMALLINT: index = Int(data.load(fromByteOffset: row * 2, as: UInt16.self))
      default: index = Int(data.load(fromByteOffset: row * 4, as: UInt32.self))
      }
      guard let name = duckdb_enum_dictionary_value(type, idx_t(index)) else { return .text(String(index)) }
      defer { duckdb_free(name) }
      return .text(String(cString: name))
    case DUCKDB_TYPE_LIST, DUCKDB_TYPE_MAP:
      let entry = data.load(fromByteOffset: row * MemoryLayout<duckdb_list_entry>.stride, as: duckdb_list_entry.self)
      guard let child = duckdb_list_vector_get_child(vector) else { return .list([]) }
      var childType = duckdb_list_type_child_type(type)
      defer { duckdb_destroy_logical_type(&childType) }
      guard let childType else { return .list([]) }
      let items = (0..<Int(entry.length)).map { decode(child, childType, Int(entry.offset) + $0) }
      if id == DUCKDB_TYPE_MAP {
        return .map(
          items.compactMap { item in
            guard case .map(let fields) = item, fields.count == 2 else { return nil }
            return DBPair(key: fields[0].value, value: fields[1].value)
          })
      }
      return .list(items)
    default:
      return .text("(\(typeName(type)))")
    }
  }

  static func decodeComposite(_ vector: duckdb_vector, _ type: duckdb_logical_type, _ row: Int, id: duckdb_type)
    -> DBValue
  {
    switch id {
    case DUCKDB_TYPE_STRUCT:
      let count = Int(duckdb_struct_type_child_count(type))
      var pairs: [DBPair] = []
      for i in 0..<count {
        guard let child = duckdb_struct_vector_get_child(vector, idx_t(i)) else { continue }
        var childType = duckdb_struct_type_child_type(type, idx_t(i))
        defer { duckdb_destroy_logical_type(&childType) }
        let namePointer = duckdb_struct_type_child_name(type, idx_t(i))
        let name = namePointer.map { String(cString: $0) } ?? "\(i)"
        if let namePointer { duckdb_free(namePointer) }
        guard let childType else { continue }
        pairs.append(DBPair(key: .text(name), value: decode(child, childType, row)))
      }
      return .map(pairs)
    case DUCKDB_TYPE_UNION:
      // A union is a struct whose first child is the member tag.
      guard let tagVector = duckdb_struct_vector_get_child(vector, 0), let tagData = duckdb_vector_get_data(tagVector)
      else { return .null }
      let tag = Int(tagData.load(fromByteOffset: row, as: UInt8.self))
      guard let member = duckdb_struct_vector_get_child(vector, idx_t(tag + 1)) else { return .null }
      var memberType = duckdb_union_type_member_type(type, idx_t(tag))
      defer { duckdb_destroy_logical_type(&memberType) }
      guard let memberType else { return .null }
      return decode(member, memberType, row)
    default:
      return .null
    }
  }

  // MARK: Formatting

  static func typeName(_ type: duckdb_logical_type?) -> String {
    guard let type else { return "?" }
    let id = duckdb_get_type_id(type)
    switch id {
    case DUCKDB_TYPE_DECIMAL: return "DECIMAL(\(duckdb_decimal_width(type)),\(duckdb_decimal_scale(type)))"
    case DUCKDB_TYPE_LIST:
      var child = duckdb_list_type_child_type(type)
      defer { duckdb_destroy_logical_type(&child) }
      return typeName(child) + "[]"
    case DUCKDB_TYPE_STRUCT:
      let count = Int(duckdb_struct_type_child_count(type))
      let fields = (0..<count).map { i -> String in
        let namePointer = duckdb_struct_type_child_name(type, idx_t(i))
        let name = namePointer.map { String(cString: $0) } ?? "\(i)"
        if let namePointer { duckdb_free(namePointer) }
        var child = duckdb_struct_type_child_type(type, idx_t(i))
        defer { duckdb_destroy_logical_type(&child) }
        return "\(name) \(typeName(child))"
      }
      return "STRUCT(\(fields.joined(separator: ", ")))"
    case DUCKDB_TYPE_MAP: return "MAP"
    default: return DuckDBFile.typeName(id, logical: nil)
    }
  }

  static func uint128String(upper: UInt64, lower: UInt64) -> String {
    var hi = upper
    var lo = lower
    if hi == 0 { return String(lo) }
    var digits: [Character] = []
    while hi != 0 || lo != 0 {
      let qHi = hi / 10
      let rHi = hi % 10
      let (qLo, r) = UInt64(10).dividingFullWidth((high: rHi, low: lo))
      hi = qHi
      lo = qLo
      digits.append(Character(String(r)))
    }
    return String(digits.reversed())
  }

  static func int128String(upper: Int64, lower: UInt64) -> String {
    if upper >= 0 { return uint128String(upper: UInt64(upper), lower: lower) }
    // Two's complement negate.
    let notLower = ~lower
    let (negLower, carry) = notLower.addingReportingOverflow(1)
    let negUpper = ~UInt64(bitPattern: upper) &+ (carry ? 1 : 0)
    return "-" + uint128String(upper: negUpper, lower: negLower)
  }

  static func scaled(_ digits: String, scale: Int) -> String {
    guard scale > 0 else { return digits }
    var negative = false
    var text = digits
    if text.hasPrefix("-") {
      negative = true
      text.removeFirst()
    }
    while text.count <= scale { text = "0" + text }
    text.insert(".", at: text.index(text.endIndex, offsetBy: -scale))
    return negative ? "-" + text : text
  }

  /// Days since 1970-01-01 → yyyy-mm-dd (proleptic Gregorian).
  static func date(_ days: Int64) -> String {
    if days == Int64(Int32.max) { return "infinity" }
    if days == -Int64(Int32.max) { return "-infinity" }
    let z = days + 719_468
    let era = (z >= 0 ? z : z - 146_096) / 146_097
    let doe = z - era * 146_097
    let yoe = (doe - doe / 1460 + doe / 36524 - doe / 146_096) / 365
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100)
    let mp = (5 * doy + 2) / 153
    let d = doy - (153 * mp + 2) / 5 + 1
    let m = mp < 10 ? mp + 3 : mp - 9
    let y = yoe + era * 400 + (m <= 2 ? 1 : 0)
    return String(format: "%04lld-%02lld-%02lld", y, m, d)
  }

  static func time(micros: Int64) -> String {
    let seconds = micros / 1_000_000
    let fraction = micros % 1_000_000
    var text = String(format: "%02lld:%02lld:%02lld", seconds / 3600, seconds / 60 % 60, seconds % 60)
    if fraction != 0 {
      var f = String(format: "%06lld", fraction)
      while f.hasSuffix("0") { f.removeLast() }
      text += "." + f
    }
    return text
  }

  static func timestamp(micros: Int64) -> String {
    var days = micros / 86_400_000_000
    var rest = micros % 86_400_000_000
    if rest < 0 {
      rest += 86_400_000_000
      days -= 1
    }
    return date(days) + " " + time(micros: rest)
  }

  static func interval(months: Int32, days: Int32, micros: Int64) -> String {
    var parts: [String] = []
    if months / 12 != 0 { parts.append("\(months / 12) year\(abs(months / 12) == 1 ? "" : "s")") }
    if months % 12 != 0 { parts.append("\(months % 12) month\(abs(months % 12) == 1 ? "" : "s")") }
    if days != 0 { parts.append("\(days) day\(abs(days) == 1 ? "" : "s")") }
    if micros != 0 || parts.isEmpty { parts.append(time(micros: micros)) }
    return parts.joined(separator: " ")
  }
}
