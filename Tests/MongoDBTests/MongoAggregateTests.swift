import Foundation
import Testing

@testable import MongoDB

/// `MongoConnection.aggregate` against the local server, fed by pipelines
/// imported from JavaScript the way the aggregation builder does it.
@Suite(.serialized) struct MongoAggregateTests {
  private static let orders: [Document] = [
    ["customer": "ann", "amount": 10, "status": "A"],
    ["customer": "ann", "amount": 30, "status": "A"],
    ["customer": "bob", "amount": 5, "status": "A"],
    ["customer": "bob", "amount": 50, "status": "B"],
    ["customer": "cyd", "amount": 7, "status": "A"],
  ]

  private func run(_ script: String, label: String) async throws -> [Document] {
    let db = TestEnv.freshDBName(label)
    try await TestEnv.seed(database: db, collection: "orders", docs: Self.orders)
    defer { try? await TestEnv.drop(database: db) }
    let conn = try await TestEnv.makeConnection()
    defer { await conn.disconnect() }
    try await conn.use(database: db)
    let stages = try AggregationPipeline.documents(AggregationPipeline.importJavaScript(script).stages)
    return try await conn.aggregate(in: "orders", pipeline: stages)
  }

  @Test func groupSortLimitFromJavaScript() async throws {
    let results = try await run(
      #"""
      db.orders.aggregate([
        { $match: { status: "A" } },
        { $group: { _id: "$customer", total: { $sum: "$amount" } } },
        { $sort: { total: -1 } },
        { $limit: 2 }
      ])
      """#, label: "agg_group")
    #expect(results.map { $0["_id"] } == [.string("ann"), .string("cyd")])
    #expect(results.map { $0["total"] } == [.int64(40), .int64(7)])
  }

  @Test func shellHelpersReachTheServer() async throws {
    // A regex literal and a type helper must arrive as real BSON values.
    let results = try await run(
      #"""
      [
        { $match: { customer: /^b/i, amount: { $gte: NumberInt(10) } } },
        { $project: { _id: 0, customer: 1, amount: 1 } }
      ]
      """#, label: "agg_regex")
    #expect(results == [["customer": "bob", "amount": 50]])
  }

  @Test func emptyPipelineReturnsEverythingAndLimitStops() async throws {
    let db = TestEnv.freshDBName("agg_empty")
    try await TestEnv.seed(database: db, collection: "orders", docs: Self.orders)
    defer { try? await TestEnv.drop(database: db) }
    let conn = try await TestEnv.makeConnection()
    defer { await conn.disconnect() }
    try await conn.use(database: db)
    #expect(try await conn.aggregate(in: "orders", pipeline: []).count == 5)
    #expect(try await conn.aggregate(in: "orders", pipeline: [], limit: 2).count == 2)
  }

  @Test func serverErrorsSurface() async throws {
    await #expect(throws: MongoDBError.self) {
      _ = try await run(#"[{ $group: { total: { $sum: 1 } } }]"#, label: "agg_error")
    }
  }
}
