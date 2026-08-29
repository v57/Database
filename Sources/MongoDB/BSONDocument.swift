import Foundation

/// A BSON document: an ordered key→value map with keyed collection semantics.
/// This is the module's own value type, replacing the swift-bson re-export, so
/// `Document` (typealiased to this) supports subscript get/set/delete, dictionary
/// and array literal construction, and round-trips through the codec.
///
/// Ordered storage preserves insertion order (matching the driver's BSONDocument);
/// duplicate keys keep the last value (matching dictionary-literal semantics).
public struct BSONDocument: Equatable, Sendable {
  /// Ordered key→value pairs. Duplicate keys resolve to the last written value
  /// but retain the first position in the ordered list, matching the driver.
  private var pairs: [(key: String, value: BSON)] = []

  public init() {}

  public init(dictionaryLiteral elements: (String, BSON)...) {
    for (k, v) in elements { self[k] = v }
  }

  /// Accepts a pre-built array of pairs (for variadic-forwarding).
  public init(pairs: [(key: String, value: BSON)]) {
    for (k, v) in pairs { self[k] = v }
  }

  // MARK: - Equatable (manual — tuple array prevents synthesis)

  public static func == (lhs: BSONDocument, rhs: BSONDocument) -> Bool {
    // Order-insensitive, value-based comparison: last value wins per key.
    guard lhs.count == rhs.count else { return false }
    for key in lhs.keys {
      guard let lv = lhs[key], let rv = rhs[key], lv == rv else { return false }
    }
    return true
  }

  // MARK: - Ordered key access

  /// All keys, in insertion order.
  public var keys: [String] { pairs.map(\.key) }

  /// All values, in insertion order.
  public var values: [BSON] { pairs.map(\.value) }

  /// All key→value pairs, in insertion order.
  public var all: [(key: String, value: BSON)] { pairs }

  /// Number of entries.
  public var count: Int { pairs.count }

  public var isEmpty: Bool { pairs.isEmpty }

  // MARK: - Subscript (read / write / delete)

  public subscript(key: String) -> BSON? {
    get {
      // Last occurrence wins.
      for i in stride(from: pairs.count - 1, through: 0, by: -1) where pairs[i].key == key {
        return pairs[i].value
      }
      return nil
    }
    set {
      if let newValue = newValue {
        // Replace in place if the key exists (first occurrence keeps position);
        // otherwise append.
        for i in pairs.indices where pairs[i].key == key {
          pairs[i].value = newValue
          return
        }
        pairs.append((key, newValue))
      } else {
        // Delete: remove every occurrence of the key.
        pairs.removeAll { $0.key == key }
      }
    }
  }

  /// Convenience: true when the key exists.
  public func contains(_ key: String) -> Bool { self[key] != nil }

  // MARK: - Iteration

  /// Iterate ordered (key, value) pairs.
  public var elements: [(key: String, value: BSON)] { pairs }

  public var sortedByKey: [(key: String, value: BSON)] {
    pairs.sorted { $0.key < $1.key }
  }

  // MARK: - Dictionary-of-keys convenience

  public var dictionary: [String: BSON] {
    var d: [String: BSON] = [:]
    for (k, v) in pairs { d[k] = v }
    return d
  }
}

// MARK: - Literal conformances

extension BSONDocument: ExpressibleByDictionaryLiteral {}
extension BSONDocument: ExpressibleByArrayLiteral {
  public init(arrayLiteral elements: BSON...) {
    self.init()
    for (i, value) in elements.enumerated() { self[String(i)] = value }
  }
}

// MARK: - String-keyed subscript over BSONDocument for Boxed containers

extension BSON {
  /// Direct document access for convenience patterns in the app layer.
  public var documentValue: BSONDocument? {
    if case .document(let d) = self { return d }
    return nil
  }

  public var arrayValue: [BSON]? {
    if case .array(let a) = self { return a }
    return nil
  }
}
