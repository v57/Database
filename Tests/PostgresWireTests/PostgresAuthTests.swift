import Foundation
import PostgresWire
import Testing
import WireKit

/// A server, or someone on the network, asking for the password in cleartext or as MD5 gets nothing on a connection
/// with neither SSH nor TLS, unless the connection allows insecure logins (security audit M9). No server needed.
@Suite struct PostgresAuthTests {
  static let password = "s3cret-pw"

  static func message(_ type: Character, _ body: [UInt8]) -> [UInt8] {
    let length = UInt32(body.count + 4)
    return [type.asciiValue!] + [24, 16, 8, 0].map { UInt8(truncatingIfNeeded: length >> $0) } + body
  }

  static func authRequest(_ code: UInt8, extra: [UInt8] = []) -> [UInt8] { message("R", [0, 0, 0, code] + extra) }

  /// Asks for the password with `code` (3 cleartext, 5 MD5), then lets the client in if it answers.
  static func server(asking code: UInt8) -> ScriptedServer {
    ScriptedServer { server in
      guard let header = server.read(4) else { return }
      let length = header.reduce(0) { $0 << 8 | Int($1) }
      guard server.read(length - 4) != nil else { return }
      server.send(authRequest(code, extra: code == 5 ? [1, 2, 3, 4] : []))
      guard let type = server.read(5), type.first == UInt8(ascii: "p") else { return }
      let bodyLength = type.dropFirst().reduce(0) { $0 << 8 | Int($1) } - 4
      guard server.read(bodyLength) != nil else { return }
      server.send(authRequest(0) + message("Z", [UInt8(ascii: "I")]))
    }
  }

  static func config(_ server: ScriptedServer, host: String = "db.example.com", isTunnel: Bool = false)
    -> PostgresClient.Config
  {
    PostgresClient.Config(
      host: host, user: "app", password: password, dialer: server.dialer(isTunnel: isTunnel))
  }

  static func sentPassword(_ server: ScriptedServer) -> Bool {
    let sent = server.received
    let needle = Array(password.utf8)
    return sent.indices.contains { sent[$0...].starts(with: needle) }
  }

  @Test func refusesCleartextRequest() async throws {
    let server = Self.server(asking: 3)
    await #expect(throws: WireError.insecureLogin(WireError.cleartextPassword)) {
      try await PostgresClient.connect(Self.config(server))
    }
    #expect(!Self.sentPassword(server))
  }

  @Test func refusesMD5Request() async throws {
    let server = Self.server(asking: 5)
    await #expect(throws: WireError.insecureLogin(WireError.md5Password)) {
      try await PostgresClient.connect(Self.config(server))
    }
  }

  @Test func answersCleartextThroughATunnel() async throws {
    let server = Self.server(asking: 3)
    let client = try await PostgresClient.connect(Self.config(server, isTunnel: true))
    await client.close()
    #expect(Self.sentPassword(server))
  }

  @Test func answersCleartextOnThisDevice() async throws {
    let server = Self.server(asking: 3)
    let client = try await PostgresClient.connect(Self.config(server, host: "127.0.0.1"))
    await client.close()
  }

  @Test func answersCleartextWhenTheConnectionAllowsIt() async throws {
    let server = Self.server(asking: 5)
    var config = Self.config(server)
    config.allowsInsecureLogin = true
    let client = try await PostgresClient.connect(config)
    await client.close()
  }
}

/// A server played by a script on its own thread, over a `WireChannel` (no socket): it reads what the client sends
/// and answers, the way a hostile server or someone between would.
final class ScriptedServer: @unchecked Sendable {
  let channel: WireChannel
  private let woken = DispatchSemaphore(value: 0)
  private let lock = NSLock()
  private var pending: [UInt8] = []
  private var all: [UInt8] = []

  init(_ script: @escaping @Sendable (ScriptedServer) -> Void) {
    let woken = self.woken
    channel = WireChannel { woken.signal() }
    Thread.detachNewThread { [self] in script(self) }
  }

  /// The next `count` bytes the client sent; nil when it closed or after 5 s.
  func read(_ count: Int) -> [UInt8]? {
    let deadline = Date().addingTimeInterval(5)
    while Date() < deadline {
      let taken = lock.withLock { () -> [UInt8]? in
        let outbound = channel.takeOutbound()
        pending += outbound
        all += outbound
        guard pending.count >= count else { return nil }
        defer { pending.removeFirst(count) }
        return Array(pending.prefix(count))
      }
      if let taken { return taken }
      if channel.isClosedByApp { return nil }
      _ = woken.wait(timeout: .now() + 0.05)
    }
    return nil
  }

  func send(_ bytes: [UInt8]) { channel.deliver(bytes) }

  /// Everything the client sent so far.
  var received: [UInt8] {
    lock.withLock {
      let outbound = channel.takeOutbound()
      pending += outbound
      all += outbound
      return all
    }
  }

  /// A dialer that reaches this server whatever host it's given; `isTunnel` as an SSH channel's is.
  func dialer(isTunnel: Bool = false) -> WireDialer {
    let channel = channel
    return WireDialer(isTunnel: isTunnel) { _, _, _, _ in WireConnection(stream: channel) }
  }
}
