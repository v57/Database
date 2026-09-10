import Foundation
import Testing

@testable import MongoDB

/// Pure unit tests for the UI filter builder's rendering: rules -> query-bar
/// filter text for the Mongo dialect, plus the dialect-independent pieces
/// (quoted keys, list rendering, value coercion from typed text). No server.
@Suite struct FilterRulesTests {

  // MARK: - Scalar operators (shared by both dialects)

  @Test func equalityRendersBareKeyAndLiteral() {
    let rules = [FilterRule(field: "age", op: .equal, value: .int32(30))]
    #expect(FilterText.render(rules, dialect: .mongo) == "{ age: 30 }")
  }

  @Test func stringEqualityQuotesAndEscapesTheValue() {
    let rules = [FilterRule(field: "name", op: .equal, value: .string("O'Brien\"x"))]
    #expect(FilterText.render(rules, dialect: .mongo) == #"{ name: "O'Brien\"x" }"#)
  }

  @Test func comparisonOperatorsMapToMongoDollarOps() {
    #expect(
      FilterText.render([FilterRule(field: "age", op: .greaterThan, value: .int32(30))],
        dialect: .mongo) == "{ age: { \"$gt\": 30 } }")
    #expect(
      FilterText.render([FilterRule(field: "age", op: .lessOrEqual, value: .int32(30))],
        dialect: .mongo) == "{ age: { \"$lte\": 30 } }")
    #expect(
      FilterText.render([FilterRule(field: "age", op: .notEqual, value: .int32(30))],
        dialect: .mongo) == "{ age: { \"$ne\": 30 } }")
  }

  @Test func listOperatorsRenderArraysAndSkipEmptyLists() {
    let anyOf = FilterRule(field: "age", op: .inList, value: .array([.int32(17), .int32(42)]))
    #expect(FilterText.render([anyOf], dialect: .mongo) == "{ age: { \"$in\": [17, 42] } }")
    let noneOf = FilterRule(field: "age", op: .inList, value: .array([]))
    #expect(FilterText.render([noneOf], dialect: .mongo) == nil)
  }

  @Test func emptinessIsDialectSpecificButNullMeansEmptyForBoth() {
    let empty = FilterRule(field: "note", op: .isEmpty)
    #expect(FilterText.render([empty], dialect: .mongo) == "{ note: null }")
    #expect(FilterText.render([empty], dialect: .sql) == "{ note: null }")
    let notEmpty = FilterRule(field: "note", op: .isNotEmpty)
    #expect(FilterText.render([notEmpty], dialect: .mongo) == "{ note: { \"$ne\": null } }")
    #expect(FilterText.render([notEmpty], dialect: .sql) == "{ note: { \"$exists\": true } }")
  }

  // MARK: - Text operators (dialect-specific)

  @Test func textOperatorsUseRegexForMongo() {
    #expect(
      FilterText.render([FilterRule(field: "name", op: .contains, value: .string("ann"))],
        dialect: .mongo) == "{ name: { \"$regex\": \"ann\" } }")
    #expect(
      FilterText.render([FilterRule(field: "name", op: .startsWith, value: .string("an"))],
        dialect: .mongo) == "{ name: { \"$regex\": \"^an\" } }")
    #expect(
      FilterText.render([FilterRule(field: "name", op: .endsWith, value: .string("nn"))],
        dialect: .mongo) == "{ name: { \"$regex\": \"nn$\" } }")
    #expect(
      FilterText.render([FilterRule(field: "name", op: .notContains, value: .string("ann"))],
        dialect: .mongo) == "{ name: { \"$not\": { \"$regex\": \"ann\" } } }")
  }

  @Test func regexMetacharactersInUserTextAreEscaped() {
    // "a.c" must match a literal dot, so the pattern carries a backslash and the
    // quote text escapes it for the parser: rendered as "a\\.c".
    #expect(
      FilterText.render([FilterRule(field: "name", op: .contains, value: .string("a.c"))],
        dialect: .mongo) == #"{ name: { "$regex": "a\\.c" } }"#)
  }

  @Test func textOperatorsUseLikeOpsForSQL() {
    #expect(
      FilterText.render([FilterRule(field: "name", op: .contains, value: .string("ann"))],
        dialect: .sql) == "{ name: { \"$contains\": \"ann\" } }")
    #expect(
      FilterText.render([FilterRule(field: "name", op: .startsWith, value: .string("an"))],
        dialect: .sql) == "{ name: { \"$startsWith\": \"an\" } }")
    #expect(
      FilterText.render([FilterRule(field: "name", op: .endsWith, value: .string("nn"))],
        dialect: .sql) == "{ name: { \"$endsWith\": \"nn\" } }")
    #expect(
      FilterText.render([FilterRule(field: "name", op: .notContains, value: .string("ann"))],
        dialect: .sql) == "{ name: { \"$notContains\": \"ann\" } }")
  }

  @Test func emptyTextMatchIsDroppedButEmptyEqualityIsKept() {
    // "contains ''" would match everything -> the rule is dropped.
    #expect(
      FilterText.render([FilterRule(field: "name", op: .contains, value: .string(""))],
        dialect: .mongo) == nil)
    // "name is ''" is a precise filter -> kept.
    #expect(
      FilterText.render([FilterRule(field: "name", op: .equal, value: .string(""))],
        dialect: .mongo) == #"{ name: "" }"#)
  }

  // MARK: - Keys, ordering, combined output

  @Test func unsafeKeysAreQuotedAndEscaped() {
    #expect(
      FilterText.render([FilterRule(field: "first name", op: .equal, value: .int32(1))],
        dialect: .mongo) == #"{ "first name": 1 }"#)
    #expect(
      FilterText.render([FilterRule(field: "a\"b", op: .equal, value: .int32(1))],
        dialect: .mongo) == #"{ "a\"b": 1 }"#)
    #expect(
      FilterText.render([FilterRule(field: "address.city", op: .equal, value: .int32(1))],
        dialect: .mongo) == "{ address.city: 1 }")
  }

  @Test func rulesRenderInOrderAndAndedTogether() {
    let rules = [
      FilterRule(field: "age", op: .greaterOrEqual, value: .int32(18)),
      FilterRule(field: "name", op: .contains, value: .string("ann")),
    ]
    #expect(
      FilterText.render(rules, dialect: .sql)
        == "{ age: { \"$gte\": 18 }, name: { \"$contains\": \"ann\" } }")
  }

  @Test func noRulesAndBlankFieldsRenderNil() {
    #expect(FilterText.render([], dialect: .mongo) == nil)
    #expect(
      FilterText.render([FilterRule(field: "  ", op: .equal, value: .int32(1))], dialect: .mongo)
        == nil)
  }

  @Test func chipSummaryIsHumanReadable() {
    #expect(
      FilterRule(field: "age", op: .greaterThan, value: .int32(30)).summary
        == "age is more than 30")
    #expect(FilterRule(field: "name", op: .isEmpty).summary == "name is empty")
  }

  @Test func customFragmentIsWrittenVerbatim() {
    // What a column's "Search…" box produces: a bare value or an operator object.
    #expect(
      FilterText.render(
        [FilterRule(field: "age", op: .custom, value: .string("{ \"$gt\": 15 }"))],
        dialect: .mongo) == "{ age: { \"$gt\": 15 } }")
    #expect(
      FilterText.render([FilterRule(field: "age", op: .custom, value: .string("15"))], dialect: .sql)
        == "{ age: 15 }")
    #expect(
      FilterText.render([FilterRule(field: "age", op: .custom, value: .string("  "))],
        dialect: .mongo) == nil)
    #expect(
      FilterRule(field: "age", op: .custom, value: .string("15")).summary == "age matches 15")
  }

  @Test func customFragmentIsValidatedByTheQueryParser() throws {
    try FilterText.validate(fragment: "15", for: "age")
    try FilterText.validate(fragment: "{ $gt: 15 }", for: "age")
    try FilterText.validate(fragment: "\"ann\"", for: "name")
    try FilterText.validate(fragment: "{ $gt: 1, $lt: 9 }", for: "age")
    #expect(throws: (any Error).self) { try FilterText.validate(fragment: "gt 15", for: "age") }
  }

  // MARK: - Typed text -> BSON value (drives the value control)

  @Test func valueCoercionFollowsTheInferredKind() {
    #expect(FilterText.value(fromText: "30", kind: .number, dialect: .sql) == .int64(30))
    #expect(FilterText.value(fromText: "3.5", kind: .number, dialect: .sql) == .double(3.5))
    #expect(FilterText.value(fromText: "abc", kind: .number, dialect: .sql) == .string("abc"))
    #expect(FilterText.value(fromText: "true", kind: .boolean, dialect: .sql) == .bool(true))
    #expect(FilterText.value(fromText: "ann", kind: .string, dialect: .sql) == .string("ann"))
  }

  @Test func datesAreTypedForMongoAndPlainStringsForSQL() {
    #expect(
      FilterText.value(fromText: "2026-01-01T00:00:00Z", kind: .date, dialect: .mongo)
        == .datetime(ISO8601DateFormatter().date(from: "2026-01-01T00:00:00Z")!))
    #expect(
      FilterText.value(fromText: "2026-01-01T00:00:00Z", kind: .date, dialect: .sql)
        == .string("2026-01-01T00:00:00Z"))
  }

  // MARK: - Search everywhere (the "$or" marker chip)

  @Test func orGroupRuleRendersOneOredConditionPerField() {
    // The chip builder stores "search everywhere" as a rule on the marker field
    // "$or" whose value is the searched text.
    let rule = FilterRule(field: "$or", op: .contains, value: .array([.string("ann")]))
    #expect(
      FilterText.render([rule], dialect: .mongo, anyOfFields: ["name", "city"])
        == "{ \"$or\": [ { name: { \"$regex\": \"ann\" } }, { city: { \"$regex\": \"ann\" } } ] }")
    #expect(
      FilterText.render([rule], dialect: .sql, anyOfFields: ["name", "city"])
        == "{ \"$or\": [ { name: { \"$contains\": \"ann\" } }, { city: { \"$contains\": \"ann\" } } ] }")
  }

  @Test func markerFieldChipReadsAsAnyTextField() {
    #expect(
      FilterRule(field: "$or", op: .contains, value: .array([.string("ann")])).summary
        == "any text field contains ann")
  }

  @Test func markerRuleWithoutTargetFieldsIsDropped() {
    let rule = FilterRule(field: "$or", op: .contains, value: .array([.string("ann")]))
    #expect(FilterText.render([rule], dialect: .mongo) == nil)
  }

  @Test func markerRuleMixesWithNormalChips() {
    let rules = [
      FilterRule(field: "age", op: .greaterThan, value: .int32(30)),
      FilterRule(field: "$or", op: .contains, value: .array([.string("ann")])),
    ]
    #expect(
      FilterText.render(rules, dialect: .mongo, anyOfFields: ["name"])
        == "{ age: { \"$gt\": 30 }, \"$or\": [ { name: { \"$regex\": \"ann\" } } ] }")
  }

  // MARK: - Round trip through the query parser

  @Test func renderedTextParsesBackWithQueryParser() throws {
    let rules = [
      FilterRule(field: "age", op: .greaterOrEqual, value: .int32(18)),
      FilterRule(field: "first name", op: .equal, value: .string("ann")),
      FilterRule(field: "note", op: .isNotEmpty),
    ]
    let text = try #require(FilterText.render(rules, dialect: .mongo))
    let doc = try BSONSupport.document(fromQuery: text)
    #expect(doc["age"] == .document(["$gte": .int32(18)]))
    #expect(doc["first name"] == .string("ann"))
    #expect(doc["note"] == .document(["$ne": .null]))
  }
}
