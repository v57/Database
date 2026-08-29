// swift-tools-version: 6.4
import PackageDescription

// Standalone system-library package for libmongoc/libbson. The root `Database`
// package declares the CMongoC systemLibrary target directly (see ../Package.swift);
// this nested manifest documents the pkgConfig and provider metadata in-place.
let package = Package(
    name: "CMongoC",
    targets: [
        .systemLibrary(
            name: "CMongoC",
            pkgConfig: "mongoc2",
            providers: [
                .brew(["mongo-c-driver"]),
                .apt(["libmongoc-dev"]),
            ]
        ),
    ]
)
