#if !os(Windows)
import Darwin
import Foundation
import Network

extension WireConnection {
  /// TLS over a stream that Network.framework can't open itself, like an SSH channel.
  ///
  /// Network.framework only adds TLS to connections it makes, so it gets the stream through a Unix socket in a
  /// private temporary folder. The socket takes one connection, only from this process, and is deleted as soon as
  /// that arrives: there's no port, and nothing another app or user can connect to.
  public static func connect(
    over stream: any WireStream, serverName: String, tls: TLSSettings, timeout: TimeInterval = 15
  ) async throws -> WireConnection {
    let socket: LocalSocket
    do {
      socket = try LocalSocket()
    } catch {
      stream.close()
      throw error
    }
    // The handshake needs the relay running, so it starts as soon as Network.framework connects.
    let relay = Task {
      let fd = try await socket.acceptFromThisProcess(timeout: timeout)
      SocketRelay.start(fd: fd, stream: stream)
    }
    do {
      let secure = try await NetworkStream.connect(
        to: .unix(path: socket.path), tls: tls, serverName: serverName, timeout: timeout, describing: serverName)
      try await relay.value
      return WireConnection(stream: secure)
    } catch {
      socket.cancel()
      stream.close()
      throw error
    }
  }
}

/// A Unix socket that accepts one connection from this process, in a folder only this user can open.
private final class LocalSocket: @unchecked Sendable {
  let path: String
  private let folder: String
  private let fd: Int32
  private let lock = NSLock()
  private var cancelled = false

  init() throws {
    var template = Array((NSTemporaryDirectory() as NSString).appendingPathComponent("wire.XXXXXX").utf8CString)
    guard mkdtemp(&template) != nil else { throw WireError.connectionFailed("couldn't make a folder for TLS") }
    let folder = String(cString: template)
    let path = folder + "/s"
    var address = sockaddr_un()
    guard path.utf8.count < MemoryLayout.size(ofValue: address.sun_path) else {
      rmdir(folder)
      throw WireError.connectionFailed("the temporary folder's path is too long for a socket")
    }
    address.sun_family = sa_family_t(AF_UNIX)
    address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
    withUnsafeMutableBytes(of: &address.sun_path) { raw in
      raw.copyBytes(from: path.utf8)
      raw[path.utf8.count] = 0
    }
    let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
    let bound = withUnsafePointer(to: &address) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
    }
    guard fd >= 0, bound == 0, listen(fd, 1) == 0 else {
      if fd >= 0 { Darwin.close(fd) }
      unlink(path)
      rmdir(folder)
      throw WireError.connectionFailed("couldn't open a socket for TLS")
    }
    self.folder = folder
    self.path = path
    self.fd = fd
  }

  func cancel() {
    lock.lock()
    cancelled = true
    lock.unlock()
  }

  private var isCancelled: Bool {
    lock.lock()
    defer { lock.unlock() }
    return cancelled
  }

  /// The first connection from this process. Connections from other processes are closed unanswered.
  func acceptFromThisProcess(timeout: TimeInterval) async throws -> Int32 {
    try await withCheckedThrowingContinuation { continuation in
      Thread.detachNewThread { [self] in
        defer { removeSocket() }
        let deadline = Date().addingTimeInterval(timeout)
        while !isCancelled && Date() < deadline {
          var ready = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
          guard poll(&ready, 1, 100) > 0 else { continue }
          let client = Darwin.accept(fd, nil, nil)
          if client < 0 { continue }
          if Self.peerProcess(client) == getpid() {
            var one: Int32 = 1
            setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
            continuation.resume(returning: client)
            return
          }
          Darwin.close(client)
        }
        continuation.resume(throwing: isCancelled ? WireError.closed : WireError.timedOut("starting TLS"))
      }
    }
  }

  private static func peerProcess(_ fd: Int32) -> pid_t {
    var pid: pid_t = 0
    var length = socklen_t(MemoryLayout<pid_t>.size)
    return getsockopt(fd, SOL_LOCAL, LOCAL_PEERPID, &pid, &length) == 0 ? pid : -1
  }

  private func removeSocket() {
    Darwin.close(fd)
    unlink(path)
    rmdir(folder)
  }
}

/// Moves bytes between a socket and a stream until either side ends, on two threads of its own (socket calls block).
private enum SocketRelay {
  static func start(fd: Int32, stream: any WireStream) {
    let socket = SharedSocket(fd, users: 2)
    // Socket → stream.
    Thread.detachNewThread {
      var buffer = [UInt8](repeating: 0, count: 64 * 1024)
      while true {
        let n = buffer.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
        if n < 0 && errno == EINTR { continue }
        guard n > 0 else { break }
        let chunk = Array(buffer[0..<n])
        guard wait({ try await stream.send(chunk) }) != nil else { break }
      }
      stream.close()
      socket.release()
    }
    // Stream → socket.
    Thread.detachNewThread {
      while let bytes = wait({ try await stream.receive() }), writeAll(fd, bytes) {}
      shutdown(fd, SHUT_WR)
      socket.release()
    }
  }

  /// Runs `operation` and blocks this thread until it's done; nil if it threw.
  private static func wait<T: Sendable>(_ operation: @escaping @Sendable () async throws -> T) -> T? {
    let result = ResultBox<T>()
    let done = DispatchSemaphore(value: 0)
    Task {
      result.value = try? await operation()
      done.signal()
    }
    done.wait()
    return result.value
  }

  private static func writeAll(_ fd: Int32, _ bytes: [UInt8]) -> Bool {
    var offset = 0
    while offset < bytes.count {
      let n = bytes.withUnsafeBytes { Darwin.write(fd, $0.baseAddress! + offset, bytes.count - offset) }
      if n < 0 && errno == EINTR { continue }
      guard n > 0 else { return false }
      offset += n
    }
    return true
  }
}

private final class ResultBox<T>: @unchecked Sendable {
  var value: T?
}

/// Closes the socket once every thread using it is done.
private final class SharedSocket: @unchecked Sendable {
  private let fd: Int32
  private let lock = NSLock()
  private var users: Int

  init(_ fd: Int32, users: Int) {
    self.fd = fd
    self.users = users
  }

  func release() {
    lock.lock()
    users -= 1
    let last = users == 0
    lock.unlock()
    if last { Darwin.close(fd) }
  }
}
#else
import Foundation
import Network

extension WireConnection {
  /// TLS over a stream it didn't open, like an SSH channel: on Windows SChannel's `TLSSession` (the Network
  /// stand-in's) runs over the stream itself.
  public static func connect(
    over stream: any WireStream, serverName: String, tls: TLSSettings, timeout: TimeInterval = 15
  ) async throws -> WireConnection {
    WireConnection(stream: try await TLSWireStream.start(over: stream, serverName: serverName, tls: tls))
  }
}

/// A stream that encrypts what it sends and decrypts what it receives over another stream. SSPI's calls block,
/// so the handshake and each read run on a thread of their own and wait for the inner stream there.
private final class TLSWireStream: WireStream, @unchecked Sendable {
  private let inner: any WireStream
  private let session: TLSSession

  private init(inner: any WireStream, session: TLSSession) {
    self.inner = inner
    self.session = session
  }

  static func start(over inner: any WireStream, serverName: String, tls: TLSSettings) async throws -> TLSWireStream {
    try await withCheckedThrowingContinuation { continuation in
      Thread.detachNewThread {
        do {
          let session = try TLSSession.connect(
            serverName: serverName, alpn: tls.alpn, allowUntrusted: tls.allowUntrusted,
            write: { data in try Self.blocking { try await inner.send(Array(data)) } },
            read: { try Self.receive(from: inner) })
          continuation.resume(returning: TLSWireStream(inner: inner, session: session))
        } catch {
          inner.close()
          continuation.resume(throwing: error)
        }
      }
    }
  }

  func send(_ bytes: [UInt8]) async throws {
    try await inner.send(Array(try session.encrypt(Data(bytes))))
  }

  func receive() async throws -> [UInt8] {
    let (session, inner) = (session, inner)
    return try await withCheckedThrowingContinuation { continuation in
      Thread.detachNewThread {
        do {
          let data = try session.decrypt(read: { try Self.receive(from: inner) })
          if data.isEmpty { throw WireError.closed }
          continuation.resume(returning: Array(data))
        } catch {
          continuation.resume(throwing: error)
        }
      }
    }
  }

  var isOpen: Bool { inner.isOpen }

  func close() { inner.close() }

  /// The inner stream's next bytes, empty at its end.
  private static func receive(from inner: any WireStream) throws -> Data {
    do {
      return Data(try blocking { try await inner.receive() })
    } catch WireError.closed {
      return Data()
    }
  }

  /// Runs `operation` and blocks this thread until it's done.
  private static func blocking<T: Sendable>(_ operation: @escaping @Sendable () async throws -> T) throws -> T {
    let box = ResultBox<T>()
    let done = DispatchSemaphore(value: 0)
    Task {
      do { box.result = .success(try await operation()) } catch { box.result = .failure(error) }
      done.signal()
    }
    done.wait()
    return try box.result!.get()
  }
}

private final class ResultBox<T>: @unchecked Sendable {
  var result: Result<T, Error>?
}
#endif
