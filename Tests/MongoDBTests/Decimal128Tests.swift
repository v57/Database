import Testing

@testable import MongoDB

/// Decimal128 display: BSON wire bytes are little-endian BID.
@Suite struct Decimal128Tests {
  /// Wire bytes for `coefficient × 10^exponent`.
  private func decimal(_ coefficient: UInt64, exponent: Int, negative: Bool = false) throws
    -> Decimal128
  {
    var high = UInt64(exponent + 6176) << 49
    if negative { high |= UInt64(1) << 63 }
    return try wire(low: coefficient, high: high)
  }

  private func wire(low: UInt64, high: UInt64) throws -> Decimal128 {
    var bytes: [UInt8] = []
    for word in [low, high] {
      for i in 0..<8 { bytes.append(UInt8((word >> (8 * UInt64(i))) & 0xFF)) }
    }
    return try Decimal128(bytes: bytes)
  }

  @Test func rendersFractions() throws {
    #expect(try decimal(1999, exponent: -2).description == "19.99")
    #expect(try decimal(510, exponent: -2, negative: true).description == "-5.10")
    #expect(try decimal(7, exponent: -3).description == "0.007")
  }

  @Test func rendersIntegers() throws {
    #expect(try decimal(42, exponent: 0).description == "42")
    #expect(try decimal(12, exponent: 2).description == "1200")
    #expect(try decimal(0, exponent: 0).description == "0")
  }

  @Test func rendersSpecialValues() throws {
    #expect(try wire(low: 0, high: 0x7800_0000_0000_0000).description == "Infinity")
    #expect(try wire(low: 0, high: 0xF800_0000_0000_0000).description == "-Infinity")
    #expect(try wire(low: 0, high: 0x7C00_0000_0000_0000).description == "NaN")
  }

  /// The largest 34-digit coefficient uses the full 113 bits.
  @Test func rendersMaximumCoefficient() throws {
    // 10^34 - 1 = 0x1ED09BEAD87C0378D8E63FFFFFFFF
    let value = try wire(low: 0x378D_8E63_FFFF_FFFF, high: (UInt64(6176) << 49) | 0x0001_ED09_BEAD_87C0)
    #expect(value.description == String(repeating: "9", count: 34))
  }
}
