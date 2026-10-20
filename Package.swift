// swift-tools-version: 6.2

import Foundation
import PackageDescription

let concurrency: [SwiftSetting] = [.enableUpcomingFeature("ApproachableConcurrency")]

// Prebuilt C libraries. Scripts/build-libssh2.sh makes them in Binary/, which isn't in git: a checkout without
// them downloads the GitHub Releases that Scripts/release-binaries.sh publishes on this repository.
func binary(_ name: String, release: String, checksum: String) -> Target {
  let path = "Binary/\(name).xcframework"
  return FileManager.default.fileExists(atPath: Context.packageDirectory + "/" + path)
    ? .binaryTarget(name: name, path: path)
    : .binaryTarget(
      name: name, url: "https://github.com/v57/Database/releases/download/\(release)/\(name).xcframework.zip",
      checksum: checksum)
}

// libssh2 + mbedTLS (module CLibssh2).
let libssh2 = binary(
  "Libssh2", release: "libssh2-1.11.1", checksum: "b855ccebd64a0434cb1d59b1c1376676682a3fc48fde829b837881307abcea98")

let package = Package(
  name: "Database",
  platforms: [.macOS(.v14), .iOS(.v17)],
  products: [
    .library(name: "DatabaseKit", targets: ["DatabaseKit"]),
    .library(name: "SSHTunnel", targets: ["SSHTunnel"]),
    // The byte streams the engines talk over, for apps that bring their own transport (Shell's SSH channels).
    .library(name: "WireKit", targets: ["WireKit"]),
    // SQLite files, for Dev's imported translation database.
    .library(name: "SQLiteKit", targets: ["SQLiteKit"]),
    // libssh2 + mbedTLS, for Shell, which links this copy instead of building its own.
    .library(name: "Libssh2", targets: ["Libssh2"]),
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
    // DuckDB's C API header; the library is an optional download that DuckDBKit opens with dlopen (macOS only).
    .target(name: "Cduckdb"),
    .target(name: "DuckDBKit", dependencies: ["WireKit", "Cduckdb"], swiftSettings: concurrency),

    // Engine-neutral model the app talks to: connections, containers, items, edits.
    .target(
      name: "DatabaseKit",
      dependencies: [
        "WireKit", "SSHTunnel", "BSON", "MongoWire", "PostgresWire", "MySQLWire", "TDSWire",
        "CQLWire", "RedisWire", "SQLiteKit", "DuckDBKit",
      ],
      swiftSettings: concurrency),

    .testTarget(name: "WireKitTests", dependencies: ["WireKit"], swiftSettings: concurrency),
    .testTarget(name: "BSONTests", dependencies: ["BSON"], swiftSettings: concurrency),
    .testTarget(
      name: "SSHTunnelTests", dependencies: ["SSHTunnel", "RedisWire", "PostgresWire", "WireKit"], swiftSettings: concurrency),
    .testTarget(name: "MongoWireTests", dependencies: ["MongoWire"], swiftSettings: concurrency),
    .testTarget(name: "PostgresWireTests", dependencies: ["PostgresWire"], swiftSettings: concurrency),
    .testTarget(name: "MySQLWireTests", dependencies: ["MySQLWire"], swiftSettings: concurrency),
    .testTarget(name: "TDSWireTests", dependencies: ["TDSWire"], swiftSettings: concurrency),
    .testTarget(name: "CQLWireTests", dependencies: ["CQLWire"], swiftSettings: concurrency),
    .testTarget(name: "RedisWireTests", dependencies: ["RedisWire"], swiftSettings: concurrency),
    .testTarget(name: "SQLiteKitTests", dependencies: ["SQLiteKit"], swiftSettings: concurrency),
    .testTarget(name: "DuckDBKitTests", dependencies: ["DuckDBKit"], swiftSettings: concurrency),
    .testTarget(name: "DatabaseKitTests", dependencies: ["DatabaseKit"], swiftSettings: concurrency),
  ]
)

#if os(Windows) || os(Linux)
/// Another v57 repository: GitHub's main branch, or the checkout next to this one with `V57_LOCAL=1`.
func v57(_ name: String) -> Package.Dependency {
  Context.environment["V57_LOCAL"] == nil
    ? .package(url: "https://github.com/v57/\(name).git", branch: "main") : .package(path: "../\(name)")
}
// Off Apple platforms CryptoKit, Network, SQLite3 and os are v57/SwiftUI's stand-ins, RSA is swift-crypto's
// _CryptoExtras (Security.framework's on Apple platforms), and libssh2 builds from source (Sources/CLibssh2) with
// the platform's crypto (WinCNG on Windows) in place of the prebuilt xcframework.
package.dependencies += [
  v57("SwiftUI"), .package(url: "https://github.com/apple/swift-crypto.git", "3.0.0"..<"5.0.0"),
]
package.targets.removeAll { $0.name == "Libssh2" }
package.targets.append(
  .target(
    name: "CLibssh2", path: "Sources/CLibssh2",
    exclude: [
      "COPYING", "README.md",
      // crypto.c includes the backend's file, agent.c the Windows agents'.
      "src/openssl.c", "src/libgcrypt.c", "src/mbedtls.c", "src/os400qc3.c", "src/wincng.c", "src/agent_win.c",
    ],
    sources: ["src"],
    // ECDSA (ecdh-sha2-nistp* key exchange, ECDSA host keys) needs Windows 10's BCrypt: OpenSSH 10 servers offer
    // no finite-field Diffie-Hellman, so without it they can't be reached.
    cSettings: [
      .define("LIBSSH2_WINCNG"), .define("LIBSSH2_ECDSA_WINCNG"), .define("LIBSSH2_LIBRARY"), .unsafeFlags(["-w"]),
    ]))
package.products.removeAll { $0.name == "Libssh2" }
package.products.append(.library(name: "Libssh2", targets: ["CLibssh2"]))
let swiftUI: [String: [Target.Dependency]] = [
  "WireKit": [.product(name: "CryptoKit", package: "SwiftUI"), .product(name: "Network", package: "SwiftUI")],
  "SSHTunnel": [
    "CLibssh2", .product(name: "CryptoKit", package: "SwiftUI"), .product(name: "_CryptoExtras", package: "swift-crypto"),
  ],
  "MySQLWire": [.product(name: "_CryptoExtras", package: "swift-crypto")],
  "SQLiteKit": [.product(name: "SQLite3", package: "SwiftUI")],
  "DuckDBKit": [.product(name: "CryptoKit", package: "SwiftUI")],
]
for target in package.targets {
  if target.name == "SSHTunnel" { target.dependencies.removeAll { "\($0)".contains("Libssh2") } }
  target.dependencies += swiftUI[target.name] ?? []
  if target.type == .regular, target.name != "CLibssh2", target.name != "Cduckdb" {
    target.dependencies += [
      .product(name: "SwiftUIPortability", package: "SwiftUI"), .product(name: "os", package: "SwiftUI"),
    ]
  }
  // URLSession lives in FoundationNetworking, Apple's Foundation extras (`URL.applicationSupportDirectory`, …)
  // in SwiftUIPortability: imported everywhere, as Foundation is on Apple platforms.
  if target.type == .regular || target.type == .test, target.name != "CLibssh2", target.name != "Cduckdb" {
    target.swiftSettings = (target.swiftSettings ?? []) + [
      .unsafeFlags(
        ["FoundationNetworking", "SwiftUIPortability"].flatMap { ["-Xfrontend", "-import-module", "-Xfrontend", $0] })
    ]
  }
}
#if os(Windows)
// The app: a DLL the SwiftUI WinUI host loads (SwiftUI's Windows/scripts/build-app.ps1 -PackagePath <this package>
// -Product DatabaseWinUI), built from the Xcode project's sources with its settings.
package.dependencies += [v57("Component"), v57("UpdateKit"), v57("Code"), v57("Dev"), v57("Vault")]
package.targets.append(
  .target(
    name: "DatabaseApp",
    dependencies: [
      "DatabaseKit", "SSHTunnel", .product(name: "SwiftUI", package: "SwiftUI"),
      .product(name: "CryptoKit", package: "SwiftUI"),
      .product(name: "ComponentKit", package: "Component"), .product(name: "UpdateKit", package: "UpdateKit"),
      .product(name: "VaultKit", package: "Vault"), .product(name: "CodeHighlighting", package: "Code"),
      .product(name: "DevScreenshots", package: "Dev"),
    ],
    path: "Database",
    exclude: ["Assets.xcassets", "Database.entitlements", "Database-iOS.entitlements", "Info.plist", "PrivacyInfo.xcprivacy"],
    swiftSettings: [
      .swiftLanguageMode(.v5), .defaultIsolation(MainActor.self), .enableUpcomingFeature("ApproachableConcurrency"),
      .enableUpcomingFeature("MemberImportVisibility"),
      // On Apple platforms `import Foundation` brings URLSession and the file APIs SwiftUIPortability adds along:
      // every file gets them here too.
      .unsafeFlags(
        ["Combine", "FoundationNetworking", "SwiftUIPortability"].flatMap { ["-Xfrontend", "-import-module", "-Xfrontend", $0] }),
    ]))
package.products.append(.library(name: "DatabaseWinUI", type: .dynamic, targets: ["DatabaseApp"]))
#endif
#endif
