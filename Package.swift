// swift-tools-version: 6.4

import PackageDescription

let package = Package(
  name: "Database",
  products: [
    .library(name: "Database", targets: ["Database"]),
    .library(name: "MongoDB", targets: ["MongoDB"]),
    .library(name: "SQLQuery", targets: ["SQLQuery"]),
    .library(name: "PostgreSQL", targets: ["PostgreSQL"]),
    .library(name: "Redis", targets: ["Redis"]), .library(name: "SQLite", targets: ["SQLite"]),
    .library(name: "Cdrivers", targets: ["Cdrivers"]),
  ],
  targets: [
    .target(name: "Database", swiftSettings: [.enableUpcomingFeature("ApproachableConcurrency")]),
    .binaryTarget(name: "Cdrivers", path: "Binary/C-drivers/Cdrivers.xcframework"),
    .target(
      name: "MongoDB",
      dependencies: ["Cdrivers"], swiftSettings: [.enableUpcomingFeature("ApproachableConcurrency")]),
    .target(
      name: "PostgreSQL",
      dependencies: ["Cdrivers"], swiftSettings: [.enableUpcomingFeature("ApproachableConcurrency")]),
    .target(
      name: "Redis",
      dependencies: ["Cdrivers"], swiftSettings: [.enableUpcomingFeature("ApproachableConcurrency")]),
    .target(name: "SQLite", swiftSettings: [.enableUpcomingFeature("ApproachableConcurrency")]),
    .target(
      name: "SQLQuery",
      dependencies: ["MongoDB"], swiftSettings: [.enableUpcomingFeature("ApproachableConcurrency")]),
    .testTarget(
      name: "DatabaseTests", dependencies: ["Database"],
      swiftSettings: [.enableUpcomingFeature("ApproachableConcurrency")]),
    .testTarget(
      name: "MongoDBTests",
      dependencies: ["MongoDB"],
      swiftSettings: [.enableUpcomingFeature("ApproachableConcurrency")]),
    .testTarget(
      name: "PostgreSQLTests", dependencies: ["PostgreSQL", "SQLQuery", "MongoDB"],
      swiftSettings: [.enableUpcomingFeature("ApproachableConcurrency")]),
    .testTarget(
      name: "RedisTests", dependencies: ["Redis"],
      swiftSettings: [.enableUpcomingFeature("ApproachableConcurrency")]),
    .testTarget(
      name: "SQLiteTests", dependencies: ["SQLite", "SQLQuery", "MongoDB"],
      swiftSettings: [.enableUpcomingFeature("ApproachableConcurrency")]),
    .testTarget(
      name: "SQLQueryTests", dependencies: ["SQLQuery"],
      swiftSettings: [.enableUpcomingFeature("ApproachableConcurrency")]),
  ])
