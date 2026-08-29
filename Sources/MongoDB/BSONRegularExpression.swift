import Foundation

/// BSON regular expression: a pattern string plus an options string
/// (e.g. "i", "m", "s"). Round-trips through the codec.
public struct BSONRegularExpression: Equatable, Sendable, CustomStringConvertible {
  public let pattern: String
  public let options: String

  public init(pattern: String, options: String = "") {
    self.pattern = pattern
    self.options = options
  }

  public var description: String {
    options.isEmpty ? pattern : "\(pattern)/\(options)"
  }
}
