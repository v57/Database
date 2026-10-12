// swift-tools-version: 6.2

import Foundation
import PackageDescription

let concurrency: [SwiftSetting] = [.enableUpcomingFeature("ApproachableConcurrency")]

// libssh2 + mbedTLS (module CLibssh2). Scripts/build-libssh2.sh makes it from Shell's build; it isn't in git, so a
// checkout without Binary/ downloads it from GitHub Releases (Scripts/release-binaries.sh publishes it).
let libssh2: Target =
  FileManager.default.fileExists(atPath: Context.packageDirectory + "/Binary/Libssh2.xcframework")
  ? .binaryTarget(name: "Libssh2", path: "Binary/Libssh2.xcframework")
  : .binaryTarget(
    name: "Libssh2", url: "https://github.com/v57/DatabasePro/releases/download/libssh2-1.11.1/Libssh2.xcframework.zip",
    checksum: "4496b3ce72eb7d049e5f3e37a0c13cc12df86d0cde27eba1262676de63bf4261")

let package = Package(
  name: "DatabasePro",
  platforms: [.macOS(.v14), .iOS(.v17)],
  products: [
    .library(name: "DatabaseCore", targets: ["DatabaseCore"]),
    .library(name: "SSHTunnel", targets: ["SSHTunnel"]),
  ],
  dependencies: [
    // Embedded DuckDB, compiled from source so it runs on iOS too.
    .package(url: "https://github.com/duckdb/duckdb-swift", exact: "1.1.3")
  ],
  targets: [
    libssh2,

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
      name: "DuckDBKit", dependencies: ["WireKit", .product(name: "DuckDB", package: "duckdb-swift")],
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
