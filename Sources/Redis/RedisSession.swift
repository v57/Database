import Foundation
import CHiredis

/// Owns a hiredis `redisContext` and a private serial DispatchQueue. Every C
/// call — connect, command, free — runs on that queue and is bridged to
/// async/await with a checked continuation, so no blocking Redis socket I/O
/// ever touches the MainActor. A single connection's calls are serialized by
/// the queue, which is exactly what hiredis's blocking context expects.
///
/// `@unchecked Sendable`: the context is only mutated from `queue` (a serial
/// DispatchQueue), and every access goes through the continuation bridge.
final class RedisSession: @unchecked Sendable {
  private let queue = DispatchQueue(label: "dev.v57.database.redis", qos: .userInitiated)
  private var context: UnsafeMutablePointer<redisContext>?
  private let lock = NSLock()

  var isConnected: Bool {
    lock.lock(); defer { lock.unlock() }
    return context != nil
  }

  /// Opens (and AUTHs) a connection, returns the PING reply string.
  func connect(
    host: String, port: UInt16, username: String?, password: String?,
    databaseIndex: Int?
  ) async throws -> String {
    try await withCheckedThrowingContinuation { continuation in
      queue.async {
        var tv = timeval(tv_sec: 5, tv_usec: 0)
        guard let rawCtx = redisConnectWithTimeout(host, Int32(port), tv) else {
          continuation.resume(throwing: RedisError.server("Redis: connection failed"))
          return
        }
        if rawCtx.pointee.err != 0 {
          let msg = Self.errorString(rawCtx)
          redisFree(rawCtx)
          continuation.resume(throwing: RedisError.server("Redis: \(msg)"))
          return
        }
        // AUTH: ACL username+password, or password-only.
        var ok = true
        var authError = ""
        if let user = username, !user.isEmpty {
          if let reply = Self.command(rawCtx, ["AUTH", user, password ?? ""]) {
            if case .error(let e) = reply { ok = false; authError = e }
          } else { ok = false; authError = Self.errorString(rawCtx) }
        } else if let pass = password, !pass.isEmpty {
          if let reply = Self.command(rawCtx, ["AUTH", pass]) {
            if case .error(let e) = reply { ok = false; authError = e }
          } else { ok = false; authError = Self.errorString(rawCtx) }
        }
        if !ok {
          redisFree(rawCtx)
          continuation.resume(throwing: RedisError.server("Redis AUTH failed: \(authError)"))
          return
        }
        let ping: String
        if let reply = Self.command(rawCtx, ["PING"]) {
          if case .error(let e) = reply {
            redisFree(rawCtx)
            continuation.resume(throwing: RedisError.server("Redis PING failed: \(e)"))
            return
          }
          ping = reply.stringValue
        } else {
          let msg = Self.errorString(rawCtx)
          redisFree(rawCtx)
          continuation.resume(throwing: RedisError.server("Redis PING failed: \(msg)"))
          return
        }
        // SELECT the configured database index, if any.
        if let index = databaseIndex {
          if let reply = Self.command(rawCtx, ["SELECT", String(index)]),
             case .error(let e) = reply {
            redisFree(rawCtx)
            continuation.resume(throwing: RedisError.server("Redis SELECT \(index) failed: \(e)"))
            return
          }
        }
        self.lock.lock()
        self.context = rawCtx
        self.lock.unlock()
        continuation.resume(returning: ping)
      }
    }
  }

  func disconnect() async {
    await withCheckedContinuation { continuation in
      queue.async {
        self.lock.lock()
        let ctx = self.context
        self.context = nil
        self.lock.unlock()
        if let ctx { redisFree(ctx) }
        continuation.resume()
      }
    }
  }

  /// Runs one command on the background queue and returns the parsed reply.
  func command(_ args: [String]) async throws -> RedisReply {
    try await withCheckedThrowingContinuation { continuation in
      queue.async {
        self.lock.lock()
        let ctx = self.context
        self.lock.unlock()
        guard let ctx else {
          continuation.resume(throwing: RedisError.notConnected)
          return
        }
        guard let reply = Self.command(ctx, args) else {
          continuation.resume(throwing: RedisError.server("Redis: \(Self.errorString(ctx))"))
          return
        }
        if case .error(let e) = reply {
          continuation.resume(throwing: RedisError.server(e))
          return
        }
        continuation.resume(returning: reply)
      }
    }
  }

  /// Executes `redisCommandArgv` synchronously (must be called on `queue`),
  /// parses the reply, frees it, and returns a value type.
  private static func command(
    _ ctx: UnsafeMutablePointer<redisContext>, _ args: [String]
  ) -> RedisReply? {
    var cArgs = args.map { UnsafeMutablePointer<CChar>(strdup($0)) }
    defer { for p in cArgs { if let p { free(p) } } }
    var argv: [UnsafePointer<CChar>?] = cArgs.map { $0.map { UnsafePointer($0) } }
    var argvlen = args.map { $0.utf8.count }
    let raw = argv.withUnsafeMutableBufferPointer { ab in
      argvlen.withUnsafeMutableBufferPointer { lb in
        redisCommandArgv(ctx, Int32(args.count), ab.baseAddress!, lb.baseAddress!)
      }
    }
    guard let ptr = raw else {
      return nil  // caller reads ctx.err via errorString
    }
    let reply = ptr.assumingMemoryBound(to: redisReply.self)
    defer { freeReplyObject(reply) }
    return Self.parse(reply)
  }

  private static func parse(_ reply: UnsafeMutablePointer<redisReply>) -> RedisReply {
    switch reply.pointee.type {
    case REDIS_REPLY_STATUS:
      return .status(cstring(reply.pointee.str) ?? "")
    case REDIS_REPLY_STRING:
      return .string(cstring(reply.pointee.str) ?? "")
    case REDIS_REPLY_INTEGER:
      return .integer(reply.pointee.integer)
    case REDIS_REPLY_NIL:
      return .nilReply
    case REDIS_REPLY_ERROR:
      return .error(cstring(reply.pointee.str) ?? "unknown error")
    case REDIS_REPLY_ARRAY:
      var parts: [RedisReply] = []
      parts.reserveCapacity(Int(reply.pointee.elements))
      for i in 0..<reply.pointee.elements {
        if let el = reply.pointee.element?[i] {
          parts.append(parse(el))
        }
      }
      return .array(parts)
    default:
      return .error("unsupported redis reply type \(reply.pointee.type)")
    }
  }

  private static func cstring(_ p: UnsafeMutablePointer<CChar>?) -> String? {
    p.map { String(cString: $0) }
  }

  private static func errorString(_ ctx: UnsafeMutablePointer<redisContext>) -> String {
    let bytes = withUnsafeBytes(of: &ctx.pointee.errstr) { raw in
      let b = UnsafeBufferPointer<UInt8>(
        start: raw.baseAddress!.assumingMemoryBound(to: UInt8.self), count: raw.count)
      let z = b.firstIndex(of: 0) ?? b.count
      return String(decoding: b.prefix(z), as: UTF8.self)
    }
    return bytes.isEmpty ? "connection failed (err \(ctx.pointee.err))" : bytes
  }
}
