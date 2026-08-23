// swift-tools-version: 6.4

import PackageDescription

let package = Package(
  name: "Database",
  products: [
    .library(name: "Database", targets: ["Database"]),
    .library(name: "MongoDB", targets: ["MongoDB"]),
    .library(name: "PostgreSQL", targets: ["PostgreSQL"]),
    .library(name: "Redis", targets: ["Redis"]),
  ],
  dependencies: [
    .package(url: "https://github.com/mongodb/mongo-swift-driver.git", from: "1.3.1"),
    // Explicit NIO dependency: MongoSwift 1.3.1 requires an EventLoopGroup at
    // client creation; importing it transitively is fragile.
    .package(url: "https://github.com/apple/swift-nio.git", from: "2.36.0"),
    .package(url: "https://github.com/vapor/postgres-nio.git", from: "1.28.0"),
    .package(url: "https://github.com/Mordil/RediStack.git", from: "1.6.3"),
  ],
  targets: [
    .target(name: "Database", swiftSettings: [.enableUpcomingFeature("ApproachableConcurrency")]),
    .target(
      name: "MongoDB",
      dependencies: [
        .product(name: "MongoSwift", package: "mongo-swift-driver"),
        .product(name: "NIO", package: "swift-nio"),
      ], swiftSettings: [.enableUpcomingFeature("ApproachableConcurrency")]),
    .target(
      name: "PostgreSQL",
      dependencies: [.product(name: "PostgresNIO", package: "postgres-nio")],
      swiftSettings: [.enableUpcomingFeature("ApproachableConcurrency")]),
    .target(
      name: "Redis",
      dependencies: [.product(name: "RediStack", package: "RediStack")],
      swiftSettings: [.enableUpcomingFeature("ApproachableConcurrency")]),
    .testTarget(
      name: "DatabaseTests", dependencies: ["Database"],
      swiftSettings: [.enableUpcomingFeature("ApproachableConcurrency")]),
    .testTarget(
      name: "MongoDBTests",
      dependencies: [
        "MongoDB", .product(name: "MongoSwift", package: "mongo-swift-driver"),
        .product(name: "NIO", package: "swift-nio"),
      ], swiftSettings: [.enableUpcomingFeature("ApproachableConcurrency")]),
    .testTarget(
      name: "PostgreSQLTests", dependencies: ["PostgreSQL"],
      swiftSettings: [.enableUpcomingFeature("ApproachableConcurrency")]),
    .testTarget(
      name: "RedisTests", dependencies: ["Redis"],
      swiftSettings: [.enableUpcomingFeature("ApproachableConcurrency")]),
  ])
