// The installer is macOS-only (DuckDBLibrary.isSupported), and these tests zip with ditto.
#if os(macOS)
import CryptoKit
import DuckDBKit
import Foundation
import Testing

/// Download, checksum and unpack, with the "download" read from a local zip instead of GitHub.
@MainActor
struct DuckDBInstallerTests {
  /// A zip holding a stand-in libduckdb.dylib, and its release description.
  static func fakeRelease(in dir: URL, sha256 override: String? = nil) throws -> DuckDBRelease {
    let staging = dir.appendingPathComponent("staging")
    try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
    try Data("not really a library".utf8).write(to: staging.appendingPathComponent("libduckdb.dylib"))
    let zip = dir.appendingPathComponent("libduckdb-macos-arm64.zip")
    let ditto = Process()
    ditto.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
    ditto.arguments = ["-c", "-k", staging.appendingPathComponent("libduckdb.dylib").path, zip.path]
    try ditto.run()
    ditto.waitUntilExit()
    let data = try Data(contentsOf: zip)
    let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    return DuckDBRelease(version: "9.9.9", url: zip, sha256: override ?? digest, size: Int64(data.count))
  }

  static func scratch() throws -> URL {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("duck-install-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
  }

  static func settle(_ installer: DuckDBInstaller) async {
    for _ in 0..<500 where installer.isBusy { try? await Task.sleep(for: .milliseconds(10)) }
  }

  @Test func installsVerifiedDownloadAndRemovesIt() async throws {
    let dir = try Self.scratch()
    defer { try? FileManager.default.removeItem(at: dir) }
    let target = dir.appendingPathComponent("App/DuckDB")
    let installer = DuckDBInstaller(release: try Self.fakeRelease(in: dir), directory: target)
    #expect(installer.state == .notInstalled)

    installer.install()
    await Self.settle(installer)
    #expect(installer.state == .installed("9.9.9"))
    #expect(!installer.hasUpdate)
    #expect(FileManager.default.fileExists(atPath: target.appendingPathComponent("libduckdb.dylib").path))
    // The downloaded zip doesn't stay behind.
    #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("App/DuckDB-download.zip").path))

    installer.remove()
    #expect(installer.state == .notInstalled)
    #expect(!FileManager.default.fileExists(atPath: target.path))
  }

  @Test func refusesADownloadWithTheWrongChecksum() async throws {
    let dir = try Self.scratch()
    defer { try? FileManager.default.removeItem(at: dir) }
    let target = dir.appendingPathComponent("App/DuckDB")
    let release = try Self.fakeRelease(in: dir, sha256: String(repeating: "0", count: 64))
    let installer = DuckDBInstaller(release: release, directory: target)

    installer.install()
    await Self.settle(installer)
    guard case .failed(let message) = installer.state else {
      Issue.record("Expected a failure, got \(installer.state)")
      return
    }
    #expect(message.contains("checksum"))
    #expect(!FileManager.default.fileExists(atPath: target.path))
  }
}
#endif
