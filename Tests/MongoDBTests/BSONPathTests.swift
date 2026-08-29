import Foundation
import Testing

@testable import MongoDB

/// Unit tests for BSONPath read/write and BSONSupport.displayString.
/// Pure — no server required.
@Suite struct BSONPathTests {

  // MARK: - Reading

  @Test func readsTopLevelKey() throws {
    let doc: Document = ["user": "ann", "age": 30]
    #expect(BSONPath.value(at: [.key("user")], in: doc) == .string("ann"))
    // Document literals resolve integers to .int64 (BSON literal conformance)
    #expect(BSONPath.value(at: [.key("age")], in: doc) == .int64(30))
  }

  @Test func readsNestedKeyAndArrayIndex() throws {
    let doc: Document = ["address": ["city": "NYC", "zip": 10001], "tags": ["a", "b"]]
    #expect(BSONPath.value(at: [.key("address"), .key("city")], in: doc) == .string("NYC"))
    #expect(BSONPath.value(at: [.key("tags"), .index(1)], in: doc) == .string("b"))
  }

  @Test func missingPathReturnsNil() throws {
    let doc: Document = ["address": ["city": "NYC"]]
    #expect(BSONPath.value(at: [.key("nope")], in: doc) == nil)
    #expect(BSONPath.value(at: [.key("address"), .key("zip")], in: doc) == nil)
    #expect(BSONPath.value(at: [.key("tags"), .index(0)], in: doc) == nil)
    #expect(BSONPath.value(at: [], in: doc) == nil)
    #expect(BSONPath.value(at: [.index(0)], in: doc) == nil)
  }

  // MARK: - Writing

  @Test func setsTopLevelValue() throws {
    let doc: Document = ["user": "ann"]
    let updated = BSONPath.setting(.string("bob"), at: [.key("user")], in: doc)
    #expect(updated["user"] == .string("bob"))
    #expect(doc["user"] == .string("ann"))  // original untouched (value semantics)
  }

  @Test func setsNestedValue() throws {
    let doc: Document = ["address": ["city": "NYC", "zip": 10001]]
    let updated = BSONPath.setting(.int32(90001), at: [.key("address"), .key("zip")], in: doc)
    #expect(updated["address"] == .document(["city": "NYC", "zip": .int32(90001)]))
  }

  @Test func setsArrayElement() throws {
    let doc: Document = ["tags": ["a", "b"]]
    let updated = BSONPath.setting(.string("c"), at: [.key("tags"), .index(1)], in: doc)
    #expect(updated["tags"] == .array([.string("a"), .string("c")]))
  }

  @Test func nilDeletesKey() throws {
    let doc: Document = ["user": "ann", "age": 30]
    let updated = BSONPath.setting(nil, at: [.key("age")], in: doc)
    #expect(updated["user"] == .string("ann"))
    #expect(updated["age"] == nil)
  }

  @Test func settingMissingPathIsNoOp() throws {
    let doc: Document = ["a": 1]
    let updated = BSONPath.setting(.string("x"), at: [.key("b"), .key("c")], in: doc)
    #expect(updated == doc)
  }

  // MARK: - Display

  @Test func displayStringFormatsTypes() throws {
    #expect(BSONSupport.displayString(.string("hi")) == "hi")
    #expect(BSONSupport.displayString(.int32(42)) == "42")
    #expect(BSONSupport.displayString(.int64(9_000_000_000)) == "9000000000")
    #expect(BSONSupport.displayString(.double(-1.5)) == "-1.5")
    #expect(BSONSupport.displayString(.bool(true)) == "true")
    #expect(BSONSupport.displayString(.null) == "null")
    #expect(
      BSONSupport.displayString(.objectID(try BSONObjectID("507f1f77bcf86cd799439011")))
        == "507f1f77bcf86cd799439011")
  }

  @Test func displayStringFormatsDate() throws {
    let date = Date(timeIntervalSince1970: 1_700_000_000)
    let s = BSONSupport.displayString(.datetime(date))
    #expect(s.hasPrefix("2023-11-14T22:13:20"))
  }

  @Test func displayStringContainersAreEmpty() throws {
    let doc: Document = ["a": 1]
    #expect(BSONSupport.displayString(.document(doc)) == "")
    #expect(BSONSupport.displayString(.array([.int32(1)])) == "")
  }
}
