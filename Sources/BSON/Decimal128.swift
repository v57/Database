import Foundation

/// IEEE 754-2008 decimal128 in binary integer decimal (BID) encoding, as BSON stores it.
public struct Decimal128: Sendable, Hashable, CustomStringConvertible {
  public let high: UInt64
  public let low: UInt64

  public init(high: UInt64, low: UInt64) {
    self.high = high
    self.low = low
  }

  static let bias = 6176

  public var isNegative: Bool { high >> 63 == 1 }

  public var description: String {
    let combination = (high >> 58) & 0x1F
    if combination == 0x1F { return "NaN" }
    if combination == 0x1E { return isNegative ? "-Infinity" : "Infinity" }

    var exponent: Int
    var hi: UInt64
    var lo = low
    if (high >> 61) & 3 == 3 {
      // The "11" form only encodes coefficients above 10^34, which are non-canonical: zero.
      exponent = Int((high >> 47) & 0x3FFF) - Self.bias
      hi = 0
      lo = 0
    } else {
      exponent = Int((high >> 49) & 0x3FFF) - Self.bias
      hi = high & 0x1_FFFF_FFFF_FFFF
    }

    var digits = Self.decimalDigits(hi: hi, lo: lo)
    if digits.isEmpty { digits = "0" }
    let adjusted = exponent + digits.count - 1
    var text: String
    if exponent <= 0 && adjusted >= -6 {
      if exponent == 0 {
        text = digits
      } else {
        let point = digits.count + exponent
        if point > 0 {
          text = String(digits.prefix(point)) + "." + String(digits.dropFirst(point))
        } else {
          text = "0." + String(repeating: "0", count: -point) + digits
        }
      }
    } else {
      text = String(digits.prefix(1))
      if digits.count > 1 { text += "." + digits.dropFirst() }
      text += "E" + (adjusted >= 0 ? "+" : "") + String(adjusted)
    }
    return isNegative ? "-" + text : text
  }

  /// Parses decimal text such as "12.50", "-1E+3", "NaN" or "Infinity".
  public init?(_ string: String) {
    var text = string.trimmingCharacters(in: .whitespaces)
    var negative = false
    if text.hasPrefix("-") {
      negative = true
      text.removeFirst()
    } else if text.hasPrefix("+") {
      text.removeFirst()
    }
    let sign: UInt64 = negative ? 1 << 63 : 0
    switch text.lowercased() {
    case "nan":
      self.init(high: 0x7C00_0000_0000_0000, low: 0)
      return
    case "inf", "infinity":
      self.init(high: sign | 0x7800_0000_0000_0000, low: 0)
      return
    default: break
    }
    var mantissa = text
    var exponent = 0
    if let e = text.firstIndex(where: { $0 == "e" || $0 == "E" }) {
      guard let value = Int(text[text.index(after: e)...]) else { return nil }
      exponent = value
      mantissa = String(text[..<e])
    }
    var digits = ""
    var seenPoint = false
    for ch in mantissa {
      if ch == "." {
        if seenPoint { return nil }
        seenPoint = true
      } else if ch.isASCII, ch.isNumber {
        digits.append(ch)
        if seenPoint { exponent -= 1 }
      } else {
        return nil
      }
    }
    guard !digits.isEmpty else { return nil }
    // Trim leading zeros, then drop trailing zeros only when there are too many digits.
    while digits.count > 1 && digits.hasPrefix("0") { digits.removeFirst() }
    while digits.count > 34 && digits.hasSuffix("0") {
      digits.removeLast()
      exponent += 1
    }
    guard digits.count <= 34 else { return nil }
    let biased = exponent + Self.bias
    guard biased >= 0 && biased <= 0x2FFF else { return nil }
    var hi: UInt64 = 0
    var lo: UInt64 = 0
    for ch in digits {
      let d = UInt64(ch.asciiValue! - 48)
      // (hi, lo) = (hi, lo) * 10 + d
      let loTimes10 = lo.multipliedFullWidth(by: 10)
      let (newLo, carry) = loTimes10.low.addingReportingOverflow(d)
      hi = hi &* 10 &+ loTimes10.high &+ (carry ? 1 : 0)
      lo = newLo
    }
    self.init(high: sign | UInt64(biased) << 49 | (hi & 0x1_FFFF_FFFF_FFFF), low: lo)
  }

  /// Base-10 digits of a 128-bit unsigned integer.
  static func decimalDigits(hi: UInt64, lo: UInt64) -> String {
    var hi = hi
    var lo = lo
    var out: [Character] = []
    while hi != 0 || lo != 0 {
      // Divide (hi, lo) by 10.
      let qHi = hi / 10
      let rHi = hi % 10
      let (qLo, rLo) = UInt64(10).dividingFullWidth((high: rHi, low: lo))
      hi = qHi
      lo = qLo
      out.append(Character(String(rLo)))
    }
    return String(out.reversed())
  }
}
