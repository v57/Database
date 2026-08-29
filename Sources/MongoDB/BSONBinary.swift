import Foundation

/// BSON binary subtype values (the low four bits of the wire tag).
public enum BinarySubtype: UInt8, Equatable, Sendable {
  case generic = 0x00
  case function = 0x01
  case binaryOld = 0x02
  case uuidOld = 0x03
  case uuid = 0x04
  case md5 = 0x05
  case encrypted = 0x06
  case column = 0x07
  case sensitive = 0x08
  case userDefined = 0x80

  /// Casts a raw subtype byte to a known case, falling back to a synthesized
  /// `userDefined` family value when the low nibble is > 8.
  public init(_ raw: UInt8) {
    let low = raw & 0x0F
    switch low {
    case 0x00: self = .generic
    case 0x01: self = .function
    case 0x02: self = .binaryOld
    case 0x03: self = .uuidOld
    case 0x04: self = .uuid
    case 0x05: self = .md5
    case 0x06: self = .encrypted
    case 0x07: self = .column
    case 0x08: self = .sensitive
    default: self = .userDefined
    }
  }

  /// The wire byte for this subtype.
  public var rawValue: UInt8 {
    switch self {
    case .generic: return 0x00
    case .function: return 0x01
    case .binaryOld: return 0x02
    case .uuidOld: return 0x03
    case .uuid: return 0x04
    case .md5: return 0x05
    case .encrypted: return 0x06
    case .column: return 0x07
    case .sensitive: return 0x08
    case .userDefined: return 0x80
    }
  }
}

/// BSON binary value: raw data plus a subtype.
public struct BSONBinary: Equatable, Sendable {
  public let data: Data
  public let subtype: BinarySubtype

  public init(data: Data, subtype: BinarySubtype = .generic) {
    self.data = data
    self.subtype = subtype
  }
}
