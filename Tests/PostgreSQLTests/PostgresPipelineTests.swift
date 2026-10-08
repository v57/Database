import Foundation
import MongoDB
import SQLQuery
import Testing

@testable import PostgreSQL

/// End-to-end: aggregation pipelines compiled for PostgreSQL — the stricter
/// dialect (derived tables need aliases, ROUND needs NUMERIC, no implicit
/// alias references) — run against the localhost server. Each test owns a schema.
@Suite(.serialized) struct PostgresPipelineTests {
  private func run(_ pipeline: String, label: String) async throws -> [PostgresRowData] {
    let conn = try await TestEnv.connect(TestEnv.config())
    defer { await conn.disconnect() }
    let schema = TestEnv.freshSchemaName(label)
    try await TestEnv.makeSchema(conn, schema)
    do {
      try await conn.execute(
        sql: """
          CREATE TABLE \(schema).orders (id int PRIMARY KEY, customer text, amount int, status text);
          INSERT INTO \(schema).orders VALUES
            (1, 'ann', 10, 'A'), (2, 'ann', 30, 'A'), (3, 'bob', 5, 'A'), (4, 'bob', 50, 'B'),
            (5, 'cyd', 7, 'A');
          """)
      let stages = try AggregationPipeline.documents(AggregationPipeline.importJavaScript(pipeline).stages)
      let sql = try SQLPipelineCompiler.compile(
        stages, from: "\"\(schema)\".\"orders\"", flavor: .postgresql)
      let rows = try await conn.select(sql: sql)
      await TestEnv.dropSchema(conn, schema)
      return rows
    } catch {
      await TestEnv.dropSchema(conn, schema)
      throw error
    }
  }

  @Test func groupMatchSortPage() async throws {
    let rows = try await run(
      #"""
      [
        { $group: { _id: "$customer", total: { $sum: "$amount" }, n: { $sum: 1 } } },
        { $match: { n: { $gte: 1 } } },
        { $sort: { total: -1 } },
        { $skip: 1 },
        { $limit: 2 }
      ]
      """#, label: "pipe_group")
    // Totals: bob 55, ann 40, cyd 7 — skipping the first leaves ann and cyd.
    #expect(rows.map { $0["_id"] } == [.string("ann"), .string("cyd")])
    #expect(rows.map { $0["total"] } == [.int(40), .int(7)])
  }

  @Test func expressionsAndCompositeKeys() async throws {
    let rows = try await run(
      #"""
      [
        { $group: { _id: { who: "$customer", status: "$status" }, avg: { $avg: "$amount" } } },
        { $project: { "_id.who": 1, rounded: { $round: [{ $divide: ["$avg", 3] }, 1] } } },
        { $sort: { "_id.who": 1, rounded: -1 } }
      ]
      """#, label: "pipe_expr")
    #expect(rows.count == 4)
    #expect(rows[0].columns == ["_id.who", "rounded"])
    #expect(rows.map { $0["_id.who"] } == [.string("ann"), .string("bob"), .string("bob"), .string("cyd")])
  }

  @Test func sortByCountAndPush() async throws {
    let byCount = try await run(#"[{ $sortByCount: "$status" }]"#, label: "pipe_sbc")
    #expect(byCount.map { $0["_id"] } == [.string("A"), .string("B")])
    #expect(byCount.map { $0["count"] } == [.int(4), .int(1)])

    let pushed = try await run(
      #"[{ $group: { _id: null, who: { $addToSet: "$customer" } } }]"#, label: "pipe_push")
    #expect(pushed.count == 1)
  }

  @Test func countAfterLimitWraps() async throws {
    let rows = try await run(#"[{ $sort: { id: 1 } }, { $limit: 3 }, { $count: "n" }]"#, label: "pipe_count")
    #expect(rows.map { $0["n"] } == [.int(3)])
  }
}
