import Foundation
import Testing
import WireKit

/// TLS over a stream Network.framework didn't open, against `openssl s_server` with a throwaway certificate.
struct StreamTLSTests {
  static let openssl = ["/opt/homebrew/bin/openssl", "/usr/bin/openssl"].first {
    FileManager.default.isExecutableFile(atPath: $0)
  }

  @Test(.enabled(if: openssl != nil, "needs openssl"))
  func speaksTLSOverAnotherStream() async throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("tls-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let key = folder.appendingPathComponent("key.pem").path
    let cert = folder.appendingPathComponent("cert.pem").path
    try run(
      ["req", "-x509", "-newkey", "rsa:2048", "-nodes", "-days", "1", "-subj", "/CN=localhost", "-keyout", key,
       "-out", cert])
    let port = Int.random(in: 40_000..<50_000)
    let server = Process()
    server.executableURL = URL(fileURLWithPath: Self.openssl!)
    server.arguments = ["s_server", "-accept", "127.0.0.1:\(port)", "-cert", cert, "-key", key, "-www", "-quiet"]
    server.standardOutput = FileHandle.nullDevice
    server.standardError = FileHandle.nullDevice
    try server.run()
    defer { server.terminate() }

    // The plain stream stands in for an SSH channel.
    var plain: WireConnection?
    for _ in 0..<50 where plain == nil {
      plain = try? await WireConnection.connect(host: "127.0.0.1", port: port, timeout: 1)
      if plain == nil { try await Task.sleep(for: .milliseconds(100)) }
    }
    let stream = try #require(plain).stream
    let secure = try await WireConnection.connect(
      over: stream, serverName: "localhost", tls: TLSSettings(enabled: true, allowUntrusted: true), timeout: 10)
    try await secure.send(Array("GET / HTTP/1.0\r\n\r\n".utf8))
    #expect(try await secure.readLine().hasPrefix("HTTP/1.0 200"))
    secure.close()

    // Certificates are still checked unless the caller says otherwise.
    let again = try await WireConnection.connect(host: "127.0.0.1", port: port, timeout: 5)
    await #expect(throws: WireError.self) {
      try await WireConnection.connect(over: again.stream, serverName: "localhost", tls: TLSSettings(enabled: true))
    }
  }

  private func run(_ arguments: [String]) throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: Self.openssl!)
    process.arguments = arguments
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    try process.run()
    process.waitUntilExit()
  }
}
