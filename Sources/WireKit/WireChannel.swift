import Foundation

/// A byte stream that another thread carries, such as an SSH channel: the app reads and writes it like any
/// `WireStream` (through a `WireConnection`), and the thread that owns the real transport moves the bytes with
/// `takeOutbound`, `deliver` and `finish`. `onActivity` tells that thread there's something to do.
public final class WireChannel: WireStream, @unchecked Sendable {
  /// How much the app may leave unread before the transport stops reading for it, so the transport's flow control
  /// holds the sender back instead of memory filling up.
  public static let inboundLimit = 1 << 20

  private let lock = NSLock()
  private let onActivity: @Sendable () -> Void
  private var inbound: [UInt8] = []
  private var outbound: [UInt8] = []
  private var reader: CheckedContinuation<[UInt8], Error>?
  private var ended = false
  private var endError: WireError?
  private var closedByApp = false

  public init(onActivity: @escaping @Sendable () -> Void) {
    self.onActivity = onActivity
  }

  // MARK: App side

  public func send(_ bytes: [UInt8]) async throws {
    try enqueue(bytes)
    onActivity()
  }

  private func enqueue(_ bytes: [UInt8]) throws {
    lock.lock()
    defer { lock.unlock() }
    if closedByApp || ended { throw endError ?? .closed }
    outbound += bytes
  }

  public func receive() async throws -> [UInt8] {
    try await withCheckedThrowingContinuation { continuation in
      lock.lock()
      if !inbound.isEmpty {
        let bytes = inbound
        let wasFull = inbound.count >= Self.inboundLimit
        inbound = []
        lock.unlock()
        continuation.resume(returning: bytes)
        // The transport stopped reading while the app was behind.
        if wasFull { onActivity() }
      } else if ended || closedByApp {
        let error = endError ?? .closed
        lock.unlock()
        continuation.resume(throwing: error)
      } else {
        reader = continuation
        lock.unlock()
      }
    }
  }

  public var isOpen: Bool {
    lock.lock()
    defer { lock.unlock() }
    return !closedByApp && !ended
  }

  public func close() {
    lock.lock()
    if closedByApp {
      lock.unlock()
      return
    }
    closedByApp = true
    let waiting = reader
    reader = nil
    lock.unlock()
    waiting?.resume(throwing: WireError.closed)
    onActivity()
  }

  // MARK: Transport side

  /// The app closed the stream: the transport can close its end once it has sent what's left (`takeOutbound`).
  public var isClosedByApp: Bool {
    lock.lock()
    defer { lock.unlock() }
    return closedByApp
  }

  /// Whether the transport should read more for the app.
  public var wantsInbound: Bool {
    lock.lock()
    defer { lock.unlock() }
    return !ended && !closedByApp && inbound.count < Self.inboundLimit
  }

  /// Takes what the app has sent since the last call.
  public func takeOutbound() -> [UInt8] {
    lock.lock()
    defer { lock.unlock() }
    let bytes = outbound
    outbound = []
    return bytes
  }

  /// Hands bytes that arrived to the app.
  public func deliver(_ bytes: [UInt8]) {
    guard !bytes.isEmpty else { return }
    lock.lock()
    if closedByApp || ended {
      lock.unlock()
      return
    }
    if let waiting = reader {
      reader = nil
      lock.unlock()
      waiting.resume(returning: bytes)
    } else {
      inbound += bytes
      lock.unlock()
    }
  }

  /// The other side finished (`nil`) or the transport broke: the app reads what's left, then gets `error` (or
  /// `WireError.closed`).
  public func finish(_ error: WireError? = nil) {
    lock.lock()
    if ended {
      lock.unlock()
      return
    }
    ended = true
    endError = error
    let waiting = reader
    reader = nil
    lock.unlock()
    waiting?.resume(throwing: error ?? .closed)
  }
}
