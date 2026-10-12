import BSON
import Foundation
import Testing

struct BSONTests {
  @Test func encodesAndDecodesEveryType() throws {
    let id = ObjectID("6703f1c2e4b0a91c00000001")!
    var doc = BSONDocument()
    doc.append("_id", .objectId(id))
    doc.append("name", .string("Lumen Desk Speaker"))
    doc.append("price", .double(129.0))
    doc.append("stock", .int32(12))
    doc.append("views", .int64(9_000_000_000))
    doc.append("onSale", .bool(false))
    doc.append("tags", .array([.string("desk"), .string("wireless")]))
    doc.append("specs", .document(["watts": .int32(20)]))
    doc.append("updatedAt", .datetime(1_791_700_000_000))
    doc.append("price128", .decimal128(Decimal128("12.50")!))
    doc.append("match", .regex(pattern: "^lum", options: "i"))
    doc.append("raw", .binary(subtype: 0, data: [1, 2, 3]))
    doc.append("ts", .timestamp(time: 10, increment: 2))
    doc.append("nothing", .null)
    doc.append("low", .minKey)
    let bytes = doc.encoded()
    let decoded = try BSONDocument(bytes: bytes)
    #expect(decoded == doc)
    #expect(decoded["specs"]?[path: "watts"] == .int32(20))
  }

  @Test func decimal128RoundTripsText() {
    for text in ["0", "12.50", "-1.5", "1E+3", "0.000001", "1.23E-7", "9999999999999999999999999999999999"] {
      #expect(Decimal128(text)?.description == text, "\(text)")
    }
    #expect(Decimal128("NaN")?.description == "NaN")
    #expect(Decimal128("-Infinity")?.description == "-Infinity")
    #expect(Decimal128("abc") == nil)
  }

  @Test func parsesShellSyntax() throws {
    let doc = try BSONDocument(
      parsing: """
        { _id: ObjectId('6703f1c2e4b0a91c00000001'), 'name': "Ann", age: 41, big: NumberLong(5),
          ratio: 0.5, at: ISODate("2026-10-12T10:02:00Z"), tags: ['a', "b",], re: /^an\\/n/i,
          price: NumberDecimal("12.50"), nested: { $gt: 3 }, // a comment
          id2: { "$oid": "6703f1c2e4b0a91c00000002" }, when: new Date("2026-01-01"), off: false, n: null }
        """)
    #expect(doc["_id"] == .objectId(ObjectID("6703f1c2e4b0a91c00000001")!))
    #expect(doc["name"] == .string("Ann"))
    #expect(doc["age"] == .int32(41))
    #expect(doc["big"] == .int64(5))
    #expect(doc["ratio"] == .double(0.5))
    #expect(doc["at"] == .datetime(1_791_799_320_000))
    #expect(doc["tags"] == .array([.string("a"), .string("b")]))
    #expect(doc["re"] == .regex(pattern: "^an/n", options: "i"))
    #expect(doc["price"] == .decimal128(Decimal128("12.50")!))
    #expect(doc["nested"] == .document(["$gt": .int32(3)]))
    #expect(doc["id2"] == .objectId(ObjectID("6703f1c2e4b0a91c00000002")!))
    #expect(doc["when"] == .datetime(1_767_225_600_000))
    #expect(doc["n"] == .null)
  }

  @Test func shellTextRoundTrips() throws {
    let doc: BSONDocument = [
      "_id": .objectId(ObjectID("6703f1c2e4b0a91c00000001")!), "n": .int32(1), "d": .double(2), "l": .int64(3),
      "s": .string("quote \" and\nnewline"), "when": .datetime(1_791_799_320_000),
      "dec": .decimal128(Decimal128("0.10")!), "arr": .array([.null, .bool(true)]),
      "ts": .timestamp(time: 5, increment: 6), "bin": .binary(subtype: 0, data: [255]),
    ]
    let text = doc.text(.shell, indent: 2)
    #expect(try BSONDocument(parsing: text) == doc)
    let ejson = doc.text(.extendedJSON)
    #expect(try BSONDocument(parsing: ejson) == doc)
    #expect(doc.text().hasPrefix("{ _id: ObjectId(\"6703f1c2e4b0a91c00000001\"), n: 1, d: 2.0, l: NumberLong(3)"))
  }

  @Test func reportsWhereParsingFailed() {
    #expect(throws: BSONError.self) { try BSONDocument(parsing: "{ a: }") }
    #expect(throws: BSONError.self) { try BSONDocument(parsing: "{ a: Foo(1) }") }
    #expect(throws: BSONError.self) { try BSONDocument(parsing: "[1, 2]") }
  }

  @Test func setsNestedPaths() {
    var doc: BSONDocument = ["a": .document(["b": .int32(1)]), "list": .array([.document(["x": .int32(1)])])]
    doc.set(path: "a.b", to: .int32(2))
    doc.set(path: "a.c.d", to: .string("new"))
    doc.set(path: "list.0.x", to: .int32(9))
    #expect(doc["a"]?[path: "b"] == .int32(2))
    #expect(doc["a"]?[path: "c.d"] == .string("new"))
    #expect(BSON.document(doc)[path: "list.0.x"] == .int32(9))
  }
}
