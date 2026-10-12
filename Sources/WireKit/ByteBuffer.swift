import Foundation

/// Appends wire-format values to a growing byte array.
public struct ByteWriter: Sendable {
  public private(set) var bytes: [UInt8] = []

  public init(capacity: Int = 64) { bytes.reserveCapacity(capacity) }

  public var count: Int { bytes.count }

  public mutating func write(_ byte: UInt8) { bytes.append(byte) }
  public mutating func write<S: Sequence>(_ data: S) where S.Element == UInt8 { bytes.append(contentsOf: data) }
  public mutating func write(_ data: Data) { bytes.append(contentsOf: data) }

  public mutating func writeBE<T: FixedWidthInteger>(_ value: T) {
    withUnsafeBytes(of: value.bigEndian) { bytes.append(contentsOf: $0) }
  }

  public mutating func writeLE<T: FixedWidthInteger>(_ value: T) {
    withUnsafeBytes(of: value.littleEndian) { bytes.append(contentsOf: $0) }
  }

  public mutating func writeDoubleLE(_ value: Double) { writeLE(value.bitPattern) }
  public mutating func writeDoubleBE(_ value: Double) { writeBE(value.bitPattern) }
  public mutating func writeFloatBE(_ value: Float) { writeBE(value.bitPattern) }

  /// UTF-8 bytes followed by a NUL.
  public mutating func writeCString(_ string: String) {
    bytes.append(contentsOf: Array(string.utf8))
    bytes.append(0)
  }

  public mutating func writeUTF8(_ string: String) { bytes.append(contentsOf: Array(string.utf8)) }

  /// Overwrites a big-endian Int32 at `offset` (used for length prefixes written after the body).
  public mutating func patchBE(_ value: Int32, at offset: Int) {
    let be = value.bigEndian
    withUnsafeBytes(of: be) { raw in
      for i in 0..<4 { bytes[offset + i] = raw[i] }
    }
  }

  public mutating func patchLE(_ value: Int32, at offset: Int) {
    let le = value.littleEndian
    withUnsafeBytes(of: le) { raw in
      for i in 0..<4 { bytes[offset + i] = raw[i] }
    }
  }

  public mutating func patchBE(_ value: UInt16, at offset: Int) {
    bytes[offset] = UInt8(value >> 8)
    bytes[offset + 1] = UInt8(value & 0xFF)
  }
}

/// Reads wire-format values from a byte array, throwing on truncation.
public struct ByteReader: Sendable {
  public let bytes: [UInt8]
  public private(set) var offset: Int

  public init(_ bytes: [UInt8], offset: Int = 0) {
    self.bytes = bytes
    self.offset = offset
  }

  public init(_ data: Data) { self.init([UInt8](data)) }

  public var remaining: Int { bytes.count - offset }
  public var isAtEnd: Bool { offset >= bytes.count }

  public mutating func skip(_ n: Int) throws {
    guard n >= 0, remaining >= n else { throw WireError.truncated }
    offset += n
  }

  public func peek() throws -> UInt8 {
    guard remaining >= 1 else { throw WireError.truncated }
    return bytes[offset]
  }

  public mutating func readByte() throws -> UInt8 {
    guard remaining >= 1 else { throw WireError.truncated }
    defer { offset += 1 }
    return bytes[offset]
  }

  public mutating func readBytes(_ n: Int) throws -> [UInt8] {
    guard n >= 0, remaining >= n else { throw WireError.truncated }
    defer { offset += n }
    return Array(bytes[offset..<offset + n])
  }

  public mutating func readRest() -> [UInt8] {
    defer { offset = bytes.count }
    return Array(bytes[offset...])
  }

  public mutating func readBE<T: FixedWidthInteger>(_: T.Type = T.self) throws -> T {
    let size = MemoryLayout<T>.size
    guard remaining >= size else { throw WireError.truncated }
    var value: T = 0
    for i in 0..<size { value = (value << 8) | T(truncatingIfNeeded: bytes[offset + i]) }
    offset += size
    return value
  }

  public mutating func readLE<T: FixedWidthInteger>(_: T.Type = T.self) throws -> T {
    let size = MemoryLayout<T>.size
    guard remaining >= size else { throw WireError.truncated }
    var value: T = 0
    for i in (0..<size).reversed() { value = (value << 8) | T(truncatingIfNeeded: bytes[offset + i]) }
    offset += size
    return value
  }

  public mutating func readDoubleLE() throws -> Double { Double(bitPattern: try readLE(UInt64.self)) }
  public mutating func readDoubleBE() throws -> Double { Double(bitPattern: try readBE(UInt64.self)) }
  public mutating func readFloatBE() throws -> Float { Float(bitPattern: try readBE(UInt32.self)) }
  public mutating func readFloatLE() throws -> Float { Float(bitPattern: try readLE(UInt32.self)) }

  /// UTF-8 up to (and consuming) the next NUL.
  public mutating func readCString() throws -> String {
    guard let end = bytes[offset...].firstIndex(of: 0) else { throw WireError.truncated }
    defer { offset = end + 1 }
    return String(decoding: bytes[offset..<end], as: UTF8.self)
  }

  public mutating func readUTF8(_ n: Int) throws -> String {
    String(decoding: try readBytes(n), as: UTF8.self)
  }
}

extension Array where Element == UInt8 {
  public var hexString: String { map { String(format: "%02x", $0) }.joined() }
}
