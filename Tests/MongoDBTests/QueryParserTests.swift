import Foundation
import MongoSwift
import Testing

@testable import MongoDB

/// Unit tests for the tolerant query parser (no server required).
/// Covers the three accepted forms: strict JSON, JS-style unquoted keys,
/// and bare `key: value` pairs without braces.
@Suite struct QueryParserTests {

  // MARK: - The three forms

  @Test func strictJSON() throws {
    let doc = try QueryParser.parse(#"{ "user": "some" }"#)
    #expect(doc["user"] == .string("some"))
  }

  @Test func jsStyleUnquotedKeys() throws {
    let doc = try QueryParser.parse(#"{ user: "some", age: 30 }"#)
    #expect(doc["user"] == .string("some"))
    #expect(doc["age"] == .int32(30))
  }

  @Test func barePairsWithoutBraces() throws {
    let doc = try QueryParser.parse(#"user: "some""#)
    #expect(doc["user"] == .string("some"))
  }

  @Test func multipleBarePairs() throws {
    let doc = try QueryParser.parse(#"user: "some", age: 30"#)
    #expect(doc["user"] == .string("some"))
    #expect(doc["age"] == .int32(30))
  }

  @Test func singleQuotedStrings() throws {
    let doc = try QueryParser.parse("{ user: 'some', 'name': \"ann\" }")
    #expect(doc["user"] == .string("some"))
    #expect(doc["name"] == .string("ann"))
  }

  // MARK: - Values

  @Test func nestedObjects() throws {
    let doc = try QueryParser.parse(#"{ address: { city: "NYC", zip: 10001 } }"#)
    #expect(doc["address"] == .document(["city": "NYC", "zip": .int32(10001)]))
  }

  @Test func arrays() throws {
    let doc = try QueryParser.parse(#"{ tags: [1, "a", true], empty: [] }"#)
    #expect(doc["tags"] == .array([.int32(1), .string("a"), .bool(true)]))
    #expect(doc["empty"] == .array([]))
  }

  @Test func numberResolutionMatchesDriver() throws {
    let doc = try QueryParser.parse(#"{ a: 20, b: 2147483648, c: -1.5, d: 1e3, e: 0.25 }"#)
    #expect(doc["a"] == .int32(20))  // small ints -> int32, like the driver's extJSON decoder
    #expect(doc["b"] == .int64(2_147_483_648))  // > Int32.max -> int64
    #expect(doc["c"] == .double(-1.5))
    #expect(doc["d"] == .double(1000.0))
    #expect(doc["e"] == .double(0.25))
  }

  @Test func booleansAndNull() throws {
    let doc = try QueryParser.parse("{ active: true, archived: false, deleted: null }")
    #expect(doc["active"] == .bool(true))
    #expect(doc["archived"] == .bool(false))
    #expect(doc["deleted"] == .null)
  }

  @Test func stringEscapes() throws {
    let doc = try QueryParser.parse(#"{ s: "a\nb\t\"c\"\\d\u0041" }"#)
    #expect(doc["s"] == .string("a\nb\t\"c\"\\dA"))
  }

  // MARK: - Query operators and dotted keys

  @Test func operatorDocuments() throws {
    let doc = try QueryParser.parse("{ $or: [ { age: 30 }, { age: 40 } ], $gt: 5 }")
    #expect(doc["$or"] == .array([.document(["age": .int32(30)]), .document(["age": .int32(40)])]))
    #expect(doc["$gt"] == .int32(5))
  }

  @Test func dottedKeys() throws {
    let quoted = try QueryParser.parse(#"{ "address.city": "NYC" }"#)
    #expect(quoted["address.city"] == .string("NYC"))
    let bare = try QueryParser.parse("{ address.city: \"NYC\" }")
    #expect(bare["address.city"] == .string("NYC"))
  }

  @Test func trailingCommas() throws {
    let doc = try QueryParser.parse("{ a: 1, b: [2, 3,], }")
    #expect(doc["a"] == .int32(1))
    #expect(doc["b"] == .array([.int32(2), .int32(3)]))
  }

  // MARK: - Strict-JSON parity

  @Test func strictJSONMatchesDocumentFromJSON() throws {
    let json = #"{ "user": "some", "age": 20, "tags": ["a", "b"] }"#
    let parsed = try QueryParser.parse(json)
    let strict = try Document(fromJSON: json)
    for key in ["user", "age", "tags"] { #expect(parsed[key] == strict[key]) }
  }

  // MARK: - Errors

  @Test func emptyQueryThrows() {
    #expect(throws: MongoDBError.self) { _ = try QueryParser.parse("   ") }
  }

  @Test func topLevelArrayThrows() {
    #expect(throws: MongoDBError.self) { _ = try QueryParser.parse("[1, 2]") }
  }

  @Test func missingColonThrows() {
    #expect(throws: MongoDBError.self) { _ = try QueryParser.parse(#"user "some""#) }
  }

  @Test func missingValueThrows() {
    #expect(throws: MongoDBError.self) { _ = try QueryParser.parse("{ user: }") }
  }

  @Test func unquotedStringValueThrows() {
    #expect(throws: MongoDBError.self) { _ = try QueryParser.parse("user: some") }
  }

  @Test func unterminatedStringThrows() {
    #expect(throws: MongoDBError.self) { _ = try QueryParser.parse(#"{ s: "oops }"#) }
  }

  @Test func trailingContentThrows() {
    #expect(throws: MongoDBError.self) { _ = try QueryParser.parse("{ a: 1 } x") }
  }

  @Test func errorMessageHasColumn() throws {
    do {
      _ = try QueryParser.parse("{ user: }")
      Issue.record("expected throw")
    } catch let error as MongoDBError {
      if case .invalidQuery(let message) = error {
        #expect(message.contains("column"))
      } else {
        Issue.record("unexpected error kind: \(error)")
      }
    }
  }

  // MARK: - BSONSupport entry point

  @Test func bsonSupportEntryPoint() throws {
    let doc = try BSONSupport.document(fromQuery: #"user: "some""#)
    #expect(doc["user"] == .string("some"))
  }
}
