import BSON
import Foundation

/// A parsed line of mongosh: `db.orders.find({…}).sort({…}).limit(5)`, `show dbs`, `use shop`…
struct MongoShellCall: Sendable {
  enum Target: Sendable, Equatable {
    case database
    case collection(String)
  }

  var target: Target
  var method: String
  var arguments: [BSON]
  /// Chained calls after the first, e.g. sort / limit / skip.
  var chain: [(name: String, arguments: [BSON])]
}

enum MongoShellStatement: Sendable {
  case showDatabases
  case showCollections
  case use(String)
  case call(MongoShellCall)
}

enum MongoShell {
  struct ParseError: Error, LocalizedError {
    var message: String
    var errorDescription: String? { message }
  }

  /// Splits text into statements (by `;` or newlines at the top level) and parses each.
  static func parse(_ text: String) throws -> [MongoShellStatement] {
    try splitStatements(text).map(parseStatement)
  }

  /// Splits on `;` and on newlines at the top level; a line starting with "." continues the one before.
  static func splitStatements(_ text: String) -> [String] {
    var pieces: [String] = []
    var current = ""
    var depth = 0
    var quote: Character?
    var escaped = false
    var chars = Array(text)
    var i = 0
    while i < chars.count {
      let ch = chars[i]
      if let q = quote {
        current.append(ch)
        if escaped { escaped = false } else if ch == "\\" { escaped = true } else if ch == q { quote = nil }
        i += 1
        continue
      }
      // `//` comments run to the end of the line.
      if ch == "/", i + 1 < chars.count, chars[i + 1] == "/" {
        while i < chars.count, chars[i] != "\n" { i += 1 }
        continue
      }
      switch ch {
      case "\"", "'": quote = ch
      case "(", "[", "{": depth += 1
      case ")", "]", "}": depth -= 1
      default: break
      }
      if depth == 0 && (ch == ";" || ch == "\n") {
        let trimmed = current.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty {
          if trimmed.hasPrefix("."), let last = pieces.popLast() {
            pieces.append(last + trimmed)
          } else {
            pieces.append(trimmed)
          }
        }
        current = ""
      } else {
        current.append(ch)
      }
      i += 1
    }
    let trimmed = current.trimmingCharacters(in: .whitespacesAndNewlines)
    if !trimmed.isEmpty {
      if trimmed.hasPrefix("."), let last = pieces.popLast() { pieces.append(last + trimmed) } else { pieces.append(trimmed) }
    }
    chars = []
    return pieces
  }

  static func parseStatement(_ raw: String) throws -> MongoShellStatement {
    let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    let words = text.split(separator: " ", omittingEmptySubsequences: true)
    if words.first == "show", words.count == 2 {
      switch words[1] {
      case "dbs", "databases": return .showDatabases
      case "collections", "tables": return .showCollections
      default: throw ParseError(message: "Unknown show command: \(words[1])")
      }
    }
    if words.first == "use", words.count == 2 { return .use(String(words[1])) }
    guard text.hasPrefix("db.") || text.hasPrefix("db[") else {
      throw ParseError(message: "Start with db.<collection>.<method>(…), show dbs, show collections or use <database>.")
    }
    var scalars = Array(text.unicodeScalars)
    var i = 2
    // Collection: db.name, db["name"], db.getCollection("name")
    var target = MongoShellCall.Target.database
    var calls: [(String, [BSON])] = []

    func readIdentifier() -> String {
      var name = ""
      while i < scalars.count, scalars[i].properties.isAlphabetic || scalars[i].properties.numericType != nil
        || scalars[i] == "_" || scalars[i] == "$" || scalars[i] == "-"
      {
        name.unicodeScalars.append(scalars[i])
        i += 1
      }
      return name
    }

    func readArguments() throws -> [BSON] {
      guard i < scalars.count, scalars[i] == "(" else { throw ParseError(message: "Expected \"(\"") }
      let start = i + 1
      var depth = 0
      var quote: Unicode.Scalar?
      var escaped = false
      while i < scalars.count {
        let c = scalars[i]
        if let q = quote {
          if escaped { escaped = false } else if c == "\\" { escaped = true } else if c == q { quote = nil }
        } else if c == "\"" || c == "'" {
          quote = c
        } else if c == "(" || c == "[" || c == "{" {
          depth += 1
        } else if c == ")" || c == "]" || c == "}" {
          depth -= 1
          if depth == 0 && c == ")" {
            let inner = String(String.UnicodeScalarView(scalars[start..<i]))
            i += 1
            do {
              // Always wrap: an argument that is itself an array must stay one argument.
              if inner.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return [] }
              guard case .array(let items) = try BSONParser.parse("[" + inner + "]") else { return [] }
              return items
            } catch let error as BSONError {
              throw ParseError(message: error.localizedDescription)
            }
          }
        }
        i += 1
      }
      throw ParseError(message: "Missing \")\"")
    }

    if i < scalars.count, scalars[i] == "[" {
      guard let close = text.firstIndex(of: "]") else { throw ParseError(message: "Missing \"]\"") }
      let inside = text[text.index(text.startIndex, offsetBy: 3)..<close].trimmingCharacters(in: .whitespaces)
      target = .collection(inside.trimmingCharacters(in: CharacterSet(charactersIn: "\"'")))
      i = text.distance(from: text.startIndex, to: close) + 1
      scalars = Array(text.unicodeScalars)
    } else {
      i = 3
      let first = readIdentifier()
      if i < scalars.count, scalars[i] == "(" {
        if first == "getCollection" {
          let args = try readArguments()
          guard let name = args.first?.stringValue else { throw ParseError(message: "getCollection needs a name") }
          target = .collection(name)
        } else {
          calls.append((first, try readArguments()))
        }
      } else {
        target = .collection(first)
      }
    }
    while i < scalars.count {
      while i < scalars.count, scalars[i] == " " || scalars[i] == "\n" || scalars[i] == "\t" { i += 1 }
      guard i < scalars.count else { break }
      guard scalars[i] == "." else {
        if scalars[i] == ";" { break }
        throw ParseError(message: "Unexpected \"\(scalars[i])\"")
      }
      i += 1
      let name = readIdentifier()
      guard !name.isEmpty else { throw ParseError(message: "Expected a method name") }
      calls.append((name, try readArguments()))
    }
    guard let first = calls.first else {
      throw ParseError(message: "Call a method, e.g. db.\(target == .database ? "runCommand" : "collection.find")(…)")
    }
    return .call(
      MongoShellCall(
        target: target, method: first.0, arguments: first.1, chain: calls.dropFirst().map { ($0.0, $0.1) }))
  }
}
