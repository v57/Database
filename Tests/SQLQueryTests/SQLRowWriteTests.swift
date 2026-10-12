import Foundation
import MongoDB
import Testing

@testable import SQLQuery

/// Pure unit tests for the record editor's single-row statements.
@Suite struct SQLRowWriteTests {
  @Test func updateAddressesTheRowByItsKey() throws {
    let sql = try SQLRowWrite.update(
      "\"people\"", set: ["name": .string("O'Hara"), "active": .bool(true), "note": .null],
      key: ["id": .int64(7)], flavor: .sqlite)
    #expect(sql == "UPDATE \"people\" SET \"name\" = 'O''Hara', \"active\" = 1, \"note\" = NULL WHERE \"id\" = 7")
  }

  @Test func compositeAndNullKeys() throws {
    let sql = try SQLRowWrite.delete(
      from: "\"s\".\"t\"", key: ["a": .string("x"), "b": .null], flavor: .postgresql)
    #expect(sql == "DELETE FROM \"s\".\"t\" WHERE \"a\" = 'x' AND \"b\" IS NULL")
  }

  @Test func emptyKeyOrChangesAreRefused() {
    #expect(throws: SQLQueryError.self) {
      try SQLRowWrite.delete(from: "\"t\"", key: [:], flavor: .sqlite)
    }
    #expect(throws: SQLQueryError.self) {
      try SQLRowWrite.update("\"t\"", set: [:], key: ["id": .int64(1)], flavor: .sqlite)
    }
  }

  @Test func insertKeepsColumnOrder() throws {
    let sql = try SQLRowWrite.insert(
      into: "\"t\"", values: ["title": .string("Up"), "year": .int32(2009), "rating": .double(8.3)],
      flavor: .postgresql)
    #expect(sql == "INSERT INTO \"t\" (\"title\", \"year\", \"rating\") VALUES ('Up', 2009, 8.3)")
    #expect(try SQLRowWrite.insert(into: "\"t\"", values: [:], flavor: .sqlite)
      == "INSERT INTO \"t\" DEFAULT VALUES")
  }

  @Test func literalsPerFlavor() throws {
    #expect(try SQLRowWrite.literal(.bool(false), flavor: .postgresql) == "FALSE")
    #expect(try SQLRowWrite.literal(.bool(false), flavor: .sqlite) == "0")
    let date = Date(timeIntervalSince1970: 0)
    #expect(try SQLRowWrite.literal(.datetime(date), flavor: .postgresql) == "'1970-01-01T00:00:00.000Z'")
    let bytes = try BSONBinary(data: Data([0xde, 0xad]), subtype: .generic)
    #expect(try SQLRowWrite.literal(.binary(bytes), flavor: .sqlite) == "X'dead'")
    #expect(try SQLRowWrite.literal(.binary(bytes), flavor: .postgresql) == "'\\xdead'")
  }
}
