import Foundation

/// One stage of the aggregation builder: the stage operator (`$match`) and its
/// argument as editable shell-syntax text (`{ status: "A" }`). Text is the
/// source of truth, like the query bar's Filter field: it is parsed when the
/// pipeline runs or is exported, never kept as a second, parsed copy.
public struct PipelineStage: Identifiable, Equatable, Sendable {
  public var id: UUID
  public var name: String
  public var body: String
  /// Disabled stages stay in the builder (and in exports, commented out) but
  /// are skipped when the pipeline runs.
  public var isEnabled: Bool

  public init(id: UUID = UUID(), name: String, body: String, isEnabled: Bool = true) {
    self.id = id
    self.name = name
    self.body = body
    self.isEnabled = isEnabled
  }

  /// A stage holding `value`, rendered in shell syntax.
  public init(name: String, value: BSON, isEnabled: Bool = true) {
    self.init(name: name, body: ShellSyntax.render(value), isEnabled: isEnabled)
  }

  /// The parsed stage argument.
  public func value() throws -> BSON {
    guard !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw MongoDBError.invalidQuery("\(name) needs a value")
    }
    return try QueryParser.parseValue(body)
  }

  /// `{ <name>: <argument> }` — the stage as it is sent to the server.
  public func document() throws -> BSONDocument {
    var stage = BSONDocument()
    stage[name] = try value()
    return stage
  }
}

/// A stage that didn't parse, with its 0-based position in the builder.
public struct PipelineError: Error, LocalizedError, Equatable {
  public let stageIndex: Int
  public let message: String

  public var errorDescription: String? { "Stage \(stageIndex + 1): \(message)" }
}

/// The result of importing JavaScript: the stages and, when the script names
/// one, the collection it aggregated (`db.orders.aggregate(…)` → "orders").
public struct PipelineImport: Equatable, Sendable {
  public var stages: [PipelineStage]
  public var collection: String?
}

/// Aggregation-builder logic shared by every engine: the stage catalog, the
/// pipeline the enabled stages describe, and mongosh JavaScript import/export.
/// MongoDB runs the stage documents directly; SQL engines compile the same
/// documents with `SQLPipelineCompiler` (Sources/SQLQuery).
public enum AggregationPipeline {
  /// A stage operator offered by the builder's "Add Stage" menu.
  public struct StageKind: Identifiable, Sendable {
    public let name: String
    public let summary: String
    /// Starter argument. `FIELD` marks where a field name goes: as a key, a
    /// string (`"FIELD"`) or a field path (`"$FIELD"`).
    let template: String

    public var id: String { name }

    /// The starter text, naming `field` (e.g. the first loaded field) when
    /// given, else the placeholder name `field`.
    public func template(field: String?) -> String {
      let name = field ?? "field"
      return template
        .replacingOccurrences(of: "\"$FIELD\"", with: "\"$" + name.escapedJSON + "\"")
        .replacingOccurrences(of: "\"FIELD\"", with: "\"" + name.escapedJSON + "\"")
        .replacingOccurrences(of: "FIELD", with: ShellSyntax.key(name))
    }
  }

  /// The stages the builder offers, in menu order. Write stages (`$out`,
  /// `$merge`) are deliberately absent: the builder is for reading.
  public static let stageKinds: [StageKind] = [
    StageKind(name: "$match", summary: "Filter documents", template: "{ FIELD: \"value\" }"),
    StageKind(
      name: "$group", summary: "Group by a key and accumulate",
      template: "{\n  _id: \"$FIELD\",\n  count: { $sum: 1 }\n}"),
    StageKind(name: "$sort", summary: "Order documents", template: "{ FIELD: 1 }"),
    StageKind(name: "$project", summary: "Choose or compute fields", template: "{ FIELD: 1 }"),
    StageKind(name: "$addFields", summary: "Add computed fields", template: "{ newField: \"$FIELD\" }"),
    StageKind(name: "$set", summary: "Add computed fields", template: "{ newField: \"$FIELD\" }"),
    StageKind(name: "$unset", summary: "Remove fields", template: "\"FIELD\""),
    StageKind(name: "$limit", summary: "Keep the first N documents", template: "10"),
    StageKind(name: "$skip", summary: "Skip the first N documents", template: "10"),
    StageKind(name: "$count", summary: "Count documents", template: "\"count\""),
    StageKind(name: "$sortByCount", summary: "Group, count and sort", template: "\"$FIELD\""),
    StageKind(name: "$sample", summary: "Pick random documents", template: "{ size: 10 }"),
    StageKind(name: "$unwind", summary: "One document per array element", template: "\"$FIELD\""),
    StageKind(
      name: "$lookup", summary: "Join another collection",
      template:
        "{\n  from: \"otherCollection\",\n  localField: \"FIELD\",\n  foreignField: \"_id\",\n  as: \"joined\"\n}"),
    StageKind(name: "$replaceRoot", summary: "Promote an embedded document", template: "{ newRoot: \"$FIELD\" }"),
    StageKind(
      name: "$bucket", summary: "Group into ranges",
      template: "{\n  groupBy: \"$FIELD\",\n  boundaries: [0, 100, 1000],\n  default: \"other\"\n}"),
    StageKind(name: "$facet", summary: "Run sub-pipelines", template: "{\n  total: [{ $count: \"count\" }]\n}"),
  ]

  /// Stages that write to the database; the builder imports and exports them
  /// but never runs them.
  public static let writeStages: Set<String> = ["$out", "$merge"]

  /// A new stage of `kind` with its starter text.
  public static func stage(_ kind: StageKind, field: String?) -> PipelineStage {
    PipelineStage(name: kind.name, body: kind.template(field: field))
  }

  /// The pipeline the enabled stages describe. Throws the first stage that
  /// doesn't parse, with its position.
  public static func documents(_ stages: [PipelineStage]) throws -> [BSONDocument] {
    try stages.enumerated().compactMap { index, stage in
      guard stage.isEnabled else { return nil }
      do { return try stage.document() } catch {
        throw PipelineError(stageIndex: index, message: error.localizedDescription)
      }
    }
  }

  /// Seed stages for the Find query bar's state: Filter → `$match`, Sort →
  /// `$sort`, Project → `$project`. Text that isn't in the query dialect (a raw
  /// SQL fragment) has no stage equivalent and is left out.
  public static func stages(filter: String?, sort: String?, projection: String?) -> [PipelineStage] {
    [("$match", filter), ("$sort", sort), ("$project", projection)].compactMap { name, text in
      guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
        let document = try? QueryParser.parse(text), !document.isEmpty
      else { return nil }
      return PipelineStage(name: name, value: .document(document))
    }
  }

  // MARK: - JavaScript

  /// The pipeline as a mongosh script:
  ///
  ///     db.getCollection("orders").aggregate([
  ///       { $match: { status: "A" } },
  ///       { $group: { _id: "$customer", total: { $sum: "$amount" } } }
  ///     ]);
  ///
  /// Disabled stages are kept as `//` comments so nothing typed is lost;
  /// stages that don't parse are exported as written, also commented out.
  public static func javaScript(_ stages: [PipelineStage], collection: String) -> String {
    let lastEnabled = stages.lastIndex { $0.isEnabled && (try? $0.document()) != nil }
    var lines: [String] = []
    for (index, stage) in stages.enumerated() {
      let text: String
      let isActive: Bool
      if let document = try? stage.document() {
        text = ShellSyntax.render(.document(document), indent: 2)
        isActive = stage.isEnabled
      } else {
        text = "{ \(ShellSyntax.key(stage.name)): \(stage.body) }"
        isActive = false
      }
      let separator = isActive && index != lastEnabled ? "," : ""
      let entry = text + separator
      lines.append(
        contentsOf: entry.split(separator: "\n", omittingEmptySubsequences: false).map {
          isActive ? "  " + $0 : "  // " + $0
        })
    }
    let target = "db.getCollection(\"\(collection.escapedJSON)\")"
    guard !lines.isEmpty else { return "\(target).aggregate([]);\n" }
    return "\(target).aggregate([\n" + lines.joined(separator: "\n") + "\n]);\n"
  }

  /// Reads a pipeline out of JavaScript: a mongosh/Compass `aggregate` call,
  /// `const pipeline = [...]`, or a bare (JSON) array of stages. Comments and
  /// the shell's type helpers are understood; anything around the pipeline
  /// (`use("db")`, options after the array) is ignored.
  public static func importJavaScript(_ text: String) throws -> PipelineImport {
    let source = try QueryParser.pipelineSource(text)
    let stages = try source.stages.enumerated().map { index, value -> PipelineStage in
      guard case .document(let document) = value, document.count == 1,
        let name = document.keys.first, name.hasPrefix("$"), let argument = document[name]
      else {
        throw PipelineError(
          stageIndex: index, message: "a stage must be an object with one $stage key, e.g. { $match: {...} }")
      }
      return PipelineStage(name: name, value: argument)
    }
    return PipelineImport(stages: stages, collection: source.collection)
  }
}
