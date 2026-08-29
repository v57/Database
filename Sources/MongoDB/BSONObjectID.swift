import Foundation

/// BSON ObjectId: a 12-byte value (4-byte timestamp, 5-byte random, 3-byte
/// counter), rendered as a 24-char lowercase hex string.
public struct BSONObjectID: Equatable, Sendable, CustomStringConvertible {
  public static let byteCount = 12
  /// Raw 12 bytes in wire order.
  public let bytes: [UInt8]

  /// Creates an ObjectId from its 24-character lowercase hex representation.
  public init(_ hex: String) throws {
    let trimmed = hex.trimmingCharacters(in: .whitespacesAndNewlines)
    guard trimmed.count == Self.byteCount * 2 else {
      throw BSONError.invalid("ObjectId must be 24 hex characters (got \(trimmed.count))")
    }
    var raw: [UInt8] = []
    raw.reserveCapacity(Self.byteCount)
    var it = trimmed.lowercased()
    for _ in 0..<Self.byteCount {
      let pair = String(it.prefix(2))
      it = String(it.dropFirst(2))
      guard let byte = UInt8(pair, radix: 16) else {
        throw BSONError.invalid("ObjectId contains non-hex characters")
      }
      raw.append(byte)
    }
    self.bytes = raw
  }

  /// Accepts raw wire bytes.
  public init(bytes: [UInt8]) throws {
    guard bytes.count == Self.byteCount else {
      throw BSONError.invalid("ObjectId must be 12 bytes (got \(bytes.count))")
    }
    self.bytes = bytes
  }

  public init(hex: String) throws { try self.init(hex) }

  /// Lowercase hex string (24 chars).
  public var hex: String {
    var out = ""
    out.reserveCapacity(Self.byteCount * 2)
    for b in bytes { out += String(format: "%02x", b) }
    return out
  }

  public var description: String { hex }
}
