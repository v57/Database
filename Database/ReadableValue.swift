import Foundation
import MongoDB

/// Values as a person reads them: "Yes" rather than `true`, a local date
/// rather than ISO 8601, "3 fields" rather than raw JSON. Used where a record
/// is read rather than queried (the record inspector, confirmations); the
/// List/JSON formats keep the exact stored form.
enum ReadableValue {
  static func text(_ bson: BSON) -> String {
    switch bson {
    case .bool(let flag): return flag ? "Yes" : "No"
    case .datetime(let date): return date.formatted(date: .abbreviated, time: .shortened)
    case .null, .undefined: return "Empty"
    case .double(let number):
      // 8.0 reads as 8; anything with a fraction keeps it.
      if number.rounded() == number, abs(number) < 1e15 { return String(Int64(number)) }
      return String(number)
    case .binary(let binary):
      let size = ByteCountFormatter.string(
        fromByteCount: Int64(binary.data.count), countStyle: .file)
      return "Binary data, \(size)"
    case .document(let document):
      return document.count == 1 ? "1 field" : "\(document.count) fields"
    case .array(let items):
      return items.count == 1 ? "1 item" : "\(items.count) items"
    default: return BSONSupport.displayString(bson)
    }
  }

  /// Table cells: like the stored form, except for values whose stored form
  /// is unreadable (ISO timestamps, base64 bytes).
  static func cellText(_ bson: BSON) -> String {
    switch bson {
    case .datetime, .binary: text(bson)
    default: BSONSupport.displayString(bson)
    }
  }

  /// Values that read as "nothing here" and are drawn dimmed.
  static func isBlank(_ bson: BSON) -> Bool {
    switch bson {
    case .null, .undefined: true
    case .string(let text): text.isEmpty
    default: false
    }
  }
}

/// What a person would call a record: its title, name, email…, so a
/// confirmation can say “Delete “Up”?” instead of “Delete record 3?”.
enum RecordName {
  private static let preferredFields = [
    "title", "name", "full_name", "fullname", "display_name", "displayname", "label",
    "username", "email", "subject", "key",
  ]

  static func of(_ document: Document) -> String? {
    let strings = document.all.compactMap { field -> (key: String, text: String)? in
      guard case .string(let text) = field.value else { return nil }
      let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
      return trimmed.isEmpty ? nil : (field.key, trimmed)
    }
    let preferred = preferredFields.lazy.compactMap { name in
      strings.first { $0.key.lowercased() == name }
    }.first
    // Otherwise the first short text that isn't an identifier.
    guard
      let pick = preferred
        ?? strings.first(where: {
          $0.key != "_id" && !$0.key.lowercased().hasSuffix("id") && $0.text.count <= 60
        })
    else { return nil }
    return pick.text.count > 40 ? String(pick.text.prefix(39)) + "…" : pick.text
  }
}
