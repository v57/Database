// swift-tools-version: 6.4
import PackageDescription

// Standalone system-library package for libpq. The root `Database` package
// declares the CPostgreSQL systemLibrary target directly (see ../Package.swift);
// this nested manifest documents the pkgConfig and provider metadata in-place.
let package = Package(
    name: "CPostgreSQL",
    targets: [
        .systemLibrary(
            name: "CPostgreSQL",
            pkgConfig: "libpq",
            providers: [
                .brew(["libpq"]),
                .apt(["libpq-dev"]),
            ]
        ),
    ]
)
