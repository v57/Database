import Foundation
import MySQLWire
import Testing
import WireKit

/// A server, or someone on the network, switching the login to `mysql_clear_password` or asking for the full password
/// encrypted to a key it sends gets nothing on a connection without SSH, unless the connection allows insecure logins
/// (security audit M9). No server needed.
@Suite struct MySQLAuthTests {
  static let password = "s3cret-pw"

  static func packet(_ payload: [UInt8], sequence: UInt8) -> [UInt8] {
    [UInt8(payload.count & 0xFF), UInt8(payload.count >> 8 & 0xFF), UInt8(payload.count >> 16 & 0xFF), sequence]
      + payload
  }

  static func greeting(plugin: String) -> [UInt8] {
    var payload: [UInt8] = [10] + Array("8.4.0-fake".utf8) + [0] + [1, 0, 0, 0] + Array("abcdefgh".utf8) + [0]
    payload += [0x05, 0x82, 45, 2, 0, 0x28, 0x00, 21] + [UInt8](repeating: 0, count: 10)
    payload += Array("ijklmnopqrst".utf8) + [0] + Array(plugin.utf8) + [0]
    return packet(payload, sequence: 0)
  }

  /// Reads one packet from the client; nil when it closed.
  static func readPacket(_ server: ScriptedServer) -> [UInt8]? {
    guard let header = server.read(4) else { return nil }
    return server.read(Int(header[0]) | Int(header[1]) << 8 | Int(header[2]) << 16)
  }

  static let ok: [UInt8] = [0x00, 0, 0, 2, 0, 0, 0]

  /// Greets with `plugin`, then sends `next` (an auth switch, a "send the full password") and lets the client in
  /// once it answers.
  static func server(plugin: String, then next: [UInt8]? = nil) -> ScriptedServer {
    ScriptedServer { server in
      server.send(greeting(plugin: plugin))
      guard readPacket(server) != nil else { return }
      if let next {
        server.send(packet(next, sequence: 2))
        guard readPacket(server) != nil else { return }
      }
      server.send(packet(ok, sequence: 4))
    }
  }

  static func config(_ server: ScriptedServer, host: String = "db.example.com", isTunnel: Bool = false)
    -> MySQLClient.Config
  {
    MySQLClient.Config(host: host, user: "app", password: password, dialer: server.dialer(isTunnel: isTunnel))
  }

  static func sentPassword(_ server: ScriptedServer) -> Bool {
    let sent = server.received
    let needle = Array(password.utf8)
    return sent.indices.contains { sent[$0...].starts(with: needle) }
  }

  static let clearSwitch: [UInt8] = [0xFE] + Array("mysql_clear_password".utf8) + [0] + Array("abcdefghijklmnopqrst".utf8) + [0]

  @Test func refusesClearPasswordSwitchWithoutTunnel() async throws {
    let server = Self.server(plugin: "mysql_native_password", then: Self.clearSwitch)
    await #expect(throws: WireError.insecureLogin(WireError.cleartextPassword)) {
      try await MySQLClient.connect(Self.config(server))
    }
    #expect(!Self.sentPassword(server))
  }

  @Test func refusesClearPasswordGreetingWithoutTunnel() async throws {
    let server = Self.server(plugin: "mysql_clear_password")
    await #expect(throws: WireError.insecureLogin(WireError.cleartextPassword)) {
      try await MySQLClient.connect(Self.config(server))
    }
    #expect(!Self.sentPassword(server))
  }

  @Test func refusesServerKeyRequestWithoutTunnel() async throws {
    let server = Self.server(plugin: "caching_sha2_password", then: [0x01, 0x04])
    await #expect(throws: WireError.insecureLogin(WireError.serverKeyPassword)) {
      try await MySQLClient.connect(Self.config(server))
    }
    #expect(!Self.sentPassword(server))
  }

  /// D-007: the refusal says what was asked (the full password, encrypted to a key the server sends), not cleartext.
  @Test func serverKeyRefusalSaysWhatWasAsked() {
    let message = WireError.insecureLogin(WireError.serverKeyPassword).errorDescription ?? ""
    #expect(message.contains("the full password") || message.contains("password in full"))
    #expect(message.contains("encrypted to a key the server sends"))
    #expect(!message.contains("cleartext"))
  }

  @Test func sendsClearPasswordThroughATunnel() async throws {
    let server = Self.server(plugin: "mysql_native_password", then: Self.clearSwitch)
    let client = try await MySQLClient.connect(Self.config(server, isTunnel: true))
    await client.close()
    #expect(Self.sentPassword(server))
  }

  @Test func sendsClearPasswordWhenTheConnectionAllowsIt() async throws {
    let server = Self.server(plugin: "mysql_clear_password")
    var config = Self.config(server)
    config.allowsInsecureLogin = true
    let client = try await MySQLClient.connect(config)
    await client.close()
    #expect(Self.sentPassword(server))
  }

  @Test func nativePasswordStillLogsIn() async throws {
    let server = Self.server(plugin: "mysql_native_password")
    let client = try await MySQLClient.connect(Self.config(server))
    await client.close()
    #expect(!Self.sentPassword(server))
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
