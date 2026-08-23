import Foundation
import MongoSwift
import Testing

@testable import MongoDB

@Suite(.serialized) struct MongoConnectionTests {
  // serialized only to keep seed/drop churn on the same server quiet; each test
  // still uses its own database name.

  @Test func connectPingAndListDatabases() async throws {
    let conn = MongoConnection(config: TestEnv.config())
    defer { try? await conn.disconnect() }
    try await conn.connect()
    #expect(conn.isConnected)
    let dbs = try await conn.listDatabases()
    #expect(dbs.contains("admin"))
  }

  @Test func listCollectionsAndSearch() async throws {
    let db = TestEnv.freshDBName("colls")
    try await TestEnv.seed(database: db, collection: "users", docs: [["n": 1]])
    try await TestEnv.seed(database: db, collection: "orders", docs: [["n": 1]])
    try await TestEnv.seed(database: db, collection: "products", docs: [["n": 1]])
    defer { try? await TestEnv.drop(database: db) }

    let conn = MongoConnection(config: TestEnv.config())
    defer { try? await conn.disconnect() }
    try await conn.connect()
    try await conn.use(database: db)

    let all = try await conn.listCollections()
    #expect(Set(all) == Set(["users", "orders", "products"]))

    let us = try await conn.listCollections(matching: "us")
    #expect(us == ["users"])
    let caseInsensitive = try await conn.listCollections(matching: "ORD")
    #expect(caseInsensitive == ["orders"])
    let none = try await conn.listCollections(matching: "zzz")
    #expect(none.isEmpty)
  }

  @Test func findReturnsMatchingDocuments() async throws {
    let db = TestEnv.freshDBName("find")
    let docs: [Document] = [
      ["name": "ann", "age": 20], ["name": "bob", "age": 30], ["name": "cat", "age": 40],
    ]
    try await TestEnv.seed(database: db, collection: "people", docs: docs)
    defer { try? await TestEnv.drop(database: db) }

    let conn = MongoConnection(config: TestEnv.config())
    defer { try? await conn.disconnect() }
    try await conn.connect()
    try await conn.use(database: db)

    let all = try await conn.find(in: "people")
    #expect(all.count == 3)

    let filter: Document = ["age": ["$gte": 30]]
    let adults = try await conn.find(in: "people", filter: filter)
    #expect(adults.count == 2)

    let limited = try await conn.find(in: "people", filter: filter, limit: 1)
    #expect(limited.count == 1)

    let missing = try await conn.find(in: "does_not_exist")
    #expect(missing.isEmpty)
  }

  @Test func findWithSortAndProjection() async throws {
    let db = TestEnv.freshDBName("sortproj")
    let docs: [Document] = [
      ["name": "ann", "age": 20], ["name": "bob", "age": 30], ["name": "cat", "age": 40],
    ]
    try await TestEnv.seed(database: db, collection: "people", docs: docs)
    defer { try? await TestEnv.drop(database: db) }

    let conn = MongoConnection(config: TestEnv.config())
    defer { try? await conn.disconnect() }
    try await conn.connect()
    try await conn.use(database: db)

    let descending = try await conn.find(in: "people", sort: ["age": -1], projection: ["name": 1])
    #expect(descending.map { $0["name"] } == [.string("cat"), .string("bob"), .string("ann")])
    // Projection keeps only `name` (+ _id); `age` is dropped.
    #expect(descending.allSatisfy { $0["age"] == nil })
    #expect(descending.first?["name"] == .string("cat"))
  }

  @Test func updateManyUpdatesMatchingDocuments() async throws {
    let db = TestEnv.freshDBName("upd")
    let docs: [Document] = [
      ["name": "ann", "age": 20], ["name": "bob", "age": 30], ["name": "cat", "age": 40],
    ]
    try await TestEnv.seed(database: db, collection: "people", docs: docs)
    defer { try? await TestEnv.drop(database: db) }

    let conn = MongoConnection(config: TestEnv.config())
    defer { try? await conn.disconnect() }
    try await conn.connect()
    try await conn.use(database: db)

    let filter: Document = ["age": ["$lt": 35]]
    let update: Document = ["$set": ["bucket": "young"]]
    let result = try await conn.updateMany(in: "people", filter: filter, update: update)
    #expect(result.matchedCount == 2)
    #expect(result.modifiedCount == 2)

    let changed = try await conn.find(in: "people", filter: ["bucket": "young"])
    #expect(changed.count == 2)
  }

  @Test func deleteManyDeletesMatchingDocuments() async throws {
    let db = TestEnv.freshDBName("del")
    let docs: [Document] = [
      ["name": "ann", "age": 20], ["name": "bob", "age": 30], ["name": "cat", "age": 40],
    ]
    try await TestEnv.seed(database: db, collection: "people", docs: docs)
    defer { try? await TestEnv.drop(database: db) }

    let conn = MongoConnection(config: TestEnv.config())
    defer { try? await conn.disconnect() }
    try await conn.connect()
    try await conn.use(database: db)

    let filter: Document = ["age": ["$lt": 35]]
    let result = try await conn.deleteMany(from: "people", filter: filter)
    #expect(result.deletedCount == 2)

    let remaining = try await conn.find(in: "people")
    #expect(remaining.count == 1)
  }
}
