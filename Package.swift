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
  "Libssh2", release: "libssh2-1.11.1", checksum: "b855ccebd64a0434cb1d59b1c1376676682a3fc48fde829b837881307abcea98")
// The DuckDB C library with parquet, json and icu built in (module Cduckdb).
let duckdb = binary(
  "Cduckdb", release: "duckdb-1.5.6", checksum: "9aa3f2c56dc5f8dfed035fa46bde1d99d3beaac8876745bace6f0fc768691aa7")

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
