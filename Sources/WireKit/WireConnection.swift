import Foundation
import Network

/// How a client wraps its TCP stream in TLS. Only "TLS from the first byte" is
/// possible here; protocols that upgrade mid-stream are tunneled over SSH instead.
public struct TLSSettings: Sendable, Equatable {
  public var enabled: Bool
  /// Accept self-signed or otherwise untrusted certificates.
  public var allowUntrusted: Bool
  /// Application protocol names (ALPN), e.g. "postgresql".
  public var alpn: [String]

  public init(enabled: Bool = false, allowUntrusted: Bool = false, alpn: [String] = []) {
    self.enabled = enabled
    self.allowUntrusted = allowUntrusted
    self.alpn = alpn
  }

  public static let off = TLSSettings()
}

/// A byte stream a wire client talks over: a TCP connection of its own (`WireConnection.connect`), or one another
/// transport carries, like an SSH channel (`WireChannel`).
public protocol WireStream: AnyObject, Sendable {
  /// Sends all of `bytes`.
  func send(_ bytes: [UInt8]) async throws
  /// The next bytes to arrive (at least one); throws `WireError.closed` once the other side has finished.
  func receive() async throws -> [UInt8]
  var isOpen: Bool { get }
  func close()
}

/// A byte stream with an internal read buffer, over any `WireStream`.
///
/// Not thread-safe by itself: every wire client owns one and calls it from a
/// single actor, so sends and reads never interleave.
public final class WireConnection: @unchecked Sendable {
  public let stream: any WireStream
  private var buffer: [UInt8] = []
  private var bufferStart = 0

  public init(stream: any WireStream) {
    self.stream = stream
  }

  /// Opens a TCP connection and waits until it is ready.
  public static func connect(
    host: String, port: Int, tls: TLSSettings = .off, timeout: TimeInterval = 15
  ) async throws -> WireConnection {
    guard let nwPort = NWEndpoint.Port(rawValue: UInt16(clamping: port)), port > 0 else {
      throw WireError.connectionFailed("invalid port \(port)")
    }
    let stream = try await NetworkStream.connect(
      to: .hostPort(host: NWEndpoint.Host(host), port: nwPort), tls: tls, serverName: host, timeout: timeout,
      describing: "\(host):\(port)")
    return WireConnection(stream: stream)
  }

  public func send(_ bytes: [UInt8]) async throws {
    try await stream.send(bytes)
  }

  private var buffered: Int { buffer.count - bufferStart }

  private func fill(atLeast n: Int) async throws {
    while buffered < n {
      let chunk = try await stream.receive()
      if bufferStart > 0 && bufferStart > buffer.count / 2 {
        buffer.removeFirst(bufferStart)
        bufferStart = 0
      }
      buffer.append(contentsOf: chunk)
    }
  }

  /// Reads exactly `n` bytes.
  public func read(exactly n: Int) async throws -> [UInt8] {
    if n == 0 { return [] }
    try await fill(atLeast: n)
    let out = Array(buffer[bufferStart..<bufferStart + n])
    bufferStart += n
    if bufferStart == buffer.count {
      buffer.removeAll(keepingCapacity: true)
      bufferStart = 0
    }
    return out
  }

  /// Reads at least one byte, returning everything buffered.
  public func readAvailable() async throws -> [UInt8] {
    try await fill(atLeast: 1)
    let out = Array(buffer[bufferStart...])
    buffer.removeAll(keepingCapacity: true)
    bufferStart = 0
    return out
  }

  /// Reads up to and including the next CRLF, returning the line without it.
  public func readLine() async throws -> String {
    var searchFrom = bufferStart
    while true {
      if let index = indexOfCRLF(from: searchFrom) {
        let line = String(decoding: buffer[bufferStart..<index], as: UTF8.self)
        bufferStart = index + 2
        return line
      }
      searchFrom = max(bufferStart, buffer.count - 1)
      let chunk = try await stream.receive()
      buffer.append(contentsOf: chunk)
    }
  }

  private func indexOfCRLF(from start: Int) -> Int? {
    var i = start
    while i + 1 < buffer.count {
      if buffer[i] == 13 && buffer[i + 1] == 10 { return i }
      i += 1
    }
    return nil
  }

  public var isOpen: Bool { stream.isOpen }

  public func close() {
    stream.close()
  }

  deinit { stream.close() }
}

/// A Network.framework connection: TCP to a host, or a Unix socket (`connect(over:…)`), with optional TLS.
final class NetworkStream: WireStream, @unchecked Sendable {
  private let connection: NWConnection
  private let queue: DispatchQueue
  private let lock = NSLock()
  private var isClosed = false

  private init(connection: NWConnection, queue: DispatchQueue) {
    self.connection = connection
    self.queue = queue
  }

  /// Opens a connection and waits until it is ready.
  static func connect(
    to endpoint: NWEndpoint, tls: TLSSettings, serverName: String, timeout: TimeInterval, describing: String
  ) async throws -> NetworkStream {
    let tcp = NWProtocolTCP.Options()
    if case .hostPort = endpoint {
      tcp.noDelay = true
      tcp.connectionTimeout = Int(timeout.rounded(.up))
    }
    let parameters: NWParameters
    if tls.enabled {
      let tlsOptions = NWProtocolTLS.Options()
      let sec = tlsOptions.securityProtocolOptions
      sec_protocol_options_set_tls_server_name(sec, serverName)
      for name in tls.alpn { sec_protocol_options_add_tls_application_protocol(sec, name) }
      if tls.allowUntrusted {
        sec_protocol_options_set_verify_block(sec, { _, _, complete in complete(true) }, .global())
      }
      parameters = NWParameters(tls: tlsOptions, tcp: tcp)
    } else {
      parameters = NWParameters(tls: nil, tcp: tcp)
    }
    let queue = DispatchQueue(label: "WireKit.connection.\(describing)")
    let stream = NetworkStream(connection: NWConnection(to: endpoint, using: parameters), queue: queue)
    try await stream.waitUntilReady(timeout: timeout, describing: describing)
    return stream
  }

  private func waitUntilReady(timeout: TimeInterval, describing endpoint: String) async throws {
    let once = ResumeOnce()
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
      connection.stateUpdateHandler = { [connection] state in
        switch state {
        case .ready:
          if once.claim() { continuation.resume() }
        case .failed(let error):
          if once.claim() { continuation.resume(throwing: WireError.connectionFailed(Self.describe(error))) }
        case .waiting(let error):
          // "Waiting" means the path or the peer refused; don't sit retrying.
          if once.claim() {
            connection.cancel()
            continuation.resume(throwing: WireError.connectionFailed(Self.describe(error)))
          }
        case .cancelled:
          if once.claim() { continuation.resume(throwing: WireError.closed) }
        default:
          break
        }
      }
      connection.start(queue: queue)
      queue.asyncAfter(deadline: .now() + timeout) { [connection] in
        if once.claim() {
          connection.cancel()
          continuation.resume(throwing: WireError.timedOut("connecting to \(endpoint)"))
        }
      }
    }
    connection.stateUpdateHandler = { [weak self] state in
      switch state {
      case .failed, .cancelled: self?.markClosed()
      default: break
      }
    }
  }

  private func markClosed() {
    lock.lock()
    isClosed = true
    lock.unlock()
  }

  static func describe(_ error: NWError) -> String {
    switch error {
    case .posix(let code):
      switch code {
      case .ECONNREFUSED: return "nothing is listening there (connection refused)"
      case .ETIMEDOUT: return "the server didn't answer in time"
      case .EHOSTUNREACH, .ENETUNREACH: return "the host can't be reached"
      default: return String(cString: strerror(code.rawValue))
      }
    case .dns(let code): return "the host name couldn't be found (DNS error \(code))"
    case .tls(let status): return "the encrypted connection failed (TLS status \(status))"
    default: return error.localizedDescription
    }
  }

  func send(_ bytes: [UInt8]) async throws {
    if !isOpen { throw WireError.closed }
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
      connection.send(
        content: Data(bytes),
        completion: .contentProcessed { error in
          if let error {
            continuation.resume(throwing: WireError.connectionFailed(Self.describe(error)))
          } else {
            continuation.resume()
          }
        })
    }
  }

  func receive() async throws -> [UInt8] {
    if !isOpen { throw WireError.closed }
    while true {
      let chunk = try await withCheckedThrowingContinuation {
        (continuation: CheckedContinuation<[UInt8], Error>) in
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 16) { data, _, isComplete, error in
          if let data, !data.isEmpty {
            continuation.resume(returning: [UInt8](data))
          } else if let error {
            continuation.resume(throwing: WireError.connectionFailed(Self.describe(error)))
          } else if isComplete {
            continuation.resume(throwing: WireError.closed)
          } else {
            continuation.resume(returning: [])
          }
        }
      }
      if !chunk.isEmpty { return chunk }
    }
  }

  var isOpen: Bool {
    lock.lock()
    defer { lock.unlock() }
    return !isClosed
  }

  func close() {
    markClosed()
    connection.cancel()
  }

  deinit { connection.cancel() }
}

/// Lets exactly one of several racing callbacks resume a continuation.
public final class ResumeOnce: @unchecked Sendable {
  private let lock = NSLock()
  private var done = false
  public init() {}
  public func claim() -> Bool {
    lock.lock()
    defer { lock.unlock() }
    if done { return false }
    done = true
    return true
  }
}
