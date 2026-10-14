import Foundation

/// Reads connection links people paste (URLs, ADO.NET strings, file paths) into a profile,
/// and writes a profile back out as a URL.
public enum ConnectionLink {
  public struct Parsed: Sendable, Equatable {
    public var profile: ConnectionProfile
    public var password: String?
  }

  /// Recognizes the engine and fills in what the link says. Returns nil if it isn't a link.
  public static func parse(_ raw: String) -> Parsed? {
    var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    if text.isEmpty { return nil }
    if text.lowercased().hasPrefix("jdbc:") { text = String(text.dropFirst(5)) }

    // Plain file paths.
    if text.hasPrefix("/") || text.hasPrefix("~") || text.hasPrefix("file://") {
      let path = text.hasPrefix("file://") ? (URL(string: text)?.path ?? text) : (text as NSString).expandingTildeInPath
      let ext = (path as NSString).pathExtension.lowercased()
      guard let engine = EngineKind.allCases.first(where: { $0.fileExtensions.contains(ext) }) else { return nil }
      return Parsed(profile: ConnectionProfile(engine: engine, filePath: path), password: nil)
    }

    // SQL Server ADO.NET: "Server=tcp:host,1433;Database=db;User Id=sa;Password=…"
    if !text.contains("://"), text.contains("="), text.contains(";") {
      return parseKeyValue(text)
    }

    guard let schemeEnd = text.range(of: "://") else { return nil }
    let scheme = text[..<schemeEnd.lowerBound].lowercased()
    guard let engine = EngineKind.allCases.first(where: { $0.schemes.contains(scheme) }) else { return nil }

    if engine.isFileBased {
      let path = String(text[schemeEnd.upperBound...])
      return Parsed(profile: ConnectionProfile(engine: engine, filePath: path.removingPercentEncoding ?? path), password: nil)
    }

    // URLComponents rejects some real-world links (multi-host, unescaped characters);
    // split by hand instead.
    var rest = String(text[schemeEnd.upperBound...])
    var query = ""
    if let q = rest.firstIndex(of: "?") {
      query = String(rest[rest.index(after: q)...])
      rest = String(rest[..<q])
    }
    var path = ""
    if let slash = rest.firstIndex(of: "/") {
      path = String(rest[rest.index(after: slash)...])
      rest = String(rest[..<slash])
    }
    var user: String?
    var password: String?
    if let at = rest.lastIndex(of: "@") {
      let credentials = rest[..<at]
      rest = String(rest[rest.index(after: at)...])
      if let colon = credentials.firstIndex(of: ":") {
        user = String(credentials[..<colon]).removingPercentEncoding
        password = String(credentials[credentials.index(after: colon)...]).removingPercentEncoding
      } else {
        user = String(credentials).removingPercentEncoding
      }
    }
    // First host of a list; IPv6 in brackets.
    let firstHost = rest.split(separator: ",").first.map(String.init) ?? rest
    var host = firstHost
    var port = engine.defaultPort
    if firstHost.hasPrefix("["), let close = firstHost.firstIndex(of: "]") {
      host = String(firstHost[firstHost.index(after: firstHost.startIndex)..<close])
      let after = firstHost[firstHost.index(after: close)...]
      if after.hasPrefix(":"), let p = Int(after.dropFirst()) { port = p }
    } else if let colon = firstHost.lastIndex(of: ":"), let p = Int(firstHost[firstHost.index(after: colon)...]) {
      host = String(firstHost[..<colon])
      port = p
    }
    if host.isEmpty { host = "127.0.0.1" }

    var options: [String: String] = [:]
    for pair in query.split(separator: "&") {
      let parts = pair.split(separator: "=", maxSplits: 1).map { String($0).removingPercentEncoding ?? String($0) }
      if parts.count == 2 { options[parts[0]] = parts[1] }
    }

    var profile = ConnectionProfile(
      engine: engine, host: host, port: port, user: user ?? engine.defaultUser,
      database: path.removingPercentEncoding ?? path)
    // TLS hints.
    let sslMode = (options["sslmode"] ?? options["ssl"] ?? options["tls"] ?? "").lowercased()
    if scheme == "rediss" || scheme == "mongodb+srv" || ["require", "verify-ca", "verify-full", "true"].contains(sslMode) {
      profile.useTLS = true
    }
    if let authSource = options["authSource"] { profile.options["authSource"] = authSource }
    if engine == .redis, let index = Int(profile.database) { profile.database = String(index) }
    if engine == .cassandra || engine == .scylla, let keyspace = options["keyspace"] { profile.database = keyspace }
    profile.name = profile.database.isEmpty ? host : profile.database.capitalized
    return Parsed(profile: profile, password: password)
  }

  static func parseKeyValue(_ text: String) -> Parsed? {
    var fields: [String: String] = [:]
    for part in text.split(separator: ";") {
      let pair = part.split(separator: "=", maxSplits: 1)
      guard pair.count == 2 else { continue }
      fields[pair[0].trimmingCharacters(in: .whitespaces).lowercased()] = pair[1].trimmingCharacters(in: .whitespaces)
    }
    guard let server = fields["server"] ?? fields["data source"] ?? fields["address"] else { return nil }
    var host = server.replacingOccurrences(of: "tcp:", with: "")
    var port = 1433
    if let comma = host.firstIndex(of: ",") {
      port = Int(host[host.index(after: comma)...]) ?? 1433
      host = String(host[..<comma])
    }
    let database = fields["database"] ?? fields["initial catalog"] ?? ""
    var profile = ConnectionProfile(
      engine: .sqlserver, host: host, port: port, user: fields["user id"] ?? fields["uid"] ?? fields["user"] ?? "sa",
      database: database)
    profile.name = database.isEmpty ? host : database
    return Parsed(profile: profile, password: fields["password"] ?? fields["pwd"])
  }

  /// A link for the profile (without the password).
  public static func url(for profile: ConnectionProfile) -> String {
    let engine = profile.engine
    if engine.isFileBased { return "\(engine.schemes[0])://\(profile.filePath)" }
    var scheme = engine.schemes[0]
    if engine == .redis && profile.useTLS { scheme = "rediss" }
    let user = profile.user.addingPercentEncoding(withAllowedCharacters: .urlUserAllowed) ?? profile.user
    let credentials = user.isEmpty ? "" : "\(user)@"
    let host = profile.host.contains(":") ? "[\(profile.host)]" : profile.host
    let database = profile.database.isEmpty ? "" : "/\(profile.database)"
    var link = "\(scheme)://\(credentials)\(host):\(profile.port)\(database)"
    if profile.useTLS && engine == .postgres { link += "?sslmode=require" }
    return link
  }
}
