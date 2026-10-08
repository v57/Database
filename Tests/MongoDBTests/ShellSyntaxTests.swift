import Foundation
import Testing

@testable import MongoDB

/// mongosh syntax in the tolerant parser and its inverse, `ShellSyntax.render`.
/// Pure: no server needed.
@Suite struct ShellSyntaxParsingTests {
  @Test func typeHelpersParse() throws {
    let doc = try QueryParser.parse(
      #"""
      {
        _id: ObjectId("64b7f0c2a1b2c3d4e5f60718"),
        at: ISODate("2024-03-01T10:00:00Z"),
        day: new Date("2024-03-01"),
        n: NumberInt(5), big: NumberLong("9007199254740993"),
        price: NumberDecimal("19.99"),
        id: UUID("0f8fad5b-d9cb-469f-a165-70867728950e")
      }
      """#)
    #expect(doc["_id"] == .objectID(try BSONObjectID("64b7f0c2a1b2c3d4e5f60718")))
    #expect(doc["at"] == .datetime(Date(timeIntervalSince1970: 1_709_287_200)))
    #expect(doc["day"] == .datetime(Date(timeIntervalSince1970: 1_709_251_200)))
    #expect(doc["n"] == .int32(5))
    #expect(doc["big"] == .int64(9_007_199_254_740_993))
    #expect(doc["price"].map { "\($0)" } != nil)
    if case .decimal128(let price)? = doc["price"] { #expect(price.description == "19.99") } else {
      Issue.record("price is not a decimal")
    }
    if case .binary(let id)? = doc["id"] {
      #expect(id.subtype == .uuid)
      #expect(id.data.count == 16)
    } else {
      Issue.record("id is not a UUID")
    }
  }

  @Test func commentsAreSkipped() throws {
    let doc = try QueryParser.parse(
      """
      {
        // who
        name: "ann", /* how old */ age: 30
      }
      """)
    #expect(doc == ["name": "ann", "age": .int32(30)])
  }

  @Test func regexLiterals() throws {
    let doc = try QueryParser.parse(#"{ name: /^an+\/x[/]/i }"#)
    #expect(doc["name"] == .regex(BSONRegularExpression(pattern: #"^an+/x[/]"#, options: "i")))
  }

  @Test func specialNumbersAndKeys() throws {
    let doc = try QueryParser.parse("{ a: NaN, b: -Infinity, c: undefined, d: MinKey, e: MaxKey() }")
    if case .double(let a)? = doc["a"] { #expect(a.isNaN) } else { Issue.record("NaN") }
    #expect(doc["b"] == .double(-.infinity))
    #expect(doc["c"] == .undefined)
    #expect(doc["d"] == .minKey)
    #expect(doc["e"] == .maxKey)
  }

  @Test func unknownFunctionAndBadArgumentsThrow() {
    #expect(throws: MongoDBError.self) { _ = try QueryParser.parse(#"{ a: Foo("x") }"#) }
    #expect(throws: MongoDBError.self) { _ = try QueryParser.parse(#"{ a: ObjectId("nope") }"#) }
    #expect(throws: MongoDBError.self) { _ = try QueryParser.parse(#"{ a: ISODate("soon") }"#) }
  }

  @Test func bareWordsStillNeedQuotes() {
    #expect(throws: MongoDBError.self) { _ = try QueryParser.parse("user: some") }
  }

  @Test func parseValueAcceptsScalarsAndBarePairs() throws {
    #expect(try QueryParser.parseValue("10") == .int32(10))
    #expect(try QueryParser.parseValue(#""$city""#) == .string("$city"))
    #expect(try QueryParser.parseValue("[1, 2]") == .array([.int32(1), .int32(2)]))
    #expect(try QueryParser.parseValue(#"status: "A""#) == .document(["status": "A"]))
    #expect(throws: MongoDBError.self) { _ = try QueryParser.parseValue("{ a: }") }
    #expect(throws: MongoDBError.self) { _ = try QueryParser.parseValue("10 20") }
  }
}

@Suite struct ShellSyntaxRenderTests {
  @Test func rendersShellSpellings() throws {
    let value: BSON = .document([
      "_id": .objectID(try BSONObjectID("64b7f0c2a1b2c3d4e5f60718")),
      "at": .datetime(Date(timeIntervalSince1970: 1_709_287_200)),
      "re": .regex(BSONRegularExpression(pattern: "a/b", options: "i")),
      "first name": "ann",
    ])
    #expect(
      ShellSyntax.inline(value)
        == #"{ _id: ObjectId("64b7f0c2a1b2c3d4e5f60718"), at: ISODate("2024-03-01T10:00:00.000Z"), re: /a\/b/i, "first name": "ann" }"#
    )
  }

  @Test func shortContainersStayOnOneLine() {
    #expect(ShellSyntax.render(["count": ["$sum": 1]]) == "{ count: { $sum: 1 } }")
    #expect(ShellSyntax.render(.document([:])) == "{}")
  }

  @Test func longContainersBreakWithIndent() {
    let group: BSON = [
      "_id": "$customer.address.city",
      "total": ["$sum": "$order.amount.value"],
      "orders": ["$sum": 1],
    ]
    #expect(
      ShellSyntax.render(group) == """
        {
          _id: "$customer.address.city",
          total: { $sum: "$order.amount.value" },
          orders: { $sum: 1 }
        }
        """)
  }

  @Test func roundTripsThroughTheParser() throws {
    let original: BSON = .document([
      "id": .objectID(BSONObjectID()),
      "when": .datetime(Date(timeIntervalSince1970: 1_700_000_000.25)),
      "price": .decimal128(try Decimal128(string: "-0.001")),
      "big": .int64(9_007_199_254_740_993),
      "ratio": .double(2.5),
      "flags": .array([.bool(true), .null, .minKey]),
      "pattern": .regex(BSONRegularExpression(pattern: #"^a\d+/"#, options: "im")),
      "uuid": .binary(BSONBinary(data: Data((0..<16).map(UInt8.init)), subtype: .uuid)),
      "blob": .binary(BSONBinary(data: Data([1, 2, 3]), subtype: .generic)),
      "dotted.key": "x",
    ])
    let text = ShellSyntax.render(original)
    #expect(try QueryParser.parseValue(text) == original)
  }

  @Test func decimal128ParsesAndPrints() throws {
    for text in ["19.99", "-0.001", "0", "1000", "123456789012345678901234567890.1234"] {
      #expect(try Decimal128(string: text).description == text)
    }
    #expect(try Decimal128(string: "1.5E+3").description == "1500")
    #expect(try Decimal128(string: "NaN").description == "NaN")
    #expect(try Decimal128(string: "-Infinity").description == "-Infinity")
    #expect(throws: BSONError.self) { _ = try Decimal128(string: "12a") }
  }
}
