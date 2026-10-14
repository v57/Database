import Foundation
import Observation

#if canImport(CryptoKit)
  import CryptoKit
#endif

/// Downloads, verifies and installs the DuckDB library, and says where that stands. Nothing happens until
/// `install()` is called: the app never fetches it on its own.
@MainActor @Observable
public final class DuckDBInstaller {
  public enum State: Equatable, Sendable {
    /// This platform can't load a downloaded library (iOS).
    case unavailable
    case notInstalled
    /// Fraction of the zip received so far.
    case downloading(Double)
    case installing
    /// The installed version.
    case installed(String)
    case failed(String)
  }

  public private(set) var state: State = .notInstalled
  public let release: DuckDBRelease
  /// Where the library goes: `DuckDBLibrary.directory` unless a test picks another folder.
  public let directory: URL
  @ObservationIgnored private var task: Task<Void, Never>?

  public init(release: DuckDBRelease = DuckDBLibrary.release, directory: URL = DuckDBLibrary.directory) {
    self.release = release
    self.directory = directory
    refresh()
  }

  public var isInstalled: Bool {
    if case .installed = state { return true }
    return false
  }

  public var isBusy: Bool {
    switch state {
    case .downloading, .installing: true
    default: false
    }
  }

  /// Whether the installed library is older than `release`.
  public var hasUpdate: Bool {
    if case .installed(let version) = state { return version != release.version }
    return false
  }

  /// Reads the disk again (after another window installed or removed the library).
  public func refresh() {
    guard DuckDBLibrary.isSupported else {
      state = .unavailable
      return
    }
    state =
      DuckDBLibrary.isInstalled(in: directory)
      ? .installed(DuckDBLibrary.installedVersion(in: directory) ?? release.version) : .notInstalled
  }

  /// Downloads `release`, checks its SHA-256 and puts the library in `directory`.
  public func install() {
    guard !isBusy else { return }
    guard DuckDBLibrary.isSupported else {
      state = .unavailable
      return
    }
    state = .downloading(0)
    let release = release
    let directory = directory
    task = Task {
      do {
        try await Self.download(release, into: directory) { fraction in
          Task { @MainActor in
            if case .downloading = self.state { self.state = .downloading(fraction) }
          }
        }
        state = .installing
        try await Self.unpack(release, into: directory)
        refresh()
      } catch is CancellationError {
        refresh()
      } catch let error as URLError where error.code == .cancelled {
        refresh()
      } catch {
        state = .failed((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
      }
      task = nil
    }
  }

  public func cancel() {
    task?.cancel()
  }

  /// Deletes the library. If it's loaded, open DuckDB connections keep working until the app quits.
  public func remove() {
    guard !isBusy else { return }
    do {
      try DuckDBLibrary.remove(from: directory)
      refresh()
    } catch {
      state = .failed((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
    }
  }

  // MARK: - Download and unpack

  private static func downloadedZip(for directory: URL) -> URL {
    directory.deletingLastPathComponent().appendingPathComponent("DuckDB-download.zip")
  }

  /// Fetches the zip next to the install folder, verifying its checksum.
  static func download(
    _ release: DuckDBRelease, into directory: URL, progress: @escaping @Sendable (Double) -> Void
  ) async throws {
    let zip = downloadedZip(for: directory)
    try FileManager.default.createDirectory(at: zip.deletingLastPathComponent(), withIntermediateDirectories: true)
    try? FileManager.default.removeItem(at: zip)
    let delegate = DownloadProgress { written, expected in
      let total = expected > 0 ? expected : release.size
      progress(min(1, Double(written) / Double(max(total, 1))))
    }
    let (file, response) = try await URLSession.shared.download(from: release.url, delegate: delegate)
    if let http = response as? HTTPURLResponse, http.statusCode != 200 {
      try? FileManager.default.removeItem(at: file)
      throw DuckDBError(message: "The download failed (HTTP \(http.statusCode)). Try again later.")
    }
    try FileManager.default.moveItem(at: file, to: zip)
    let digest = try sha256(of: zip)
    guard digest == release.sha256.lowercased() else {
      try? FileManager.default.removeItem(at: zip)
      throw DuckDBError(message: "The downloaded DuckDB didn't match its checksum, so it wasn't installed. Try again.")
    }
  }

  /// Unzips the verified download into `directory` and records the version.
  static func unpack(_ release: DuckDBRelease, into directory: URL) async throws {
    #if os(macOS)
      let zip = downloadedZip(for: directory)
      defer { try? FileManager.default.removeItem(at: zip) }
      let work = FileManager.default.temporaryDirectory.appendingPathComponent("DuckDB-\(UUID().uuidString)")
      try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
      defer { try? FileManager.default.removeItem(at: work) }
      let ditto = Process()
      ditto.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
      ditto.arguments = ["-x", "-k", zip.path, work.path]
      try ditto.run()
      ditto.waitUntilExit()
      guard ditto.terminationStatus == 0 else { throw DuckDBError(message: "Couldn't unpack the DuckDB download.") }
      let unpacked = work.appendingPathComponent("libduckdb.dylib")
      guard FileManager.default.fileExists(atPath: unpacked.path) else {
        throw DuckDBError(message: "The DuckDB download didn't contain libduckdb.dylib.")
      }
      // A downloaded library isn't quarantined like a browser download, but make sure dyld sees a plain file.
      removexattr(unpacked.path, "com.apple.quarantine", 0)
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      let target = DuckDBLibrary.libraryURL(in: directory)
      if FileManager.default.fileExists(atPath: target.path) {
        _ = try FileManager.default.replaceItemAt(target, withItemAt: unpacked)
      } else {
        try FileManager.default.moveItem(at: unpacked, to: target)
      }
      try release.version.write(to: DuckDBLibrary.versionURL(in: directory), atomically: true, encoding: .utf8)
    #else
      throw DuckDBError(message: "DuckDB isn't available on this device.")
    #endif
  }

  static func sha256(of url: URL) throws -> String {
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }
    var hasher = SHA256()
    while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
    return hasher.finalize().map { String(format: "%02x", $0) }.joined()
  }
}

/// Reports download progress for one task.
private final class DownloadProgress: NSObject, URLSessionDownloadDelegate, Sendable {
  let onProgress: @Sendable (Int64, Int64) -> Void
  init(onProgress: @escaping @Sendable (Int64, Int64) -> Void) { self.onProgress = onProgress }

  func urlSession(
    _ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64
  ) {
    onProgress(totalBytesWritten, totalBytesExpectedToWrite)
  }

  // The async `download(from:)` hands the file back itself.
  func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {}
}
