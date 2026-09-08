import Foundation
import Testing

@testable import SQLQuery

/// Pure unit tests for the JSON -> SQL query compiler: dialect detection,
/// operator mapping, literal escaping, and error paths. No server needed.
@Suite struct SQLQueryDetectionTests {
  private func compile(filter: String? = nil, sort: String? = nil, projection: String? = nil)
    throws -> SQLQueryParts
  {
    try SQLQueryCompiler.compile(filter: filter, sort: sort, projection: projection)
  }

  @Test func strictJSONObjectCompiles() throws {
    let parts = try compile(filter: "{\"age\": {\"$gt\": 30}, \"name\": \"ann\"}")
    #expect(parts.whereBody == "\"age\" > 30 AND \"name\" = 'ann'")
  }

  @Test func jsStyleUnquotedKeysCompile() throws {
    let parts = try compile(filter: "{age: {$gt: 30}}")
    #expect(parts.whereBody == "\"age\" > 30")
  }

  @Test func barePairsCompileWithoutBraces() throws {
    let parts = try compile(filter: "age: 30, active: true")
    #expect(parts.whereBody == "\"age\" = 30 AND \"active\" = TRUE")
  }

  @Test func rawSQLFragmentPassesThrough() throws {
    let filter = "age > 30 AND name LIKE 'a%'"
    let parts = try compile(filter: filter)
    #expect(parts.whereBody == filter)
  }

  @Test func rawSQLWithCastPassesThrough() throws {
    let filter = "created_at::date = '2026-01-01'"
    let parts = try compile(filter: filter)
    #expect(parts.whereBody == filter)
  }

  @Test func rawSQLSortPassesThrough() throws {
    let sort = "age DESC, name ASC"
    let parts = try compile(sort: sort)
    #expect(parts.orderBy == sort)
  }

  @Test func bareSortPairIsJSON() throws {
    let parts = try compile(sort: "age: -1")
    #expect(parts.orderBy == "\"age\" DESC")
  }

  @Test func malformedExplicitJSONThrows() {
    #expect(throws: SQLQueryError.self) {
      _ = try compile(filter: "{age: }")
    }
  }

  @Test func emptyAndWhitespaceFieldsAreNil() throws {
    let parts = try compile(filter: "   ", sort: "  ")
    #expect(parts.whereBody == nil)
    #expect(parts.orderBy == nil)
  }

  @Test func emptyDocumentsAreNilWhere() throws {
    let parts = try compile(filter: "{}", sort: "{}")
    #expect(parts.whereBody == nil)
    #expect(parts.orderBy == nil)
  }

  @Test func emptyProjectionStaysStar() throws {
    let parts = try compile(projection: "{}")
    #expect(parts.columns == "*")
  }

  @Test func rawProjectionStaysUnapplied() throws {
    let parts = try compile(projection: "name, age")
    #expect(parts.columns == "*")
  }

  @Test func allThreeJSONFieldsCompileTogether() throws {
    let parts = try compile(
      filter: "{age: {$gte: 18}}", sort: "{age: -1, name: 1}", projection: "{name: 1}")
    #expect(parts.whereBody == "\"age\" >= 18")
    #expect(parts.orderBy == "\"age\" DESC, \"name\" ASC")
    #expect(parts.columns == "\"name\"")
  }
}

@Suite struct SQLQueryOperatorTests {
  private func whereBody(_ filter: String) throws -> String? {
    try SQLQueryCompiler.compile(filter: filter, sort: nil, projection: nil).whereBody
  }

  /// Asserts the compiler throws invalidQuery whose message contains `needle`.
  private func expectError(_ filter: String, contains needle: String) {
    do {
      _ = try whereBody(filter)
      Issue.record("expected invalidQuery for \(filter)")
    } catch let error as SQLQueryError {
      guard case .invalidQuery(let message) = error else {
        Issue.record("unexpected error \(error) for \(filter)")
        return
      }
      if !message.contains(needle) {
        Issue.record("expected \"\(needle)\" in error message for \(filter): \(message)")
      }
    } catch {
      Issue.record("unexpected error type \(error) for \(filter)")
    }
  }

  @Test func multipleComparisonOperatorsAndTogether() throws {
    #expect(try whereBody("{\"a\": {\"$gt\": 1, \"$lte\": 10}}") == "\"a\" > 1 AND \"a\" <= 10")
  }

  @Test func neRendersNotEqualTo() throws {
    #expect(try whereBody("{\"a\": {\"$ne\": 5}}") == "\"a\" <> 5")
  }

  @Test func nullEqualityBecomesIsNull() throws {
    #expect(try whereBody("{\"a\": null}") == "\"a\" IS NULL")
    #expect(try whereBody("{\"a\": {\"$eq\": null}}") == "\"a\" IS NULL")
    #expect(try whereBody("{\"a\": {\"$ne\": null}}") == "\"a\" IS NOT NULL")
  }

  @Test func inAndNinRenderLists() throws {
    #expect(try whereBody("{\"a\": {\"$in\": [1, \"x\", true]}}") == "\"a\" IN (1, 'x', TRUE)")
    #expect(try whereBody("{\"a\": {\"$nin\": [1, 2]}}") == "\"a\" NOT IN (1, 2)")
  }

  @Test func emptyInMatchesNothingAndEmptyNinEverything() throws {
    #expect(try whereBody("{\"a\": {\"$in\": []}}") == "1 = 0")
    #expect(try whereBody("{\"a\": {\"$nin\": []}}") == nil)
  }

  @Test func existsMapsToNullness() throws {
    #expect(try whereBody("{\"a\": {\"$exists\": true}}") == "\"a\" IS NOT NULL")
    #expect(try whereBody("{\"a\": {\"$exists\": false}}") == "\"a\" IS NULL")
  }

  @Test func orGroupKeepsPrecedenceAgainstAndSibling() throws {
    #expect(
      try whereBody("{\"$or\": [{\"a\": 1}, {\"b\": {\"$lt\": 5}}], \"c\": \"x\"}")
        == "( \"a\" = 1 OR \"b\" < 5 ) AND \"c\" = 'x'")
  }

  @Test func multiPartAndBranchInsideOrIsParenthesized() throws {
    #expect(
      try whereBody("{\"$or\": [{\"a\": 1, \"b\": 2}, {\"c\": 3}]}")
        == "( ( \"a\" = 1 AND \"b\" = 2 ) OR \"c\" = 3 )")
  }

  @Test func stringLiteralDoublesEmbeddedQuotes() throws {
    #expect(try whereBody("{\"name\": \"O'Brien\"}") == "\"name\" = 'O''Brien'")
  }

  @Test func identifierWithEmbeddedQuoteIsDoubled() throws {
    #expect(try whereBody("{\"we\\\"ird\": 1}") == "\"we\"\"ird\" = 1")
  }

  @Test func int64AndDoubleRenderNatively() throws {
    #expect(try whereBody("{\"n\": 2147483648}") == "\"n\" = 2147483648")
    #expect(try whereBody("{\"d\": 1.5}") == "\"d\" = 1.5")
  }

  @Test func unsupportedOperatorThrows() {
    expectError("{\"name\": {\"$regex\": \"^a\"}}", contains: "$regex")
    expectError("{\"name\": {\"$size\": 2}}", contains: "$size")
  }

  @Test func nestedObjectEqualityThrows() {
    expectError("{\"address\": {\"city\": \"x\"}}", contains: "flat")
  }

  @Test func bareArrayEqualityThrows() {
    expectError("{\"tags\": [\"a\", \"b\"]}", contains: "$in")
  }

  @Test func comparingNullWithRangeOperatorThrows() {
    expectError("{\"a\": {\"$gt\": null}}", contains: "can't compare against null")
  }

  @Test func nullInsideInThrows() {
    expectError("{\"a\": {\"$in\": [1, null]}}", contains: "no SQL equivalent")
  }
}

@Suite struct SQLQuerySortProjectionTests {
  private func orderBy(_ sort: String) throws -> String? {
    try SQLQueryCompiler.compile(filter: nil, sort: sort, projection: nil).orderBy
  }

  private func columns(_ projection: String) throws -> String {
    try SQLQueryCompiler.compile(filter: nil, sort: nil, projection: projection).columns
  }

  @Test func sortDocumentPreservesKeyOrderAndDirections() throws {
    #expect(try orderBy("{age: -1, name: 1}") == "\"age\" DESC, \"name\" ASC")
    #expect(try orderBy("{age: \"desc\", name: \"asc\"}") == "\"age\" DESC, \"name\" ASC")
  }

  @Test func badSortDirectionsThrow() {
    do {
      _ = try orderBy("{a: 2}")
      Issue.record("expected invalidQuery for sort direction 2")
    } catch let error as SQLQueryError {
      #expect(error.localizedDescription.contains("1 or -1"))
    } catch {
      Issue.record("unexpected error type")
    }
  }

  @Test func includeProjectionListsColumns() throws {
    #expect(try columns("{name: 1, age: 1}") == "\"name\", \"age\"")
    #expect(try columns("{name: true}") == "\"name\"")
  }

  @Test func exclusionProjectionThrows() {
    do {
      _ = try columns("{_id: 0}")
      Issue.record("expected invalidQuery for exclusion projection")
    } catch let error as SQLQueryError {
      #expect(error.localizedDescription.contains("exclusion"))
    } catch {
      Issue.record("unexpected error type")
    }
  }

  @Test func nonProjectionValuesThrow() {
    do {
      _ = try columns("{name: \"x\"}")
      Issue.record("expected invalidQuery for string projection value")
    } catch let error as SQLQueryError {
      #expect(error.localizedDescription.contains("1 or 0"))
    } catch {
      Issue.record("unexpected error type")
    }
  }
}
