import Foundation

/// A pasted connection link (`mongodb://…`, `postgres://…`, `redis://…`, or a
/// SQLite file path) split into the fields of the connection form. Hosting
/// services hand out links like these, so pasting one is the easiest way in
/// for someone who doesn't know what a port or an auth source is.
public struct ConnectionLink: Equatable, Sendable {
  public enum Engine: String, Sendable {
    case mongodb
    case postgresql
    case redis
    case sqlite
  }

  public var engine: Engine
  /// Server host name, or the file path for SQLite.
  public var host: String
  public var port: Int?
  public var username: String?
  public var password: String?
  /// MongoDB/PostgreSQL database name, or the Redis database number.
  public var database: String?
  /// MongoDB `authSource`.
  public var authSource: String?
  /// MongoDB `directConnection=true`.
  public var directConnection = false
  /// Something about the link this app can't honour (encryption, several
  /// servers), in plain words. The other fields are still filled in.
  public var warning: String?

  public init(engine: Engine, host: String) {
    self.engine = engine
    self.host = host
  }

  public enum ParseError: LocalizedError, Equatable {
    case empty
    case unknownScheme(String)
    case missingHost

    public var errorDescription: String? {
      switch self {
      case .empty: "Paste a connection link first."
      case .unknownScheme(let scheme):
        "Links starting with “\(scheme)://” aren’t supported. Use a link that starts with mongodb://, postgres://, redis://, or a path to a SQLite file."
      case .missingHost: "The link doesn’t contain a server address."
      }
    }
  }

  static let encryptionWarning =
    "This link asks for an encrypted connection, which Database doesn’t support yet. It works with servers that accept unencrypted connections, such as ones on this Mac or your local network."

  /// Parses `text`; surrounding whitespace and quotes are ignored.
  public static func parse(_ text: String) throws -> ConnectionLink {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
      .trimmingCharacters(in: CharacterSet(charactersIn: "\"'`"))
    guard !trimmed.isEmpty else { throw ParseError.empty }

    guard let schemeEnd = trimmed.range(of: "://") else {
      // A bare path to a database file.
      if trimmed.hasPrefix("/") || trimmed.hasPrefix("~") {
        return ConnectionLink(engine: .sqlite, host: (trimmed as NSString).expandingTildeInPath)
      }
      throw ParseError.unknownScheme(trimmed.prefix { $0 != ":" }.lowercased())
    }
    let scheme = trimmed[..<schemeEnd.lowerBound].lowercased()
    let rest = String(trimmed[schemeEnd.upperBound...])

    switch scheme {
    case "sqlite", "sqlite3", "file":
      let path = rest.removingPercentEncoding ?? rest
      guard !path.isEmpty else { throw ParseError.missingHost }
      // sqlite:///abs/path and file:///abs/path both keep the leading slash.
      return ConnectionLink(
        engine: .sqlite, host: path.hasPrefix("/") ? path : (path as NSString).expandingTildeInPath)
    case "mongodb", "mongodb+srv": return try server(.mongodb, rest, srv: scheme == "mongodb+srv")
    case "postgres", "postgresql": return try server(.postgresql, rest, srv: false)
    case "redis", "rediss":
      var link = try server(.redis, rest, srv: false)
      if scheme == "rediss" { link.warning = encryptionWarning }
      return link
    default: throw ParseError.unknownScheme(scheme)
    }
  }

  /// `[user[:password]@]host[:port][,host…][/database][?options]`
  private static func server(_ engine: Engine, _ rest: String, srv: Bool) throws -> ConnectionLink {
    // The authority ends at the first "/" or "?" after the credentials; the
    // LAST "@" splits credentials off, as an unencoded "@" in a password is
    // more common than one in a host name.
    let authorityEnd =
      rest.firstIndex(where: { $0 == "/" || $0 == "?" }).map { end in
        // A "/" or "?" inside the password: look again after the "@".
        if let at = rest.lastIndex(of: "@"), at > end {
          return rest[at...].firstIndex(where: { $0 == "/" || $0 == "?" }) ?? rest.endIndex
        }
        return end
      } ?? rest.endIndex
    let authority = rest[..<authorityEnd]
    var tail = rest[authorityEnd...]

    var credentials: Substring?
    var hosts = authority
    if let at = authority.lastIndex(of: "@") {
      credentials = authority[..<at]
      hosts = authority[authority.index(after: at)...]
    }

    let hostList = hosts.split(separator: ",")
    guard let first = hostList.first, !first.isEmpty else { throw ParseError.missingHost }
    let (host, port) = splitHostPort(first)
    guard !host.isEmpty else { throw ParseError.missingHost }

    var link = ConnectionLink(engine: engine, host: host)
    link.port = port
    if let credentials {
      if let colon = credentials.firstIndex(of: ":") {
        link.username = decoded(credentials[..<colon])
        link.password = decoded(credentials[credentials.index(after: colon)...])
      } else {
        link.username = decoded(credentials)
      }
    }

    var query = Substring("")
    if let mark = tail.firstIndex(of: "?") {
      query = tail[tail.index(after: mark)...]
      tail = tail[..<mark]
    }
    let path = tail.drop { $0 == "/" }
    if !path.isEmpty { link.database = decoded(path) }

    for pair in query.split(separator: "&") {
      let parts = pair.split(separator: "=", maxSplits: 1)
      let key = parts[0].lowercased()
      let value = parts.count > 1 ? decoded(parts[1]) ?? "" : ""
      switch (engine, key) {
      case (.mongodb, "authsource"): link.authSource = value
      case (.mongodb, "directconnection"): link.directConnection = value.lowercased() == "true"
      case (.mongodb, "tls"), (.mongodb, "ssl"):
        if value.lowercased() == "true" { link.warning = encryptionWarning }
      case (.postgresql, "sslmode"):
        if ["require", "verify-ca", "verify-full"].contains(value.lowercased()) {
          link.warning = encryptionWarning
        }
      case (.postgresql, "user"): link.username = value
      case (.postgresql, "password"): link.password = value
      case (.postgresql, "dbname"): link.database = value
      default: break
      }
    }
    // The username doubles as nil when the link has an empty one ("redis://:pw@host").
    if link.username?.isEmpty == true { link.username = nil }

    if srv {
      link.warning =
        "Links starting with mongodb+srv:// (MongoDB Atlas and other cloud services) need encrypted connections, which Database doesn’t support yet."
    } else if hostList.count > 1, link.warning == nil {
      link.warning =
        "This link lists \(hostList.count) servers. Database connects to the first one, \(host)."
      link.directConnection = true
    }
    return link
  }

  /// `host`, `host:port`, `[::1]:port`.
  private static func splitHostPort(_ text: Substring) -> (String, Int?) {
    if text.hasPrefix("["), let close = text.firstIndex(of: "]") {
      let host = String(text[text.index(after: text.startIndex)..<close])
      let after = text[text.index(after: close)...]
      return (host, after.hasPrefix(":") ? Int(after.dropFirst()) : nil)
    }
    if let colon = text.lastIndex(of: ":") {
      return (decoded(text[..<colon]) ?? "", Int(text[text.index(after: colon)...]))
    }
    return (decoded(text) ?? "", nil)
  }

  private static func decoded(_ text: Substring) -> String? {
    let string = String(text)
    return string.removingPercentEncoding ?? string
  }
}
