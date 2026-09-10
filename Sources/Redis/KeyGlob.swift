import Foundation

/// Builds a Redis key pattern (SCAN MATCH glob) from the UI filter. `*` matches
/// any run of characters, `?` one character and `[...]` a character class, so
/// glob metacharacters typed by the user are backslash-escaped to match
/// literally.
public enum KeyGlob {
  public enum Match: String, CaseIterable, Identifiable, Sendable {
    case contains, startsWith, endsWith, exact

    public var id: String { rawValue }

    public var label: String {
      switch self {
      case .contains: return "contains"
      case .startsWith: return "starts with"
      case .endsWith: return "ends with"
      case .exact: return "is exactly"
      }
    }
  }

  /// `pattern("user", .contains)` -> `*user*`; nil when there is no text (no filter).
  public static func pattern(_ text: String, match: Match) -> String? {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }
    let body = escaped(trimmed)
    switch match {
    case .contains: return "*\(body)*"
    case .startsWith: return "\(body)*"
    case .endsWith: return "*\(body)"
    case .exact: return body
    }
  }

  /// True when the user typed glob syntax themselves, so the text is passed to
  /// SCAN MATCH verbatim instead of being wrapped as a substring search.
  public static func isPattern(_ text: String) -> Bool {
    text.contains("*") || text.contains("?") || text.contains("[")
  }

  /// Backslash-escapes glob metacharacters so user text matches literally.
  static func escaped(_ text: String) -> String {
    var out = ""
    for character in text {
      if "*?[]\\".contains(character) { out.append("\\") }
      out.append(character)
    }
    return out
  }
}
