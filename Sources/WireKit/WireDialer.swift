import Foundation

/// How a wire client reaches its server: over a TCP connection of its own (`direct`), or over streams something
/// else opens, like the channels of an SSH connection that's already logged in (`streams`). An SSH-tunneled client
/// then talks to the SSH session directly, with no local port that other apps or users could connect to.
public struct WireDialer: Sendable {
  private let dial: @Sendable (_ host: String, _ port: Int, _ tls: TLSSettings, _ timeout: TimeInterval) async throws
    -> WireConnection
  /// Whether what it dials travels inside something encrypted (an SSH channel), so a login may send a password the
  /// server asks for in the clear.
  public let isTunnel: Bool

  public init(
    isTunnel: Bool = false,
    _ dial: @escaping @Sendable (_ host: String, _ port: Int, _ tls: TLSSettings, _ timeout: TimeInterval)
      async throws -> WireConnection
  ) {
    self.isTunnel = isTunnel
    self.dial = dial
  }

  /// Whether a login to `host` over this dialer, with `tls`, can send a password readably: through a tunnel, over TLS,
  /// or to this device itself. Otherwise a cleartext or MD5 login is refused unless the connection allows it
  /// (security audit M9).
  public func protects(host: String, tls: TLSSettings) -> Bool {
    isTunnel || tls.enabled || Self.isLoopback(host)
  }

  /// `localhost`, `127.x.x.x` and `::1`: a server on this device, where nothing crosses the network.
  public static func isLoopback(_ host: String) -> Bool {
    let name = host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
    return name == "localhost" || name == "::1" || name.hasPrefix("127.") || name == "0:0:0:0:0:0:0:1"
  }

  /// A connection to `host:port` (as the dialer sees it: through SSH, the SSH server resolves the name).
  public func connect(host: String, port: Int, tls: TLSSettings = .off, timeout: TimeInterval = 15) async throws
    -> WireConnection
  {
    try await dial(host, port, tls, timeout)
  }

  /// TCP from this device.
  public static let direct = WireDialer { host, port, tls, timeout in
    try await WireConnection.connect(host: host, port: port, tls: tls, timeout: timeout)
  }

  /// Streams from `open` (say, an SSH channel to `host:port`), with TLS on top when the client asks for it.
  public static func streams(
    _ open: @escaping @Sendable (_ host: String, _ port: Int, _ timeout: TimeInterval) async throws -> any WireStream
  ) -> WireDialer {
    WireDialer(isTunnel: true) { host, port, tls, timeout in
      let stream = try await open(host, port, timeout)
      guard tls.enabled else { return WireConnection(stream: stream) }
      #if canImport(Darwin) || os(Windows) || os(Linux)
        return try await WireConnection.connect(over: stream, serverName: host, tls: tls, timeout: timeout)
      #else
        // StreamTLS has no TLS engine here yet (Network.framework on Apple platforms, SChannel on Windows, OpenSSL
        // on Linux).
        stream.close()
        throw WireError.unsupported("TLS over an SSH channel isn't available on this system yet")
      #endif
    }
  }
}
