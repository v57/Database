// swift-tools-version: 6.4

import PackageDescription

let package = Package(
  name: "Database",
  products: [
    .library(name: "Database", targets: ["Database"]),
    .library(name: "MongoDB", targets: ["MongoDB"]),
    .library(name: "PostgreSQL", targets: ["PostgreSQL"]),
    .library(name: "Redis", targets: ["Redis"]), .library(name: "SQLite", targets: ["SQLite"]),
    .library(name: "CPostgreSQL", targets: ["CPostgreSQL"]),
    .library(name: "CMongoC", targets: ["CMongoC"]),
    .library(name: "CHiredis", targets: ["CHiredis"]),
  ],
  targets: [
    .target(name: "Database", swiftSettings: [.enableUpcomingFeature("ApproachableConcurrency")]),
    .systemLibrary(name: "CPostgreSQL", pkgConfig: "libpq", providers: [.brew(["libpq"]), .apt(["libpq-dev"])]),
    .systemLibrary(name: "CMongoC", pkgConfig: "mongoc2", providers: [.brew(["mongo-c-driver"]), .apt(["libmongoc-dev"])]),
    .systemLibrary(name: "CHiredis", pkgConfig: "hiredis", providers: [.brew(["hiredis"]), .apt(["libhiredis-dev"])]),
    .target(
      name: "MongoDB",
      dependencies: ["CMongoC"], swiftSettings: [.enableUpcomingFeature("ApproachableConcurrency")]),
    .target(
      name: "PostgreSQL",
      dependencies: ["CPostgreSQL"], swiftSettings: [.enableUpcomingFeature("ApproachableConcurrency")]),
    .target(
      name: "Redis",
      dependencies: ["CHiredis"], swiftSettings: [.enableUpcomingFeature("ApproachableConcurrency")]),
    .target(name: "SQLite", swiftSettings: [.enableUpcomingFeature("ApproachableConcurrency")]),
    .testTarget(
      name: "DatabaseTests", dependencies: ["Database"],
      swiftSettings: [.enableUpcomingFeature("ApproachableConcurrency")]),
    .testTarget(
      name: "MongoDBTests",
      dependencies: ["MongoDB"],
      swiftSettings: [.enableUpcomingFeature("ApproachableConcurrency")]),
    .testTarget(
      name: "PostgreSQLTests", dependencies: ["PostgreSQL"],
      swiftSettings: [.enableUpcomingFeature("ApproachableConcurrency")]),
    .testTarget(
      name: "RedisTests", dependencies: ["Redis"],
      swiftSettings: [.enableUpcomingFeature("ApproachableConcurrency")]),
    .testTarget(
      name: "SQLiteTests", dependencies: ["SQLite"],
      swiftSettings: [.enableUpcomingFeature("ApproachableConcurrency")]),
  ])
