import Foundation

/// A driver error retold for someone who doesn't know databases: a short
/// title, what happened in plain words, what to try, and the original text
/// for anyone who needs it. Works on the message text alone, so every engine's
/// errors (and the app's own) go through the same rules.
public struct FriendlyError: Equatable, Sendable {
  /// What the user was doing; picks the fallback title and the advice.
  public enum Situation: Sendable {
    case connecting
    case loading
    case saving
  }

  public let title: String
  public let message: String
  public let suggestion: String?
  /// The original message without the engine prefix.
  public let details: String

  public init(title: String, message: String, suggestion: String? = nil, details: String) {
    self.title = title
    self.message = message
    self.suggestion = suggestion
    self.details = details
  }

  /// Explains `technical` (usually `error.localizedDescription`).
  public init(_ technical: String, while situation: Situation) {
    let details = Self.cleaned(technical)
    self = Self.rules(for: details, situation: situation)
      ?? FriendlyError(
        title: Self.fallbackTitle(situation), message: details,
        suggestion: situation == .connecting
          ? "Check the connection details with Edit Connection, then try again." : nil,
        details: details)
  }

  public init(_ error: any Error, while situation: Situation) {
    self.init(error.localizedDescription, while: situation)
  }

  /// True when the plain message adds nothing over the original (an unknown
  /// error), so the UI can skip a "Details" section that would repeat it.
  public var detailsRepeatMessage: Bool { details == message }

  // MARK: - Rules

  private static func fallbackTitle(_ situation: Situation) -> String {
    switch situation {
    case .connecting: "Couldn’t connect"
    case .loading: "Couldn’t load the data"
    case .saving: "Couldn’t save the change"
    }
  }

  /// First matching rule wins, so specific causes come before generic ones
  /// ("no encryption" before "connection refused").
  private static func rules(for details: String, situation: Situation) -> FriendlyError? {
    let text = details.lowercased()
    func has(_ needles: String...) -> Bool { needles.contains { text.contains($0) } }
    func make(_ title: String, _ message: String, _ suggestion: String? = nil) -> FriendlyError {
      FriendlyError(title: title, message: message, suggestion: suggestion, details: details)
    }

    if has("no encryption", "ssl is required", "ssl required", "requires ssl", "requires tls",
      "tls required", "ssl off", "encryption is required")
    {
      return make(
        "This server needs an encrypted connection",
        "Database connects without encryption (TLS), so it can’t open servers that require it yet. Most cloud database services do.",
        "Use a database on this Mac or on your local network.")
    }
    if has("no pg_hba.conf entry") {
      return make(
        "The server turned this connection away",
        "The server’s settings don’t allow connections from this device or this user.",
        "Ask whoever runs the server to allow access from this device.")
    }
    if has("password authentication failed", "authentication failed", "wrongpass",
      "invalid password", "invalid username-password", "auth failed")
    {
      return make(
        "Wrong username or password",
        "The server didn’t accept the username or password.",
        "Edit the connection and enter them again. For MongoDB, also check the Auth Source (usually “admin”).")
    }
    if has("noauth", "no password supplied", "authentication required") {
      return make(
        "This server needs a password",
        "The server only lets in users who sign in.",
        "Edit the connection and enter the username and password.")
    }
    if let role = quoted(after: "role", in: details), has("does not exist") {
      return make(
        "There’s no user called “\(role)”", "The server doesn’t know this username.",
        "Check the username in Edit Connection.")
    }
    if let name = quoted(after: "database", in: details), has("does not exist") {
      return make(
        "There’s no database called “\(name)”", "The server has no database with this name.",
        "Check the Default Database in Edit Connection, or leave it empty to see every database.")
    }
    if has("db index is out of range", "invalid db index") {
      return make(
        "That database number doesn’t exist", "This Redis server has fewer numbered databases.",
        "Redis database numbers usually run from 0 to 15.")
    }
    if has("failed to resolve", "could not translate host name", "nodename nor servname",
      "name or service not known", "unknown host", "no address associated")
    {
      return make(
        "Server not found", "No server could be found at the address you entered.",
        "Check the spelling of the host. For a database on this Mac, use “localhost”.")
    }
    if has("no route to host", "network is unreachable", "host is down") {
      return make(
        "Can’t reach that network address",
        "This device has no route to the server.",
        "Check that you’re on the same network as the server. On iPhone or iPad, allow Local Network access for Database in Settings › Privacy & Security.")
    }
    if has("connection refused", "setsockopt(tcp_nodelay)", "couldn't connect to server",
      "could not connect to server") || text == "connection failed"
    {
      return make(
        "Can’t reach the server",
        "Nothing answered at this address. The database server may not be running, or the host or port is wrong.",
        "Check that the server is running and that the host and port are right.")
    }
    if has("timed out", "timeout") {
      return make(
        "The server didn’t answer in time", "The server took too long to respond.",
        "Check your network connection. A firewall or VPN can also block the connection.")
    }
    if has("server closed the connection", "connection reset", "broken pipe", "not connected to") {
      return make(
        "The connection was lost", "The connection to the server closed.",
        "Connect again from the sidebar.")
    }
    if has("database file not found") {
      return make(
        "The database file is missing", "The file may have been moved, renamed or deleted.",
        "Edit the connection and choose the file again.")
    }
    if has("not a sqlite database", "file is not a database", "not a database") {
      return make(
        "This file isn’t a SQLite database",
        "The file opened, but it doesn’t contain a database this app can read.",
        "Choose a file ending in .sqlite, .sqlite3 or .db.")
    }
    if has("readonly database", "read-only") {
      return make(
        "This database is read-only", "Changes can’t be saved to this database.",
        "Check that the file isn’t locked and that you’re allowed to change it.")
    }
    if has("permission denied", "not authorized", "noperm", "unauthorized") {
      return make(
        "You don’t have permission",
        "Your user isn’t allowed to do this on this database.",
        "Ask whoever runs the database for access, or connect as a different user.")
    }
    if let table = name(after: "no such table:", in: details)
      ?? quoted(after: "relation", in: details).flatMap({ has("does not exist") ? $0 : nil })
    {
      return make(
        "There’s no table called “\(table)”", "It may have been renamed or deleted.",
        "Refresh the list in the sidebar.")
    }
    if let column = name(after: "no such column:", in: details)
      ?? quoted(after: "column", in: details).flatMap({ has("does not exist") ? $0 : nil })
    {
      return make(
        "There’s no field called “\(column)”",
        "The filter or sort mentions a field these records don’t have.",
        "Check the spelling. Field names are case-sensitive.")
    }
    if has("unique constraint failed", "duplicate key", "e11000") {
      return make(
        "That value is already used",
        "This field must be unique, and another record already has the same value.",
        "Enter a different value.")
    }
    if let column = notNullColumn(in: details) {
      return make(
        "“\(column)” can’t be empty", "This field needs a value.", "Enter a value and save again.")
    }
    if has("cannot store", "invalid input syntax for type", "datatype mismatch",
      "is out of range for type")
    {
      return make(
        "That value doesn’t fit this field",
        "The field expects a different kind of value, for example a number instead of text.",
        "Check the value and try again.")
    }
    if situation == .loading,
      has("expected", "at column", "incomplete input", "syntax error", "unexpected",
        "unterminated", "invalid json")
    {
      return make(
        "The query couldn’t be understood", details,
        "Check the query for a typo, or clear it and use Filter to build one without typing.")
    }
    return nil
  }

  /// `"name"` right after `keyword` (PostgreSQL: `role "bob" does not exist`).
  private static func quoted(after keyword: String, in text: String) -> String? {
    guard let range = text.range(of: keyword + " \"", options: .caseInsensitive) else { return nil }
    let rest = text[range.upperBound...]
    guard let end = rest.firstIndex(of: "\"") else { return nil }
    let name = String(rest[..<end])
    return name.isEmpty ? nil : name
  }

  /// The identifier after `prefix` (SQLite: `no such column: age`).
  private static func name(after prefix: String, in text: String) -> String? {
    guard let range = text.range(of: prefix, options: .caseInsensitive) else { return nil }
    let name = text[range.upperBound...].trimmingCharacters(in: .whitespaces)
      .prefix { !$0.isWhitespace }
    return name.isEmpty ? nil : String(name)
  }

  /// The column of a NOT NULL failure, without its table (`t.name` → `name`).
  private static func notNullColumn(in text: String) -> String? {
    if let qualified = name(after: "not null constraint failed:", in: text) {
      return String(qualified.split(separator: ".").last ?? Substring(qualified))
    }
    if text.localizedCaseInsensitiveContains("violates not-null constraint") {
      return quoted(after: "column", in: text)
    }
    return nil
  }

  /// Drops the engine/category prefixes the libraries put in front of the
  /// driver's own text, and folds whitespace runs (libpq adds newlines/tabs).
  static func cleaned(_ message: String) -> String {
    var text = message.trimmingCharacters(in: .whitespacesAndNewlines)
    let prefixes = [
      "MongoDB error:", "PostgreSQL error:", "Redis error:", "Redis:", "SQLite error:",
      "Invalid query:", "Invalid configuration:", "ERROR:",
    ]
    var stripped = true
    while stripped {
      stripped = false
      for prefix in prefixes where text.hasPrefix(prefix) {
        text = String(text.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
        stripped = true
      }
    }
    return text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
  }
}
