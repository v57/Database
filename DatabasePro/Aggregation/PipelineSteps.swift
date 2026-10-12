import DatabaseProKit
import Foundation

/// Every MongoDB aggregation stage the builder offers, with a plain name.
enum StepKind: String, CaseIterable, Identifiable, Codable {
  case match, project, set, unset, replaceWith
  case group, count, bucket, bucketAuto, sortByCount
  case unwind
  case sort, limit, skip, sample
  case lookup, graphLookup, unionWith, facet
  case setWindowFields, densify, fill
  case geoNear
  case out, merge

  var id: String { rawValue }
  var op: String { "$" + rawValue }

  var name: String {
    switch self {
    case .match: "Filter"
    case .project: "Pick Fields"
    case .set: "Add Fields"
    case .unset: "Remove Fields"
    case .replaceWith: "Replace Document"
    case .group: "Group"
    case .count: "Count"
    case .bucket: "Buckets"
    case .bucketAuto: "Auto Buckets"
    case .sortByCount: "Count by Value"
    case .unwind: "Unwind"
    case .sort: "Sort"
    case .limit: "Limit"
    case .skip: "Skip"
    case .sample: "Random Sample"
    case .lookup: "Join"
    case .graphLookup: "Follow Links"
    case .unionWith: "Append Collection"
    case .facet: "Branches"
    case .setWindowFields: "Window Fields"
    case .densify: "Fill Gaps"
    case .fill: "Fill Missing"
    case .geoNear: "Nearest First"
    case .out: "Save to Collection"
    case .merge: "Merge Into"
    }
  }

  var does: String {
    switch self {
    case .match: "Keep only matching documents"
    case .project: "Show, hide or rename fields"
    case .set: "Compute new fields"
    case .unset: "Drop fields"
    case .replaceWith: "Make a sub-document the whole document"
    case .group: "Combine and count, sum, average"
    case .count: "Count what reaches this step"
    case .bucket: "Group into ranges you choose"
    case .bucketAuto: "Group into even ranges"
    case .sortByCount: "Count each value, most common first"
    case .unwind: "One document per array item"
    case .sort: "Put documents in order"
    case .limit: "Keep the first few"
    case .skip: "Skip the first few"
    case .sample: "Pick documents at random"
    case .lookup: "Bring in documents from another collection"
    case .graphLookup: "Follow references recursively"
    case .unionWith: "Add another collection's documents"
    case .facet: "Several summaries from one pass"
    case .setWindowFields: "Running totals, ranks, moving averages"
    case .densify: "Add missing dates or numbers"
    case .fill: "Fill empty values"
    case .geoNear: "Order by distance from a point"
    case .out: "Replace a collection with the results"
    case .merge: "Merge the results into a collection"
    }
  }

  var group: String {
    switch self {
    case .match, .project, .set, .unset, .replaceWith: "Filter and shape"
    case .group, .count, .bucket, .bucketAuto, .sortByCount: "Group and count"
    case .unwind: "Arrays"
    case .sort, .limit, .skip, .sample: "Order and pages"
    case .lookup, .graphLookup, .unionWith, .facet: "Combine"
    case .setWindowFields, .densify, .fill: "Time and windows"
    case .geoNear: "Location"
    case .out, .merge: "Save results"
    }
  }

  static let groups = [
    "Filter and shape", "Group and count", "Arrays", "Order and pages", "Combine", "Time and windows", "Location",
    "Save results",
  ]

  /// The steps the simple builder lists.
  static let common: [StepKind] = [.match, .group, .sort, .limit, .project, .set, .lookup, .unwind]

  /// Steps a SQL table can run (compiled to one SELECT).
  static let sqlCompatible: Set<StepKind> = [.match, .group, .sort, .limit, .skip, .project, .count]

  /// Writes data: off by default while trying things out.
  var writes: Bool { self == .out || self == .merge }

  /// A starting body for a new step.
  func template(field: String?) -> String {
    let f = field ?? "field"
    switch self {
    case .match: return "{ \(f): { $exists: true } }"
    case .project: return "{ \(f): 1 }"
    case .set: return "{ newField: \"$\(f)\" }"
    case .unset: return "\"\(f)\""
    case .replaceWith: return "\"$\(f)\""
    case .group: return "{ _id: \"$\(f)\", count: { $count: {} } }"
    case .count: return "\"count\""
    case .bucket: return "{ groupBy: \"$\(f)\", boundaries: [0, 100, 1000], default: \"Other\" }"
    case .bucketAuto: return "{ groupBy: \"$\(f)\", buckets: 5 }"
    case .sortByCount: return "\"$\(f)\""
    case .unwind: return "{ path: \"$\(f)\", preserveNullAndEmptyArrays: false }"
    case .sort: return "{ \(f): 1 }"
    case .limit: return "10"
    case .skip: return "10"
    case .sample: return "{ size: 10 }"
    case .lookup: return "{ from: \"other\", localField: \"\(f)\", foreignField: \"_id\", as: \"joined\" }"
    case .graphLookup:
      return "{ from: \"other\", startWith: \"$\(f)\", connectFromField: \"\(f)\", connectToField: \"_id\", as: \"chain\" }"
    case .unionWith: return "{ coll: \"other\" }"
    case .facet: return "{ first: [{ $limit: 5 }], second: [{ $count: \"n\" }] }"
    case .setWindowFields:
      return "{ sortBy: { \(f): 1 }, output: { running: { $sum: 1, window: { documents: [\"unbounded\", \"current\"] } } } }"
    case .densify: return "{ field: \"\(f)\", range: { step: 1, unit: \"day\", bounds: \"full\" } }"
    case .fill: return "{ output: { \(f): { value: 0 } } }"
    case .geoNear: return "{ near: { type: \"Point\", coordinates: [0, 0] }, distanceField: \"distance\" }"
    case .out: return "\"results\""
    case .merge: return "{ into: \"results\", whenMatched: \"replace\", whenNotMatched: \"insert\" }"
    }
  }
}

/// One condition in a Filter step ("rating is at least 4").
struct StepCondition: Identifiable, Hashable, Codable {
  var id = UUID()
  var field: String
  var op: FilterOp
  var value: String
}

/// One output of a Group step ("avgRating = Average of rating").
struct GroupOutput: Identifiable, Hashable, Codable {
  enum Function: String, CaseIterable, Codable, Identifiable {
    case count, sum, avg, min, max, first, last, push, addToSet
    var id: String { rawValue }
    var label: String {
      switch self {
      case .count: "Count"
      case .sum: "Sum of"
      case .avg: "Average of"
      case .min: "Smallest"
      case .max: "Largest"
      case .first: "First"
      case .last: "Last"
      case .push: "List of"
      case .addToSet: "Distinct list of"
      }
    }
    var sql: String? {
      switch self {
      case .count: "COUNT"
      case .sum: "SUM"
      case .avg: "AVG"
      case .min: "MIN"
      case .max: "MAX"
      default: nil
      }
    }
  }

  var id = UUID()
  var name: String
  var function: Function
  var field: String
}

/// A computed field in an Add Fields step, built from blocks.
struct FieldFormula: Identifiable, Hashable, Codable {
  enum Kind: String, CaseIterable, Codable, Identifiable {
    case copy, roundDate, condition, concat, math, size, raw
    var id: String { rawValue }
    var label: String {
      switch self {
      case .copy: "Copy of"
      case .roundDate: "Round date down"
      case .condition: "If … then … else"
      case .concat: "Join text"
      case .math: "Arithmetic"
      case .size: "Number of items"
      case .raw: "Expression"
      }
    }
    var op: String {
      switch self {
      case .copy: "$field"
      case .roundDate: "$dateTrunc"
      case .condition: "$cond"
      case .concat: "$concat"
      case .math: "$add / $multiply…"
      case .size: "$size"
      case .raw: "{ … }"
      }
    }
  }

  var id = UUID()
  var name: String
  var kind: Kind
  var field: String = ""
  var unit: String = "month"
  var timezone: String = ""
  var compare: FilterOp = .greaterOrEqual
  var compareValue: String = ""
  var thenValue: String = "1"
  var elseValue: String = "0"
  var otherField: String = ""
  var mathOp: String = "$add"
  var raw: String = ""
}

/// A step's friendly form. Steps without one are edited as text.
enum StepForm: Hashable, Codable {
  case filter([StepCondition])
  case group(by: [String], outputs: [GroupOutput])
  case sort([SortKey])
  case limit(Int)
  case skip(Int)
  case pick(fields: [String], exclude: Bool)
  case addFields([FieldFormula])
  case unwind(path: String, keepEmpty: Bool)
  case lookup(from: String, localField: String, foreignField: String, as: String)
  case count(String)
}

struct PipelineStep: Identifiable, Hashable {
  var id = UUID()
  var kind: StepKind
  var isEnabled = true
  var form: StepForm?
  /// Shell text of the stage body; the source of truth when `form` is nil.
  var text: String
  /// Steps that run inside a Join's sub-pipeline or a Branches stage, shown nested.
  var note: String?
}
