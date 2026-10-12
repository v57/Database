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

/// A TCP (optionally TLS) byte stream with an internal read buffer.
///
/// Not thread-safe by itself: every wire client owns one and calls it from a
/// single actor, so sends and reads never interleave.
public final class WireConnection: @unchecked Sendable {
  private let connection: NWConnection
  private let queue: DispatchQueue
  private var buffer: [UInt8] = []
  private var bufferStart = 0
  private var isClosed = false

  private init(connection: NWConnection, queue: DispatchQueue) {
    self.connection = connection
    self.queue = queue
  }

  /// Opens a connection and waits until it is ready.
  public static func connect(
    host: String, port: Int, tls: TLSSettings = .off, timeout: TimeInterval = 15
  ) async throws -> WireConnection {
    guard let nwPort = NWEndpoint.Port(rawValue: UInt16(clamping: port)), port > 0 else {
      throw WireError.connectionFailed("invalid port \(port)")
    }
    let tcp = NWProtocolTCP.Options()
    tcp.noDelay = true
    tcp.connectionTimeout = Int(timeout.rounded(.up))
    let parameters: NWParameters
    if tls.enabled {
      let tlsOptions = NWProtocolTLS.Options()
      let sec = tlsOptions.securityProtocolOptions
      sec_protocol_options_set_tls_server_name(sec, host)
      for name in tls.alpn { sec_protocol_options_add_tls_application_protocol(sec, name) }
      if tls.allowUntrusted {
        sec_protocol_options_set_verify_block(sec, { _, _, complete in complete(true) }, .global())
      }
      parameters = NWParameters(tls: tlsOptions, tcp: tcp)
    } else {
      parameters = NWParameters(tls: nil, tcp: tcp)
    }
    let queue = DispatchQueue(label: "WireKit.connection.\(host):\(port)")
    let nw = NWConnection(host: NWEndpoint.Host(host), port: nwPort, using: parameters)
    let wire = WireConnection(connection: nw, queue: queue)
    try await wire.waitUntilReady(timeout: timeout, describing: "\(host):\(port)")
    return wire
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
      if case .failed = state { self?.isClosed = true }
      if case .cancelled = state { self?.isClosed = true }
    }
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

  public func send(_ bytes: [UInt8]) async throws {
    if isClosed { throw WireError.closed }
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

  /// Reads whatever arrives next (at least one byte).
  private func receiveChunk() async throws -> [UInt8] {
    if isClosed { throw WireError.closed }
    return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<[UInt8], Error>) in
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
  }

  private var buffered: Int { buffer.count - bufferStart }

  private func fill(atLeast n: Int) async throws {
    while buffered < n {
      let chunk = try await receiveChunk()
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
      let chunk = try await receiveChunk()
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

  public var isOpen: Bool { !isClosed }

  public func close() {
    isClosed = true
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
