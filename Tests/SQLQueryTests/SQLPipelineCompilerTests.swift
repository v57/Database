import Foundation
import MongoDB
import Testing

@testable import SQLQuery

/// Pure unit tests for the aggregation pipeline -> SQL compiler: which stages
/// fold into one SELECT, which wrap a derived table, and the error paths.
@Suite struct SQLPipelineCompilerTests {
  /// Compiles shell-syntax stage text, e.g. `[{ $match: { a: 1 } }]`.
  private func sql(_ pipeline: String, flavor: SQLFlavor = .sqlite) throws -> String {
    let stages = try AggregationPipeline.importJavaScript(pipeline).stages
    return try SQLPipelineCompiler.compile(
      AggregationPipeline.documents(stages), from: "\"t\"", flavor: flavor)
  }

  @Test func emptyPipelineSelectsEverything() throws {
    #expect(try sql("[]") == "SELECT *\nFROM \"t\"")
  }

  @Test func classicStagesFoldIntoOneSelect() throws {
    let compiled = try sql(
      #"""
      [
        { $match: { status: "A" } },
        { $group: { _id: "$customer", total: { $sum: "$amount" }, n: { $sum: 1 } } },
        { $sort: { total: -1 } },
        { $skip: 10 },
        { $limit: 5 }
      ]
      """#)
    #expect(
      compiled == """
        SELECT "customer" AS "_id", COALESCE(SUM("amount"), 0) AS "total", COUNT(*) AS "n"
        FROM "t"
        WHERE "status" = 'A'
        GROUP BY "customer"
        ORDER BY "total" DESC
        LIMIT 5
        OFFSET 10
        """)
  }

  @Test func matchAfterGroupWrapsADerivedTable() throws {
    let compiled = try sql(
      #"[{ $group: { _id: "$city", n: { $sum: 1 } } }, { $match: { n: { $gt: 1 } } }]"#)
    #expect(
      compiled == """
        SELECT *
        FROM (
          SELECT "city" AS "_id", COUNT(*) AS "n"
          FROM "t"
          GROUP BY "city"
        ) AS "s1"
        WHERE "n" > 1
        """)
  }

  @Test func sortSurvivesAWrapForRowFilters() throws {
    let compiled = try sql(#"[{ $sort: { age: -1 } }, { $limit: 3 }, { $match: { age: { $gt: 1 } } }]"#)
    #expect(
      compiled == """
        SELECT *
        FROM (
          SELECT *
          FROM "t"
          ORDER BY "age" DESC
          LIMIT 3
        ) AS "s1"
        WHERE "age" > 1
        ORDER BY "age" DESC
        """)
  }

  @Test func skipAfterLimitNarrowsTheWindow() throws {
    #expect(try sql("[{ $limit: 10 }, { $skip: 4 }]") == "SELECT *\nFROM \"t\"\nLIMIT 6\nOFFSET 4")
    #expect(try sql("[{ $limit: 10 }, { $limit: 3 }]") == "SELECT *\nFROM \"t\"\nLIMIT 3")
  }

  @Test func offsetWithoutLimitPerFlavor() throws {
    #expect(try sql("[{ $skip: 2 }]", flavor: .sqlite) == "SELECT *\nFROM \"t\"\nLIMIT -1\nOFFSET 2")
    #expect(try sql("[{ $skip: 2 }]", flavor: .postgresql) == "SELECT *\nFROM \"t\"\nOFFSET 2")
  }

  @Test func compositeGroupKeysBecomeDottedColumns() throws {
    let compiled = try sql(
      #"[{ $group: { _id: { city: "$city", year: "$year" }, avg: { $avg: "$age" } } }, { $sort: { "_id.city": 1 } }]"#)
    #expect(
      compiled == """
        SELECT "city" AS "_id.city", "year" AS "_id.year", AVG("age") AS "avg"
        FROM "t"
        GROUP BY "city", "year"
        ORDER BY "_id.city" ASC
        """)
  }

  @Test func nullGroupKeyAggregatesEverything() throws {
    #expect(
      try sql(#"[{ $group: { _id: null, max: { $max: "$age" } } }]"#)
        == "SELECT NULL AS \"_id\", MAX(\"age\") AS \"max\"\nFROM \"t\"")
  }

  @Test func projectionsIncludeComputeAndKeepIDAfterGroup() throws {
    #expect(
      try sql(#"[{ $project: { name: 1, total: { $multiply: ["$price", "$qty"] }, _id: 0 } }]"#)
        == "SELECT \"name\", (\"price\" * \"qty\") AS \"total\"\nFROM \"t\"")
    // After $group the columns are known: `_id` stays unless excluded, and
    // exclusion works.
    #expect(
      try sql(#"[{ $group: { _id: "$c", n: { $sum: 1 }, s: { $sum: "$v" } } }, { $project: { n: 1 } }]"#)
        == """
        SELECT "_id", "n"
        FROM (
          SELECT "c" AS "_id", COUNT(*) AS "n", COALESCE(SUM("v"), 0) AS "s"
          FROM "t"
          GROUP BY "c"
        ) AS "s1"
        """)
    #expect(
      try sql(#"[{ $group: { _id: "$c", n: { $sum: 1 } } }, { $unset: "_id" }]"#).hasPrefix("SELECT \"n\"\nFROM ("))
  }

  @Test func exclusionOnATableThrows() {
    #expect(throws: SQLQueryError.self) { _ = try sql("[{ $project: { secret: 0 } }]") }
    #expect(throws: SQLQueryError.self) { _ = try sql("[{ $project: { a: 1, b: 0 } }]") }
  }

  @Test func addFieldsAppendsOrReplacesColumns() throws {
    #expect(
      try sql(#"[{ $addFields: { label: { $concat: ["$first", " ", "$last"] } } }]"#)
        == "SELECT *, (\"first\" || ' ' || \"last\") AS \"label\"\nFROM \"t\"")
    let replaced = try sql(
      #"[{ $group: { _id: "$c", n: { $sum: 1 } } }, { $set: { n: { $add: ["$n", 1] } } }]"#)
    #expect(replaced.hasPrefix("SELECT \"_id\", (\"n\" + 1) AS \"n\"\nFROM ("))
  }

  @Test func countAndSortByCount() throws {
    #expect(
      try sql(#"[{ $match: { a: 1 } }, { $count: "total" }]"#)
        == "SELECT COUNT(*) AS \"total\"\nFROM \"t\"\nWHERE \"a\" = 1")
    #expect(
      try sql(#"[{ $sortByCount: "$tag" }]"#)
        == "SELECT \"tag\" AS \"_id\", COUNT(*) AS \"count\"\nFROM \"t\"\nGROUP BY \"tag\"\nORDER BY \"count\" DESC")
  }

  @Test func expressionsCompile() throws {
    let compiled = try sql(
      #"""
      [{ $project: {
        ratio: { $divide: ["$a", "$b"] },
        size: { $cond: { if: { $gte: ["$n", 10] }, then: "big", else: "small" } },
        name: { $toUpper: { $ifNull: ["$name", "?"] } },
        r: { $round: ["$x", 2] }
      } }]
      """#, flavor: .postgresql)
    #expect(
      compiled
        == "SELECT (\"a\" * 1.0 / \"b\") AS \"ratio\", CASE WHEN (\"n\" >= 10) THEN 'big' ELSE 'small' END AS \"size\", "
        + "UPPER(COALESCE(\"name\", '?')) AS \"name\", ROUND(CAST(\"x\" AS NUMERIC), 2) AS \"r\"\nFROM \"t\"")
  }

  @Test func exprInMatch() throws {
    #expect(
      try sql(#"[{ $match: { $expr: { $gt: ["$spent", "$budget"] }, active: true } }]"#)
        == "SELECT *\nFROM \"t\"\nWHERE (\"spent\" > \"budget\") AND \"active\" = TRUE")
  }

  @Test func pushPerFlavor() throws {
    #expect(try sql(#"[{ $group: { _id: null, all: { $addToSet: "$tag" } } }]"#, flavor: .postgresql)
      .contains("array_agg(DISTINCT \"tag\") AS \"all\""))
    #expect(try sql(#"[{ $group: { _id: null, all: { $push: "$tag" } } }]"#, flavor: .sqlite)
      .contains("json_group_array(\"tag\") AS \"all\""))
  }

  @Test func unsupportedStagesAndOperatorsNameTheStage() {
    for pipeline in [
      #"[{ $unwind: "$tags" }]"#,
      #"[{ $match: {} }, { $group: { _id: "$a", f: { $first: "$b" } } }]"#,
      #"[{ $project: { a: { $year: "$d" } } }]"#,
      #"[{ $project: { a: "$$ROOT" } }]"#,
      "[{ $limit: 0 }]",
      "[{ $group: { n: { $sum: 1 } } }]",
    ] {
      #expect(throws: SQLQueryError.self) { _ = try sql(pipeline) }
    }
    do {
      _ = try sql(#"[{ $match: {} }, { $unwind: "$tags" }]"#)
    } catch {
      #expect(error.localizedDescription.hasPrefix("Stage 2 ($unwind): $unwind has no SQL equivalent"))
    }
  }
}
