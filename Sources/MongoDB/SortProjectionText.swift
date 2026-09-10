import Foundation

/// One sort key of the Sort field: a field plus its direction.
public struct SortKey: Equatable, Sendable {
  public let field: String
  public let ascending: Bool

  public init(field: String, ascending: Bool) {
    self.field = field
    self.ascending = ascending
  }
}

/// The Sort field's text model. The Sort field is the ONLY state behind the
/// column sort UI: `parse` turns whatever is written there into ordered keys
/// (driving header arrows), and the click/menu actions return a new key list
/// that the caller renders back into the field. Both spellings are understood
/// on every engine — `{ name: 1, value: -1 }` (Mongo document) and
/// `name ASC, value DESC` (SQL) — so hand-typed text from either dialect still
/// drives the UI. Only RENDERING is dialect-specific.
public enum SortText {
  /// Any direction spelling the query dialect accepts.
  public enum Direction: Sendable {
    case ascending, descending
  }

  // MARK: - Parsing

  /// Ordered sort keys in `text`. Never throws: malformed text yields no keys,
  /// and the query bar surfaces the execution error instead of the column UI.
  public static func parse(_ text: String) -> [SortKey] {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return [] }
    return trimmed.hasPrefix("{") ? parseDocument(trimmed) : parseList(trimmed)
  }

  /// Direction of `field` in `text` (nil = not sorted by it), for header arrows.
  public static func direction(of field: String, in text: String) -> Direction? {
    guard let key = parse(text).first(where: { $0.field == field }) else { return nil }
    return key.ascending ? .ascending : .descending
  }

  /// Direction of `field` in a working key list (nil = not sorted by it). The
  /// click/menu actions work on key lists, not on the query-bar text.
  public static func direction(of field: String, in keys: [SortKey]) -> Direction? {
    guard let key = keys.first(where: { $0.field == field }) else { return nil }
    return key.ascending ? .ascending : .descending
  }

  /// The STRICT-JSON probe for "{ a: 1, b: 2 }" (JS-style keys are handled by
  /// the tolerant parser below when this fails). A document whose values are
  /// neither directions nor 1/-1 contributes no keys, so parsing falls through
  /// to the next spelling instead of stopping at an empty result.
  private static func parseDocument(_ text: String) -> [SortKey] {
    if let doc = try? BSONSupport.document(fromJSON: text) {
      let keys = sortKeys(from: doc)
      if !keys.isEmpty { return keys }
    }
    if let doc = try? BSONSupport.document(fromQuery: text) {
      let keys = sortKeys(from: doc)
      if !keys.isEmpty { return keys }
    }
    // Not parseable as a document at all: fall back to the list form so
    // `{ name ASC }`-ish text still drives the UI.
    return parseList(text.trimmingCharacters(in: CharacterSet(charactersIn: "{} ")))
  }

  /// Every sort entry of a parsed document: Mongo's `1`/`-1` and the direction
  /// words (`asc`/`desc`/`ascending`/`descending`) both count. Any other value
  /// is not a sort entry and is skipped.
  private static func sortKeys(from doc: BSONDocument) -> [SortKey] {
    doc.all.compactMap { pair in
      switch pair.value {
      case .int32(let number) where number == 1 || number == -1:
        return SortKey(field: pair.key, ascending: number == 1)
      case .int64(let number) where number == 1 || number == -1:
        return SortKey(field: pair.key, ascending: number == 1)
      case .double(let number) where number == 1 || number == -1:
        return SortKey(field: pair.key, ascending: number == 1)
      case .string(let word):
        guard let ascending = directionWord(word) else { return nil }
        return SortKey(field: pair.key, ascending: ascending)
      default:
        return nil
      }
    }
  }

  /// `"field" ASC, "other" DESC` — also accepts `-1`/`1`, the direction words
  /// and naked keys (which are ascending).
  private static func parseList(_ text: String) -> [SortKey] {
    var keys: [SortKey] = []
    for rawTerm in text.split(separator: ",") {
      let term = rawTerm.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !term.isEmpty else { continue }
      guard let split = split(term), !split.name.isEmpty else { continue }
      guard let direction = split.direction else {
        keys.append(SortKey(field: split.name, ascending: true))
        continue
      }
      guard let ascending = directionWord(direction) else { continue }
      keys.append(SortKey(field: split.name, ascending: ascending))
    }
    return keys
  }

  /// Splits one `name [direction]` term. A double-quoted name may contain
  /// spaces (`"first name" DESC`); an unquoted name ends at the first space.
  /// nil when the term has no usable name (a lone `"` or an empty term).
  private static func split(_ term: String) -> (name: String, direction: String?)? {
    guard term.hasPrefix("\"") else {
      let tokens = term.split(separator: " ").map(String.init).filter { !$0.isEmpty }
      guard let name = tokens.first else { return nil }
      let rest = tokens.dropFirst().joined(separator: " ")
      return (name, rest.isEmpty ? nil : rest)
    }
    var name = ""
    var escaped = false
    var index = term.index(after: term.startIndex)
    var closed = false
    while index < term.endIndex {
      let character = term[index]
      if escaped {
        name.append(character)
        escaped = false
      } else if character == "\\" {
        escaped = true
      } else if character == "\"" {
        closed = true
        index = term.index(after: index)
        break
      } else {
        name.append(character)
      }
      index = term.index(after: index)
    }
    guard closed else { return nil }
    let rest = term[index...].trimmingCharacters(in: .whitespacesAndNewlines)
    return (name, rest.isEmpty ? nil : rest)
  }

  /// `ASC`/`ASCENDING`/`1` -> true, `DESC`/`DESCENDING`/`-1` -> false, anything
  /// else nil (not a direction).
  private static func directionWord(_ token: String) -> Bool? {
    switch token.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() {
    case "ASC", "ASCENDING", "1": return true
    case "DESC", "DESCENDING", "-1": return false
    default: return nil
    }
  }

  // MARK: - Rendering

  /// Sort text for `keys`, or nil when nothing is sorted. Mongo gets the
  /// document spelling, SQL the ORDER BY spelling (document spellings also
  /// compile to ORDER BY, but SQL's own spelling is what the user asked for).
  public static func render(_ keys: [SortKey], dialect: FilterDialect) -> String? {
    guard !keys.isEmpty else { return nil }
    switch dialect {
    case .mongo:
      let parts = keys.map { "\(FilterText.quotedKey($0.field)): \($0.ascending ? 1 : -1)" }
      return "{ " + parts.joined(separator: ", ") + " }"
    case .sql:
      let parts = keys.map {
        "\(FilterText.quotedKey($0.field)) \($0.ascending ? "ASC" : "DESC")"
      }
      return parts.joined(separator: ", ")
    }
  }

  // MARK: - Click / menu actions

  /// Result of a column action: the new key list plus the direction that action
  /// left the column in (nil = not sorted), so the caller can both write the
  /// Sort text and update its arrow.
  public struct Change: Sendable {
    public let keys: [SortKey]
    public let field: String
    public let direction: Direction?

    public init(keys: [SortKey], field: String, direction: Direction?) {
      self.keys = keys
      self.field = field
      self.direction = direction
    }

    /// Direction the change left `field` in (nil = not sorted), for the header
    /// arrow of that column.
    public func direction(_ field: String) -> Direction? {
      guard let key = keys.first(where: { $0.field == field }) else { return nil }
      return key.ascending ? .ascending : .descending
    }
  }

  /// Click on a column header: none -> ascending -> descending -> none. Other
  /// keys keep their position (the example: `{ name: 1 }`, then clicking `value`
  /// appends -> `{ name: 1, value: 1 }`).
  public static func cycle(_ field: String, in keys: [SortKey]) -> Change {
    switch direction(of: field, in: keys) {
    case .none: return change(set(field, direction: .ascending, in: keys), field: field)
    case .some(.ascending): return change(set(field, direction: .descending, in: keys), field: field)
    case .some(.descending): return change(remove(field, from: keys), field: field)
    }
  }

  /// Explicit direction from a context menu item (Sort Ascending/Descending).
  public static func apply(_ direction: Direction, to field: String, in keys: [SortKey]) -> Change {
    change(set(field, direction: direction, in: keys), field: field)
  }

  /// Disable sorting for one column ("Disable Sorting" in the menus).
  public static func disable(_ field: String, in keys: [SortKey]) -> Change {
    change(remove(field, from: keys), field: field)
  }

  /// Sets `field` to `direction`, replacing its entry in place or appending it.
  public static func set(_ field: String, direction: Direction, in keys: [SortKey]) -> [SortKey] {
    let replacement = SortKey(field: field, ascending: direction == .ascending)
    guard let index = keys.firstIndex(where: { $0.field == field }) else {
      return keys + [replacement]
    }
    var updated = keys
    updated[index] = replacement
    return updated
  }

  /// Drops `field` from the sort list, keeping the order of the rest.
  public static func remove(_ field: String, from keys: [SortKey]) -> [SortKey] {
    keys.filter { $0.field != field }
  }

  /// Keys that still name a field the results actually carry. Called with the
  /// visible column set so a sort on a hidden/absent column is dropped instead
  /// of silently ordering by something the user cannot see.
  public static func reconciled(_ keys: [SortKey], with fields: [String]) -> [SortKey] {
    keys.filter { fields.contains($0.field) }
  }

  private static func change(_ keys: [SortKey], field: String) -> Change {
    Change(keys: keys, field: field, direction: direction(of: field, in: keys))
  }
}

/// The Projection field's text model: which columns the user has hidden, in
/// either spelling. Mongo hides with exclusions (`{ note: 0 }`); SQL hides with an
/// include list of everything else (`{ _id: 1, name: 1 }`) because
/// SQLQueryCompiler rejects exclusion projections ("Projection \"note: 0\"
/// (exclusion) can't map to SQL"). The hidden set is therefore DERIVED from the
/// text plus the field universe of the loaded rows — never stored in a view.
public enum ProjectionText {
  /// Fields hidden by `text`, given the field universe of the loaded rows.
  public static func hidden(
    in text: String, allFields: [String], dialect: FilterDialect
  ) -> [String] {
    let parsed = parse(text)
    switch dialect {
    case .mongo:
      return parsed.excluded
    case .sql:
      guard !parsed.included.isEmpty else { return [] }
      return allFields.filter { !parsed.included.contains($0) }
    }
  }

  /// Projection text hiding exactly `hidden` (`nil` = no projection at all, i.e.
  /// every field). Unknown names are ignored, and the render order follows the
  /// field universe so the text reads like the table.
  public static func render(
    hidden: [String], allFields: [String], dialect: FilterDialect
  ) -> String? {
    let hide = allFields.filter { hidden.contains($0) }
    guard !hide.isEmpty else { return nil }
    switch dialect {
    case .mongo:
      let parts = hide.map { "\(FilterText.quotedKey($0)): 0" }
      return "{ " + parts.joined(separator: ", ") + " }"
    case .sql:
      let kept = allFields.filter { !hide.contains($0) }
      guard !kept.isEmpty else { return nil }  // "hide everything" isn't expressible
      let parts = kept.map { "\(FilterText.quotedKey($0)): 1" }
      return "{ " + parts.joined(separator: ", ") + " }"
    }
  }

  /// Hides one more field. Mongo appends the exclusion; SQL rebuilds the include
  /// list from every field except the hidden ones. Idempotent.
  public static func hide(
    _ field: String, in text: String, allFields: [String], dialect: FilterDialect
  ) -> String? {
    var hiddenFields = hidden(in: text, allFields: allFields, dialect: dialect)
    guard !hiddenFields.contains(field) else { return text.isEmpty ? nil : text }
    hiddenFields.append(field)
    return render(hidden: hiddenFields, allFields: allFields, dialect: dialect)
  }

  /// Shows a hidden field again (`nil` = back to no projection).
  public static func show(
    _ field: String, in text: String, allFields: [String], dialect: FilterDialect
  ) -> String? {
    var hiddenFields = hidden(in: text, allFields: allFields, dialect: dialect)
    guard hiddenFields.contains(field) else { return text.isEmpty ? nil : text }
    hiddenFields.removeAll { $0 == field }
    return render(hidden: hiddenFields, allFields: allFields, dialect: dialect)
  }

  /// "Show All Fields" in the query bar: clears the Projection field.
  public static var showAll: String? { nil }

  /// Parsed include/exclude lists. Understands `{ note: 0 }`, `{ _id: 1, name: 1 }`
  /// and a raw SQL column list (`id, name`, treated as include-only).
  static func parse(_ text: String) -> (included: [String], excluded: [String]) {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return ([], []) }
    if trimmed.hasPrefix("{"),
      let doc = try? BSONSupport.document(fromQuery: trimmed),
      !doc.isEmpty
    {
      var included: [String] = []
      var excluded: [String] = []
      for (key, value) in doc.all {
        switch value {
        case .int32(1), .int64(1), .double(1), .bool(true): included.append(key)
        case .int32(0), .int64(0), .double(0), .bool(false): excluded.append(key)
        default: continue
        }
      }
      return (included, excluded)
    }
    let names = trimmed.split(separator: ",").map {
      $0.trimmingCharacters(in: .whitespacesAndNewlines)
        .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
    }.filter { !$0.isEmpty }
    return (names, [])
  }
}
