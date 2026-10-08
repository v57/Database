import Foundation
import MongoDB
import SQLQuery
import Testing

@testable import SQLite

/// End-to-end: aggregation pipelines compiled by SQLPipelineCompiler must run
/// as real SQL against a real SQLite file. Each test owns its own temp file.
@Suite struct PipelineEndToEndTests {
  /// Orders: ann 10 + 30 (A), bob 5 (A), bob 50 (B), cyd 7 (A).
  private static let seedSQL = """
    CREATE TABLE orders (id INTEGER PRIMARY KEY, customer TEXT, amount INTEGER, status TEXT);
    INSERT INTO orders VALUES (1, 'ann', 10, 'A');
    INSERT INTO orders VALUES (2, 'ann', 30, 'A');
    INSERT INTO orders VALUES (3, 'bob', 5, 'A');
    INSERT INTO orders VALUES (4, 'bob', 50, 'B');
    INSERT INTO orders VALUES (5, 'cyd', 7, 'A');
    """

  private func run(_ pipeline: String, label: String) async throws -> [SQLiteRowData] {
    let path = TestEnv.freshFile(label)
    TestEnv.createEmptyFile(at: path)
    defer { TestEnv.remove(path) }
    let conn = try await TestEnv.connect(TestEnv.config(label: label, path: path))
    defer { await conn.disconnect() }
    try await conn.execute(sql: Self.seedSQL)
    let stages = try AggregationPipeline.documents(AggregationPipeline.importJavaScript(pipeline).stages)
    let sql = try SQLPipelineCompiler.compile(stages, from: "\"orders\"", flavor: .sqlite)
    return try await conn.select(sql: sql)
  }

  @Test func groupSortLimit() async throws {
    let rows = try await run(
      #"""
      db.orders.aggregate([
        { $match: { status: "A" } },
        { $group: { _id: "$customer", total: { $sum: "$amount" }, orders: { $sum: 1 } } },
        { $sort: { total: -1 } },
        { $limit: 2 }
      ])
      """#, label: "group")
    #expect(rows.map(\.columns) == [["_id", "total", "orders"], ["_id", "total", "orders"]])
    #expect(rows.map { $0["_id"] } == [.string("ann"), .string("cyd")])
    #expect(rows.map { $0["total"] } == [.int(40), .int(7)])
    #expect(rows.map { $0["orders"] } == [.int(2), .int(1)])
  }

  @Test func matchOnGroupOutput() async throws {
    let rows = try await run(
      #"""
      [
        { $group: { _id: "$customer", n: { $sum: 1 } } },
        { $match: { n: { $gte: 2 } } },
        { $sort: { _id: 1 } }
      ]
      """#, label: "having")
    #expect(rows.map { $0["_id"] } == [.string("ann"), .string("bob")])
  }

  @Test func projectWithExpressionsAndPaging() async throws {
    let rows = try await run(
      #"""
      [
        { $sort: { id: 1 } },
        { $project: { customer: 1, doubled: { $multiply: ["$amount", 2] }, tag: { $toUpper: "$status" } } },
        { $skip: 1 },
        { $limit: 2 }
      ]
      """#, label: "project")
    #expect(rows.map(\.columns) == [["customer", "doubled", "tag"], ["customer", "doubled", "tag"]])
    #expect(rows.map { $0["doubled"] } == [.int(60), .int(10)])
    #expect(rows.map { $0["tag"] } == [.string("A"), .string("A")])
  }

  @Test func countAndSortByCount() async throws {
    let count = try await run(#"[{ $match: { amount: { $gt: 6 } } }, { $count: "big" }]"#, label: "count")
    #expect(count.map { $0["big"] } == [.int(4)])
    let byCount = try await run(#"[{ $sortByCount: "$status" }]"#, label: "sortbycount")
    #expect(byCount.map { $0["_id"] } == [.string("A"), .string("B")])
    #expect(byCount.map { $0["count"] } == [.int(4), .int(1)])
  }

  @Test func compositeKeysAndAddFields() async throws {
    let rows = try await run(
      #"""
      [
        { $group: { _id: { who: "$customer", status: "$status" }, sum: { $sum: "$amount" } } },
        { $addFields: { half: { $divide: ["$sum", 2] } } },
        { $sort: { "_id.who": 1, "_id.status": 1 } }
      ]
      """#, label: "composite")
    #expect(rows.count == 4)
    #expect(rows[0].columns == ["_id.who", "_id.status", "sum", "half"])
    #expect(rows[0]["half"] == .double(20))
    #expect(rows.map { $0["_id.status"] } == [.string("A"), .string("A"), .string("B"), .string("A")])
  }
}
