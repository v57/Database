// swift-tools-version: 6.4
import PackageDescription

// Standalone system-library package for hiredis. The root `Database` package
// declares the CHiredis systemLibrary target directly (see ../Package.swift);
// this nested manifest documents the pkgConfig and provider metadata in-place.
let package = Package(
    name: "CHiredis",
    targets: [
        .systemLibrary(
            name: "CHiredis",
            pkgConfig: "hiredis",
            providers: [
                .brew(["hiredis"]),
                .apt(["libhiredis-dev"]),
            ]
        ),
    ]
)
