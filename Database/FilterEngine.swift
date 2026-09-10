import MongoDB

/// Engine-specific pieces of the UI filter builder: which query dialect a rule
/// set renders to, which operators make sense for an inferred field kind, and
/// how Redis key matching maps to a glob. Kept deliberately thin — all real
/// logic lives in Sources/MongoDB/FilterRules.swift and Sources/Redis/KeyGlob.swift.
enum FilterEngine {
  /// nil for engines without a query language (Redis).
  static func dialect(for engine: DatabaseEngine?) -> FilterDialect? {
    switch engine {
    case .mongodb, nil: return .mongo
    case .postgresql, .sqlite: return .sql
    case .redis: return nil
    }
  }

  /// Operators offered for a field of `kind`. Text matching is offered for text
  /// and unknown/mixed fields, comparisons for numeric/date fields.
  static func operators(for kind: FieldKind) -> [FilterOp] {
    switch kind {
    case .string:
      return [.equal, .notEqual, .contains, .notContains, .startsWith, .endsWith,
        .inList, .notInList, .isEmpty, .isNotEmpty]
    case .number, .date:
      return [.equal, .notEqual, .lessThan, .lessOrEqual, .greaterThan, .greaterOrEqual,
        .inList, .notInList, .isEmpty, .isNotEmpty]
    case .boolean:
      return [.equal, .notEqual, .isEmpty, .isNotEmpty]
    case .objectID:
      return [.equal, .notEqual, .inList, .notInList, .isEmpty, .isNotEmpty]
    default:
      return [.equal, .notEqual, .contains, .notContains, .inList, .notInList,
        .isEmpty, .isNotEmpty]
    }
  }

  /// The default operator when a chip is created for a field of `kind`.
  static func defaultOperator(for kind: FieldKind) -> FilterOp {
    operators(for: kind).first ?? .equal
  }
}
