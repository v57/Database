import Foundation
import Testing

@testable import MongoDB

/// The aggregation builder's model: stage parsing and JavaScript
/// import/export. Pure: no server needed.
@Suite struct AggregationPipelineTests {
  private let stages = [
    PipelineStage(name: "$match", body: #"{ status: "A" }"#),
    PipelineStage(name: "$group", body: #"{ _id: "$customer", total: { $sum: "$amount" } }"#),
    PipelineStage(name: "$limit", body: "5", isEnabled: false),
    PipelineStage(name: "$sort", body: "{ total: -1 }"),
  ]

  @Test func documentsSkipDisabledStages() throws {
    let documents = try AggregationPipeline.documents(stages)
    #expect(documents.map(\.keys) == [["$match"], ["$group"], ["$sort"]])
    #expect(documents[1]["$group"] == ["_id": "$customer", "total": ["$sum": "$amount"]])
  }

  @Test func documentsReportTheBrokenStage() {
    var broken = stages
    broken[3].body = "{ total: }"
    #expect(throws: PipelineError.self) { _ = try AggregationPipeline.documents(broken) }
    do {
      _ = try AggregationPipeline.documents(broken)
    } catch let error as PipelineError {
      #expect(error.stageIndex == 3)
      #expect(error.localizedDescription.hasPrefix("Stage 4:"))
    } catch {
      Issue.record("unexpected error \(error)")
    }
  }

  @Test func exportsMongoshScript() {
    let script = AggregationPipeline.javaScript(stages, collection: "orders")
    #expect(
      script == """
        db.getCollection("orders").aggregate([
          { $match: { status: "A" } },
          { $group: { _id: "$customer", total: { $sum: "$amount" } } },
          // { $limit: 5 }
          { $sort: { total: -1 } }
        ]);

        """)
  }

  @Test func exportImportRoundTrip() throws {
    let script = AggregationPipeline.javaScript(stages, collection: "orders")
    let imported = try AggregationPipeline.importJavaScript(script)
    #expect(imported.collection == "orders")
    // The disabled stage was exported as a comment, so it isn't re-imported.
    let enabled = try AggregationPipeline.documents(stages)
    #expect(try AggregationPipeline.documents(imported.stages) == enabled)
  }

  @Test func importsShellScriptWithHelpersAndComments() throws {
    let script = #"""
      use("shop");
      // Orders per customer since March
      db.orders.aggregate([
        { $match: { createdAt: { $gte: ISODate("2024-03-01") }, note: /rush/i } },
        { $group: { _id: "$customer", n: { $sum: 1 } } }, // trailing comma ok
      ], { allowDiskUse: true });
      """#
    let imported = try AggregationPipeline.importJavaScript(script)
    #expect(imported.collection == "orders")
    #expect(imported.stages.map(\.name) == ["$match", "$group"])
    let match = try imported.stages[0].value()
    #expect(
      match.documentValue?["createdAt"]?.documentValue?["$gte"]
        == .datetime(Date(timeIntervalSince1970: 1_709_251_200)))
    #expect(match.documentValue?["note"] == .regex(BSONRegularExpression(pattern: "rush", options: "i")))
    // The stage text is shell syntax, so it re-parses to the same value.
    #expect(imported.stages[0].body.contains(#"ISODate("2024-03-01T00:00:00.000Z")"#))
  }

  @Test func importsCollectionSpellings() throws {
    #expect(try AggregationPipeline.importJavaScript(#"db["my orders"].aggregate([])"#).collection == "my orders")
    #expect(
      try AggregationPipeline.importJavaScript(#"db.getCollection('orders').aggregate([{ $count: "n" }])"#)
        .collection == "orders")
    #expect(try AggregationPipeline.importJavaScript(#"db.sales.daily.aggregate([])"#).collection == "sales.daily")
  }

  @Test func importsVariablePipelinesAndJSON() throws {
    let variable = try AggregationPipeline.importJavaScript(
      """
      const pipeline = [{ $match: { a: 1 } }];
      db.things.aggregate(pipeline);
      """)
    #expect(variable.stages.map(\.name) == ["$match"])
    #expect(variable.collection == "things")

    let json = try AggregationPipeline.importJavaScript(#"[{"$limit": 3}]"#)
    #expect(json.stages.map(\.name) == ["$limit"])
    #expect(json.collection == nil)
  }

  @Test func ignoresBracketsInsideStringsAndComments() throws {
    let script = """
      // see [docs]
      const label = "[not this]";
      db.c.aggregate([{ $count: "n" }]);
      """
    let imported = try AggregationPipeline.importJavaScript(script)
    #expect(imported.stages.map(\.name) == ["$count"])
  }

  @Test func rejectsNonStages() {
    #expect(throws: PipelineError.self) {
      _ = try AggregationPipeline.importJavaScript(#"[{ $match: {}, $limit: 1 }]"#)
    }
    #expect(throws: PipelineError.self) { _ = try AggregationPipeline.importJavaScript("[1]") }
    #expect(throws: MongoDBError.self) { _ = try AggregationPipeline.importJavaScript("db.c.find({})") }
  }

  @Test func seedsStagesFromTheFindQuery() {
    let seeded = AggregationPipeline.stages(
      filter: "age: { $gt: 30 }", sort: "{ age: -1 }", projection: "name ASC")
    #expect(seeded.map(\.name) == ["$match", "$sort"])
    #expect(seeded[0].body == "{ age: { $gt: 30 } }")
  }

  @Test func templatesNameTheField() {
    let group = AggregationPipeline.stageKinds.first { $0.name == "$group" }!
    #expect(group.template(field: "first name").contains(#"_id: "$first name""#))
    let sort = AggregationPipeline.stageKinds.first { $0.name == "$sort" }!
    #expect(sort.template(field: "first name") == #"{ "first name": 1 }"#)
    #expect(sort.template(field: nil) == "{ field: 1 }")
    // Every template parses.
    for kind in AggregationPipeline.stageKinds {
      #expect((try? QueryParser.parseValue(kind.template(field: "age"))) != nil, "\(kind.name)")
    }
  }
}
