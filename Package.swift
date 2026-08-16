// swift-tools-version: 6.4

import PackageDescription

let package = Package(
    name: "Database",
    products: [
        .library(name: "Database", targets: ["Database"]),
        .library(name: "MongoDB", targets: ["MongoDB"]),
    ],
    dependencies: [
        .package(url: "https://github.com/mongodb/mongo-swift-driver.git", from: "1.3.1"),
        // Explicit NIO dependency: MongoSwift 1.3.1 requires an EventLoopGroup at
        // client creation; importing it transitively is fragile.
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.36.0"),
    ],
    targets: [
        .target(
            name: "Database",
            swiftSettings: [.enableUpcomingFeature("ApproachableConcurrency")]
        ),
        .target(
            name: "MongoDB",
            dependencies: [
                .product(name: "MongoSwift", package: "mongo-swift-driver"),
                .product(name: "NIO", package: "swift-nio"),
            ],
            swiftSettings: [.enableUpcomingFeature("ApproachableConcurrency")]
        ),
        .testTarget(
            name: "DatabaseTests",
            dependencies: ["Database"],
            swiftSettings: [.enableUpcomingFeature("ApproachableConcurrency")]
        ),
        .testTarget(
            name: "MongoDBTests",
            dependencies: [
                "MongoDB",
                .product(name: "MongoSwift", package: "mongo-swift-driver"),
                .product(name: "NIO", package: "swift-nio"),
            ],
            swiftSettings: [.enableUpcomingFeature("ApproachableConcurrency")]
        ),
    ]
)
