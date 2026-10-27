// swift-tools-version: 6.2

import Foundation
import PackageDescription

let concurrency: [SwiftSetting] = [.enableUpcomingFeature("ApproachableConcurrency")]

/// Another v57 repository: GitHub's main branch, or the checkout next to this one with `V57_LOCAL=1`.
func v57(_ name: String) -> Package.Dependency {
  Context.environment["V57_LOCAL"] == nil
    ? .package(url: "https://github.com/v57/\(name).git", branch: "main") : .package(path: "../\(name)")
}

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
    // libssh2 + mbedTLS (../SSH's), for Shell, which links this copy instead of building its own.
    .library(name: "Libssh2", targets: ["Libssh2Exports"]),
    // The app's interface (connection tree, browsers, query tabs, pipelines, inspector, sheets), for this app and
    // Shell's database connections.
    .library(name: "DatabaseUI", targets: ["DatabaseUI"]),
  ],
  // SSHKit: logins, keys, SFTP, commands and libssh2 (Scripts/build-libssh2.sh still makes the prebuilt libssh2 and
  // Scripts/release-binaries.sh publishes it on this repository's releases, which ../SSH downloads).
  dependencies: [v57("SSH"), v57("Component"), v57("Vault"), v57("Code")],
  targets: [
    .target(name: "Libssh2Exports", dependencies: [.product(name: "Libssh2", package: "SSH")]),

    // Byte streams, buffers and the hashes the wire protocols share.
    .target(name: "WireKit", swiftSettings: concurrency),
    // Local port forwarding over SSH (direct-tcpip) on SSHKit's logins; re-exports SSHKit.
    .target(
      name: "SSHTunnel", dependencies: [.product(name: "SSHKit", package: "SSH"), "WireKit"], swiftSettings: concurrency),

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

    // The interface on DatabaseKit: ComponentKit's design, the vault's shared connections and accounts, and Code's
    // highlighting.
    .target(
      name: "DatabaseUI",
      dependencies: [
        "DatabaseKit", "SSHTunnel", .product(name: "ComponentKit", package: "Component"),
        .product(name: "VaultKit", package: "Vault"), .product(name: "VaultUI", package: "Vault"),
        .product(name: "CodeHighlighting", package: "Code"),
      ],
      swiftSettings: [
        .swiftLanguageMode(.v5), .defaultIsolation(MainActor.self), .enableUpcomingFeature("ApproachableConcurrency"),
        .enableUpcomingFeature("MemberImportVisibility"),
      ]),

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
// Off Apple platforms CryptoKit, Network, SQLite3 and os are v57/SwiftUI's stand-ins, RSA is swift-crypto's
// _CryptoExtras (Security.framework's on Apple platforms), and ../SSH builds libssh2 from source in place of the
// prebuilt xcframework.
package.dependencies += [
  v57("SwiftUI"), .package(url: "https://github.com/apple/swift-crypto.git", "3.0.0"..<"5.0.0"),
]
let swiftUI: [String: [Target.Dependency]] = [
  "WireKit": [.product(name: "CryptoKit", package: "SwiftUI"), .product(name: "Network", package: "SwiftUI")],
  "MySQLWire": [.product(name: "_CryptoExtras", package: "swift-crypto")],
  "SQLiteKit": [.product(name: "SQLite3", package: "SwiftUI")],
  "DuckDBKit": [.product(name: "CryptoKit", package: "SwiftUI")],
  "DatabaseUI": [.product(name: "SwiftUI", package: "SwiftUI"), .product(name: "CryptoKit", package: "SwiftUI")],
]
for target in package.targets {
  target.dependencies += swiftUI[target.name] ?? []
  if target.type == .regular, target.name != "Libssh2Exports", target.name != "Cduckdb" {
    target.dependencies += [
      .product(name: "SwiftUIPortability", package: "SwiftUI"), .product(name: "os", package: "SwiftUI"),
    ]
  }
  // URLSession lives in FoundationNetworking, Apple's Foundation extras (`URL.applicationSupportDirectory`, …)
  // in SwiftUIPortability: imported everywhere, as Foundation is on Apple platforms.
  if target.type == .regular || target.type == .test, target.name != "Libssh2Exports", target.name != "Cduckdb" {
    // The interface also uses Combine's names, as SwiftUI brings them on Apple platforms.
    let modules = (target.name == "DatabaseUI" ? ["Combine"] : []) + ["FoundationNetworking", "SwiftUIPortability"]
    target.swiftSettings = (target.swiftSettings ?? []) + [
      .unsafeFlags(modules.flatMap { ["-Xfrontend", "-import-module", "-Xfrontend", $0] })
    ]
  }
}
#if os(Windows)
// The app: a DLL the SwiftUI WinUI host loads (SwiftUI's Windows/scripts/build-app.ps1 -PackagePath <this package>
// -Product DatabaseWinUI), built from the Xcode project's sources (the app's scene on DatabaseUI) with its settings.
package.dependencies += [v57("UpdateKit"), v57("Dev")]
package.targets.append(
  .target(
    name: "DatabaseApp",
    dependencies: [
      "DatabaseUI", "DatabaseKit", .product(name: "SwiftUI", package: "SwiftUI"),
      .product(name: "ComponentKit", package: "Component"), .product(name: "UpdateKit", package: "UpdateKit"),
      .product(name: "VaultKit", package: "Vault"), .product(name: "VaultUI", package: "Vault"),
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
