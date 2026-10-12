// swift-tools-version: 6.2

import Foundation
import PackageDescription

let concurrency: [SwiftSetting] = [.enableUpcomingFeature("ApproachableConcurrency")]

// Prebuilt C libraries. Scripts/build-libssh2.sh and Scripts/build-duckdb.sh make them in Binary/, which isn't in
// git: a checkout without them downloads the GitHub Releases that Scripts/release-binaries.sh publishes.
func binary(_ name: String, release: String, checksum: String) -> Target {
  let path = "Binary/\(name).xcframework"
  return FileManager.default.fileExists(atPath: Context.packageDirectory + "/" + path)
    ? .binaryTarget(name: name, path: path)
    : .binaryTarget(
      name: name, url: "https://github.com/v57/DatabasePro/releases/download/\(release)/\(name).xcframework.zip",
      checksum: checksum)
}

// libssh2 + mbedTLS (module CLibssh2).
let libssh2 = binary(
  "Libssh2", release: "libssh2-1.11.1", checksum: "4496b3ce72eb7d049e5f3e37a0c13cc12df86d0cde27eba1262676de63bf4261")
// The DuckDB C library with parquet, json and icu built in (module Cduckdb).
let duckdb = binary(
  "Cduckdb", release: "duckdb-1.5.6", checksum: "c427c1018f67ec42ea3ce511f01ea40d7a2ac26a8819c1976a28532680c1faad")

let package = Package(
  name: "DatabasePro",
  platforms: [.macOS(.v14), .iOS(.v17)],
  products: [
    .library(name: "DatabaseCore", targets: ["DatabaseCore"]),
    .library(name: "SSHTunnel", targets: ["SSHTunnel"]),
  ],
  targets: [
    libssh2,
    duckdb,

    // Byte streams, buffers and the hashes the wire protocols share.
    .target(name: "WireKit", swiftSettings: concurrency),
    // Local port forwarding over SSH (direct-tcpip), with key and password login.
    .target(name: "SSHTunnel", dependencies: ["Libssh2", "WireKit"], swiftSettings: concurrency),

    // One pure-Swift client per wire protocol.
    .target(name: "BSON", swiftSettings: concurrency),
    .target(name: "MongoWire", dependencies: ["WireKit", "BSON"], swiftSettings: concurrency),
    .target(name: "PostgresWire", dependencies: ["WireKit"], swiftSettings: concurrency),
    .target(name: "MySQLWire", dependencies: ["WireKit"], swiftSettings: concurrency),
    .target(name: "TDSWire", dependencies: ["WireKit"], swiftSettings: concurrency),
    .target(name: "CQLWire", dependencies: ["WireKit"], swiftSettings: concurrency),
    .target(name: "RedisWire", dependencies: ["WireKit"], swiftSettings: concurrency),
    // File engines.
    .target(name: "SQLiteKit", dependencies: ["WireKit"], swiftSettings: concurrency),
    .target(
      name: "DuckDBKit", dependencies: ["WireKit", "Cduckdb"],
      swiftSettings: concurrency),

    // Engine-neutral model the app talks to: connections, containers, items, edits.
    .target(
      name: "DatabaseCore",
      dependencies: [
        "WireKit", "SSHTunnel", "BSON", "MongoWire", "PostgresWire", "MySQLWire", "TDSWire",
        "CQLWire", "RedisWire", "SQLiteKit", "DuckDBKit",
      ],
      swiftSettings: concurrency),

    .testTarget(name: "WireKitTests", dependencies: ["WireKit"], swiftSettings: concurrency),
    .testTarget(name: "BSONTests", dependencies: ["BSON"], swiftSettings: concurrency),
    .testTarget(
      name: "SSHTunnelTests", dependencies: ["SSHTunnel", "RedisWire", "PostgresWire"], swiftSettings: concurrency),
    .testTarget(name: "MongoWireTests", dependencies: ["MongoWire"], swiftSettings: concurrency),
    .testTarget(name: "PostgresWireTests", dependencies: ["PostgresWire"], swiftSettings: concurrency),
    .testTarget(name: "MySQLWireTests", dependencies: ["MySQLWire"], swiftSettings: concurrency),
    .testTarget(name: "TDSWireTests", dependencies: ["TDSWire"], swiftSettings: concurrency),
    .testTarget(name: "CQLWireTests", dependencies: ["CQLWire"], swiftSettings: concurrency),
    .testTarget(name: "RedisWireTests", dependencies: ["RedisWire"], swiftSettings: concurrency),
    .testTarget(name: "SQLiteKitTests", dependencies: ["SQLiteKit"], swiftSettings: concurrency),
    .testTarget(name: "DuckDBKitTests", dependencies: ["DuckDBKit"], swiftSettings: concurrency),
    .testTarget(name: "DatabaseCoreTests", dependencies: ["DatabaseCore"], swiftSettings: concurrency),
  ]
)
