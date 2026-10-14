import BSON
import Foundation
import MongoWire
import Testing
import WireKit

/// Needs the `mongodb` service from docker-compose.yml (27017, no auth by default).
@Suite(.serialized) struct MongoClientTests {
  static let config = MongoClient.Config(
    host: "127.0.0.1", port: Int(ProcessInfo.processInfo.environment["MONGO_PORT"] ?? "") ?? 27017)

  @Test func handshakeReportsServer() async throws {
    let client = try await MongoClient.connect(Self.config)
    #expect(await client.maxWireVersion >= 17)
    #expect(await client.isWritablePrimary)
    await client.close()
  }

  @Test func crudAggregateAndCursors() async throws {
    let client = try await MongoClient.connect(Self.config)
    defer { Task { await client.close() } }
    let db = "wiretest"
    _ = try? await client.dropCollection(database: db, collection: "reviews")
    var docs: [BSONDocument] = []
    for i in 0..<1500 {
      docs.append([
        "_id": .int32(Int32(i)), "product": .string(i % 3 == 0 ? "speaker" : "radio"),
        "rating": .int32(Int32(i % 5 + 1)), "at": .datetime(1_791_700_000_000 + Int64(i) * 60_000),
      ])
    }
    let inserted = try await client.insert(database: db, collection: "reviews", documents: docs)
    #expect(inserted == 1500)

    // More than one batch: getMore must kick in.
    let all = try await client.find(database: db, collection: "reviews", limit: 1400)
    #expect(all.count == 1400)
    let top = try await client.find(
      database: db, collection: "reviews", filter: ["rating": .document(["$gte": .int32(4)])],
      sort: ["_id": .int32(-1)], projection: ["rating": .int32(1)], limit: 3)
    #expect(top.map { $0["_id"] } == [.int32(1499), .int32(1498), .int32(1494)])
    #expect(top.first?.keys == ["_id", "rating"])

    let groups = try await client.aggregate(
      database: db, collection: "reviews",
      pipeline: [
        ["$group": .document(["_id": .string("$product"), "n": .document(["$count": .document([:])])])],
        ["$sort": .document(["_id": .int32(1)])],
      ])
    #expect(groups.map { $0["n"] } == [.int32(1000), .int32(500)])
    #expect(try await client.count(database: db, collection: "reviews", filter: ["product": .string("speaker")]) == 500)

    let (matched, modified) = try await client.update(
      database: db, collection: "reviews", filter: ["_id": .int32(1)],
      update: ["$set": .document(["rating": .int32(5)])])
    #expect(matched == 1 && modified == 1)
    #expect(try await client.delete(database: db, collection: "reviews", filter: ["product": .string("radio")], many: true) == 1000)

    let plan = try await client.explain(
      database: db, command: ["find": .string("reviews"), "filter": .document(["rating": .int32(5)])])
    #expect(plan["queryPlanner"] != nil)

    let collections = try await client.listCollections(database: db)
    #expect(collections.map(\.name).contains("reviews"))
    #expect(try await client.listDatabases().contains { $0.name == db })
    try await client.dropCollection(database: db, collection: "reviews")
  }

  @Test func errorsCarryServerCodes() async throws {
    let client = try await MongoClient.connect(Self.config)
    defer { Task { await client.close() } }
    do {
      try await client.command(["noSuchCommand": .int32(1)], database: "admin")
      Issue.record("expected an error")
    } catch let error as MongoError {
      #expect(error.code == 59)
    }
    _ = try? await client.dropCollection(database: "wiretest", collection: "dupes")
    try await client.insert(database: "wiretest", collection: "dupes", documents: [["_id": .int32(1)]])
    await #expect(throws: MongoError.self) {
      try await client.insert(database: "wiretest", collection: "dupes", documents: [["_id": .int32(1)]])
    }
  }

  @Test(arguments: [true, false]) func logsInWithSCRAM(sha256: Bool) async throws {
    let admin = try await MongoClient.connect(Self.config)
    let user = sha256 ? "wire256" : "wire1"
    _ = try? await admin.command(["dropUser": .string(user)], database: "admin")
    try await admin.command(
      [
        "createUser": .string(user), "pwd": .string("p@ss word"), "roles": .array([.string("readAnyDatabase")]),
        "mechanisms": .array([.string(sha256 ? "SCRAM-SHA-256" : "SCRAM-SHA-1")]),
      ], database: "admin")
    await admin.close()

    var config = Self.config
    config.user = user
    config.password = "p@ss word"
    let client = try await MongoClient.connect(config)
    try await client.ping()
    await client.close()

    config.password = "wrong"
    await #expect(throws: WireError.self) { try await MongoClient.connect(config) }
  }
}

@Test func concurrentCommandsOnOneConnection() async throws {
  let client = try await MongoClient.connect(MongoClientTests.config)
  try await withThrowingTaskGroup(of: Bool.self) { group in
    for i in 0..<100 {
      group.addTask {
        let reply = try await client.command(["ping": .int32(1), "comment": .string("c\(i)")], database: "admin")
        return reply["ok"]?.doubleValue == 1
      }
    }
    for try await ok in group { #expect(ok) }
  }
  await client.close()
}
