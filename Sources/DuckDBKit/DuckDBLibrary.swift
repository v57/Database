import Cduckdb
import Foundation

#if os(Windows)
  import WinSDK
#endif

/// The DuckDB build Database downloads when asked: a signed `libduckdb.dylib` for Apple silicon Macs, published
/// by `Scripts/release-binaries.sh duckdb` (which also updates `DuckDBLibrary.release` below).
public struct DuckDBRelease: Sendable, Equatable {
  public var version: String
  public var url: URL
  /// SHA-256 of the zip, checked before anything is installed.
  public var sha256: String
  /// The zip's size in bytes, for the download prompt and progress.
  public var size: Int64

  public init(version: String, url: URL, sha256: String, size: Int64) {
    self.version = version
    self.url = url
    self.sha256 = sha256
    self.size = size
  }
}

/// Where the optional DuckDB library lives on disk, and the C API once it's loaded.
///
/// The app ships without DuckDB (it would be 90 % of the binary). `DuckDBInstaller` downloads the release into
/// `directory`; `DuckDBFile` opens it with `dlopen` on first use. macOS only: iOS can't load downloaded code.
public enum DuckDBLibrary {
  public static let release = DuckDBRelease(
    version: "1.5.6",
    url: URL(string: "https://github.com/v57/Database/releases/download/duckdb-1.5.6/libduckdb-macos-arm64.zip")!,
    sha256: "d40f95691b49c7f3ca9e5735bf8e1e6ad85255a8ff75c9680d85a22d35dd55f5",
    size: 15300007)

  /// The folder holding `libduckdb.dylib` and `VERSION`. Defaults to the app's data folder; the app sets it when it
  /// keeps its data elsewhere (a development run with `--data-dir`), and tests point it elsewhere with
  /// `DATABASE_DUCKDB_DIR`.
  nonisolated(unsafe) public static var directory: URL =
    ProcessInfo.processInfo.environment["DATABASE_DUCKDB_DIR"].map { URL(fileURLWithPath: $0, isDirectory: true) }
    ?? URL.applicationSupportDirectory
    .appendingPathComponent("dev.v57.db", isDirectory: true)
    .appendingPathComponent("DuckDB", isDirectory: true)

  public static var libraryURL: URL { libraryURL(in: directory) }
  static func libraryURL(in folder: URL) -> URL { folder.appendingPathComponent("libduckdb.dylib") }
  static func versionURL(in folder: URL) -> URL { folder.appendingPathComponent("VERSION") }

  /// Whether this platform can load a downloaded library at all.
  public static var isSupported: Bool {
    #if os(macOS)
      true
    #else
      false
    #endif
  }

  public static var isInstalled: Bool { isInstalled(in: directory) }

  static func isInstalled(in folder: URL) -> Bool {
    isSupported && FileManager.default.fileExists(atPath: libraryURL(in: folder).path)
  }

  /// The version written at install time, if the library is installed.
  public static var installedVersion: String? { installedVersion(in: directory) }

  static func installedVersion(in folder: URL) -> String? {
    guard isInstalled(in: folder) else { return nil }
    return (try? String(contentsOf: versionURL(in: folder), encoding: .utf8))?
      .trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private static let lock = NSLock()
  nonisolated(unsafe) private static var loaded: DuckDBAPI?

  /// Whether the library is mapped into this process. A removed library stays usable until the app quits.
  public static var isLoaded: Bool { lock.withLock { loaded != nil } }

  /// The C API, loading the library the first time.
  static func api() throws -> DuckDBAPI {
    try lock.withLock {
      if let loaded { return loaded }
      guard isSupported else { throw DuckDBError(message: "DuckDB isn't available on this device.") }
      guard isInstalled else { throw DuckDBError.notInstalled }
      let api = try DuckDBAPI(path: libraryURL.path)
      loaded = api
      return api
    }
  }

  /// Deletes the installed library. If it's loaded, it keeps working until the app quits.
  public static func remove() throws { try remove(from: directory) }

  static func remove(from folder: URL) throws {
    guard FileManager.default.fileExists(atPath: folder.path) else { return }
    try FileManager.default.removeItem(at: folder)
  }
}

extension DuckDBError {
  public static let notInstalled = DuckDBError(
    message: "DuckDB isn't installed. Download it from the connection sheet or in Settings.")
}

/// DuckDB's C functions, resolved with `dlsym` so nothing is linked at build time. The signatures mirror `duckdb.h`.
struct DuckDBAPI: @unchecked Sendable {
  let handle: UnsafeMutableRawPointer

  let library_version: @convention(c) () -> UnsafePointer<CChar>?

  let create_config: @convention(c) (UnsafeMutablePointer<duckdb_config?>?) -> duckdb_state
  let destroy_config: @convention(c) (UnsafeMutablePointer<duckdb_config?>?) -> Void
  let set_config: @convention(c) (duckdb_config?, UnsafePointer<CChar>?, UnsafePointer<CChar>?) -> duckdb_state
  let open_ext:
    @convention(c) (
      UnsafePointer<CChar>?, UnsafeMutablePointer<duckdb_database?>?, duckdb_config?,
      UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?
    ) -> duckdb_state
  let close: @convention(c) (UnsafeMutablePointer<duckdb_database?>?) -> Void
  let connect: @convention(c) (duckdb_database?, UnsafeMutablePointer<duckdb_connection?>?) -> duckdb_state
  let disconnect: @convention(c) (UnsafeMutablePointer<duckdb_connection?>?) -> Void
  let free: @convention(c) (UnsafeMutableRawPointer?) -> Void

  let query: @convention(c) (duckdb_connection?, UnsafePointer<CChar>?, UnsafeMutablePointer<duckdb_result>?) -> duckdb_state
  let destroy_result: @convention(c) (UnsafeMutablePointer<duckdb_result>?) -> Void
  let result_error: @convention(c) (UnsafeMutablePointer<duckdb_result>?) -> UnsafePointer<CChar>?
  let column_count: @convention(c) (UnsafeMutablePointer<duckdb_result>?) -> idx_t
  let column_name: @convention(c) (UnsafeMutablePointer<duckdb_result>?, idx_t) -> UnsafePointer<CChar>?
  let column_logical_type: @convention(c) (UnsafeMutablePointer<duckdb_result>?, idx_t) -> duckdb_logical_type?
  let fetch_chunk: @convention(c) (duckdb_result) -> duckdb_data_chunk?

  let destroy_data_chunk: @convention(c) (UnsafeMutablePointer<duckdb_data_chunk?>?) -> Void
  let data_chunk_get_size: @convention(c) (duckdb_data_chunk?) -> idx_t
  let data_chunk_get_vector: @convention(c) (duckdb_data_chunk?, idx_t) -> duckdb_vector?
  let vector_get_data: @convention(c) (duckdb_vector?) -> UnsafeMutableRawPointer?
  let vector_get_validity: @convention(c) (duckdb_vector?) -> UnsafeMutablePointer<UInt64>?
  let validity_row_is_valid: @convention(c) (UnsafeMutablePointer<UInt64>?, idx_t) -> Bool
  let list_vector_get_child: @convention(c) (duckdb_vector?) -> duckdb_vector?
  let struct_vector_get_child: @convention(c) (duckdb_vector?, idx_t) -> duckdb_vector?
  let string_t_length: @convention(c) (duckdb_string_t) -> UInt32
  let string_t_data: @convention(c) (UnsafeMutablePointer<duckdb_string_t>?) -> UnsafePointer<CChar>?

  let destroy_logical_type: @convention(c) (UnsafeMutablePointer<duckdb_logical_type?>?) -> Void
  let get_type_id: @convention(c) (duckdb_logical_type?) -> duckdb_type
  let decimal_width: @convention(c) (duckdb_logical_type?) -> UInt8
  let decimal_scale: @convention(c) (duckdb_logical_type?) -> UInt8
  let decimal_internal_type: @convention(c) (duckdb_logical_type?) -> duckdb_type
  let enum_internal_type: @convention(c) (duckdb_logical_type?) -> duckdb_type
  let enum_dictionary_value: @convention(c) (duckdb_logical_type?, idx_t) -> UnsafeMutablePointer<CChar>?
  let list_type_child_type: @convention(c) (duckdb_logical_type?) -> duckdb_logical_type?
  let struct_type_child_count: @convention(c) (duckdb_logical_type?) -> idx_t
  let struct_type_child_name: @convention(c) (duckdb_logical_type?, idx_t) -> UnsafeMutablePointer<CChar>?
  let struct_type_child_type: @convention(c) (duckdb_logical_type?, idx_t) -> duckdb_logical_type?
  let union_type_member_type: @convention(c) (duckdb_logical_type?, idx_t) -> duckdb_logical_type?

  /// Opens the library at `path`. With the hardened runtime, dyld only accepts a library signed by the app's team.
  init(path: String) throws {
    #if os(Windows)
      guard let module = path.withCString(encodedAs: UTF16.self, { LoadLibraryW($0) }) else {
        throw DuckDBError(message: "Couldn't load DuckDB: error \(GetLastError())")
      }
      let handle = UnsafeMutableRawPointer(module)
      func address(_ name: String) -> UnsafeMutableRawPointer? {
        GetProcAddress(module, name).map { unsafeBitCast($0, to: UnsafeMutableRawPointer.self) }
      }
    #else
      guard let handle = dlopen(path, RTLD_NOW | RTLD_LOCAL) else {
        let reason = dlerror().map { String(cString: $0) } ?? "unknown error"
        throw DuckDBError(message: "Couldn't load DuckDB: \(reason)")
      }
      func address(_ name: String) -> UnsafeMutableRawPointer? { dlsym(handle, name) }
    #endif
    self.handle = handle
    func symbol<T>(_ name: String) throws -> T {
      guard let pointer = address(name) else {
        throw DuckDBError(message: "The installed DuckDB library has no \(name). Remove it in Settings and download it again.")
      }
      return unsafeBitCast(pointer, to: T.self)
    }
    library_version = try symbol("duckdb_library_version")
    create_config = try symbol("duckdb_create_config")
    destroy_config = try symbol("duckdb_destroy_config")
    set_config = try symbol("duckdb_set_config")
    open_ext = try symbol("duckdb_open_ext")
    close = try symbol("duckdb_close")
    connect = try symbol("duckdb_connect")
    disconnect = try symbol("duckdb_disconnect")
    free = try symbol("duckdb_free")
    query = try symbol("duckdb_query")
    destroy_result = try symbol("duckdb_destroy_result")
    result_error = try symbol("duckdb_result_error")
    column_count = try symbol("duckdb_column_count")
    column_name = try symbol("duckdb_column_name")
    column_logical_type = try symbol("duckdb_column_logical_type")
    fetch_chunk = try symbol("duckdb_fetch_chunk")
    destroy_data_chunk = try symbol("duckdb_destroy_data_chunk")
    data_chunk_get_size = try symbol("duckdb_data_chunk_get_size")
    data_chunk_get_vector = try symbol("duckdb_data_chunk_get_vector")
    vector_get_data = try symbol("duckdb_vector_get_data")
    vector_get_validity = try symbol("duckdb_vector_get_validity")
    validity_row_is_valid = try symbol("duckdb_validity_row_is_valid")
    list_vector_get_child = try symbol("duckdb_list_vector_get_child")
    struct_vector_get_child = try symbol("duckdb_struct_vector_get_child")
    string_t_length = try symbol("duckdb_string_t_length")
    string_t_data = try symbol("duckdb_string_t_data")
    destroy_logical_type = try symbol("duckdb_destroy_logical_type")
    get_type_id = try symbol("duckdb_get_type_id")
    decimal_width = try symbol("duckdb_decimal_width")
    decimal_scale = try symbol("duckdb_decimal_scale")
    decimal_internal_type = try symbol("duckdb_decimal_internal_type")
    enum_internal_type = try symbol("duckdb_enum_internal_type")
    enum_dictionary_value = try symbol("duckdb_enum_dictionary_value")
    list_type_child_type = try symbol("duckdb_list_type_child_type")
    struct_type_child_count = try symbol("duckdb_struct_type_child_count")
    struct_type_child_name = try symbol("duckdb_struct_type_child_name")
    struct_type_child_type = try symbol("duckdb_struct_type_child_type")
    union_type_member_type = try symbol("duckdb_union_type_member_type")
  }

  /// "1.5.6", as the library reports it.
  var version: String { library_version().map { String(cString: $0).replacingOccurrences(of: "v", with: "") } ?? "?" }
}
