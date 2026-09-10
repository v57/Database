import Foundation
import Testing

@testable import MongoDB

/// Pure unit tests for the text models behind the column UI: the Sort field is
/// parsed into ordered keys that drive header arrows and clicks, and the
/// Projection field is parsed into hidden columns. Both directions (parse and
/// render) are dialect-aware, and BOTH spellings parse on every engine.
@Suite struct SortTextParsingTests {
  @Test func mongoDocumentSpellingParsesInOrder() {
    let keys = SortText.parse("{ name: 1, value: -1 }")
    #expect(keys == [
      SortKey(field: "name", ascending: true),
      SortKey(field: "value", ascending: false),
    ])
  }

  @Test func sqlSpellingParsesAndIgnoresCommas() {
    #expect(SortText.parse("name ASC, value DESC") == [
      SortKey(field: "name", ascending: true),
      SortKey(field: "value", ascending: false),
    ])
  }

  @Test func bareKeyIsAscending() {
    #expect(SortText.parse("name") == [SortKey(field: "name", ascending: true)])
  }

  @Test func directionWordsAndQuotedKeys() {
    #expect(SortText.parse("{ \"first name\": \"desc\" }") == [
      SortKey(field: "first name", ascending: false)
    ])
    #expect(SortText.parse("\"first name\" DESC") == [
      SortKey(field: "first name", ascending: false)
    ])
  }

  @Test func garbageIsIgnoredInsteadOfCrashingTheColumnUI() {
    // The query bar reports execution errors; the column UI must not throw.
    #expect(SortText.parse("{ name: : }") == [])
    #expect(SortText.parse("") == [])
    #expect(SortText.parse("   ") == [])
  }
}

/// Rendering + the click/cycle behaviour that the table header uses.
@Suite struct SortTextRenderingTests {
  @Test func mongoRendersDocumentSpellingAndSQLRendersOrderBy() {
    let keys = [
      SortKey(field: "name", ascending: true),
      SortKey(field: "value", ascending: false),
    ]
    #expect(SortText.render(keys, dialect: .mongo) == "{ name: 1, value: -1 }")
    #expect(SortText.render(keys, dialect: .sql) == "name ASC, value DESC")
    #expect(SortText.render([], dialect: .mongo) == nil)
    #expect(SortText.render([], dialect: .sql) == nil)
  }

  @Test func clickingAColumnCyclesNoneAscendingDescendingNone() {
    var keys: [SortKey] = []
    keys = SortText.cycle("age", in: keys).keys
    #expect(SortText.render(keys, dialect: .mongo) == "{ age: 1 }")
    keys = SortText.cycle("age", in: keys).keys
    #expect(SortText.render(keys, dialect: .mongo) == "{ age: -1 }")
    keys = SortText.cycle("age", in: keys).keys
    #expect(keys.isEmpty)
  }

  @Test func clickingASecondColumnAppendsToTheExistingSort() {
    // The user's example: clicking name then value gives { name: 1, value: 1 }.
    var keys = SortText.cycle("name", in: []).keys
    keys = SortText.cycle("value", in: keys).keys
    #expect(SortText.render(keys, dialect: .mongo) == "{ name: 1, value: 1 }")
    #expect(SortText.render(keys, dialect: .sql) == "name ASC, value ASC")
    // Cycling value again flips only value, in place.
    keys = SortText.cycle("value", in: keys).keys
    #expect(SortText.render(keys, dialect: .mongo) == "{ name: 1, value: -1 }")
  }

  @Test func cycleReportsTheDirectionForTheHeaderArrow() {
    let first = SortText.cycle("age", in: [])
    #expect(first.direction("age") == .ascending)
    let second = SortText.cycle("age", in: first.keys)
    #expect(second.direction("age") == .descending)
    let third = SortText.cycle("age", in: second.keys)
    #expect(third.direction("age") == nil)
  }

  @Test func explicitDirectionsAndRemoval() {
    var keys = SortText.set("age", direction: .descending, in: [])
    #expect(SortText.render(keys, dialect: .mongo) == "{ age: -1 }")
    keys = SortText.set("name", direction: .ascending, in: keys)
    #expect(SortText.render(keys, dialect: .mongo) == "{ age: -1, name: 1 }")
    keys = SortText.remove("age", from: keys)
    #expect(SortText.render(keys, dialect: .mongo) == "{ name: 1 }")
    #expect(SortText.direction(of: "age", in: keys) == nil)
  }
}

/// Projection text: which columns are hidden, and how hiding is spelled per
/// dialect (Mongo exclusions, SQL include-lists because `0` is rejected there).
@Suite struct ProjectionTextTests {
  private let allFields = ["_id", "name", "age", "note"]

  @Test func mongoParsesAndRendersExclusions() {
    #expect(ProjectionText.hidden(in: "{ note: 0 }", allFields: allFields, dialect: .mongo)
      == ["note"])
    #expect(ProjectionText.hidden(in: "{ note: 0, score: 0 }", allFields: allFields,
      dialect: .mongo) == ["note", "score"])
    #expect(ProjectionText.render(hidden: ["note"], allFields: allFields, dialect: .mongo)
      == "{ note: 0 }")
  }

  @Test func sqlParsesAndRendersIncludeLists() {
    #expect(ProjectionText.hidden(in: "{ _id: 1, name: 1 }", allFields: allFields, dialect: .sql)
      == ["age", "note"])
    #expect(ProjectionText.hidden(in: "id, name", allFields: allFields, dialect: .sql)
      == ["_id", "age", "note"])
    #expect(ProjectionText.render(hidden: ["note"], allFields: allFields, dialect: .sql)
      == "{ _id: 1, name: 1, age: 1 }")
  }

  @Test func hidingInMongoAppendsAnExclusion() {
    // `render` follows the field universe of the loaded rows, so a second hide
    // only renders when the field is part of it — hence a fixture with `score`.
    let fields = ["_id", "name", "age", "note", "score"]
    #expect(ProjectionText.hide("note", in: "", allFields: fields, dialect: .mongo)
      == "{ note: 0 }")
    #expect(ProjectionText.hide("score", in: "{ note: 0 }", allFields: fields, dialect: .mongo)
      == "{ note: 0, score: 0 }")
  }

  @Test func hidingInSQLKeepsOnlyTheOtherFields() {
    #expect(ProjectionText.hide("note", in: "", allFields: allFields, dialect: .sql)
      == "{ _id: 1, name: 1, age: 1 }")
    // Removing a field from an include list re-adds it to the visible set.
    #expect(ProjectionText.hide("age", in: "{ _id: 1, name: 1 }", allFields: allFields,
      dialect: .sql) == "{ _id: 1, name: 1 }")
  }

  @Test func showAndShowAllAreDialectSymmetric() {
    #expect(ProjectionText.show("note", in: "{ note: 0 }", allFields: allFields, dialect: .mongo)
      == nil)
    #expect(ProjectionText.show("age", in: "{ _id: 1, name: 1 }", allFields: allFields,
      dialect: .sql) == "{ _id: 1, name: 1, age: 1 }")
    #expect(ProjectionText.showAll == nil)
  }
}
