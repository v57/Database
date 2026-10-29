// swift-tools-version: 6.2
// The app, a package of its own beside the libraries (..), so the repositories it depends on can depend on this one's
// libraries without a cycle between packages.

import PackageDescription

/// Another v57 repository: GitHub's main branch, or the checkout next to this one with `V57_LOCAL=1` (in Xcode,
/// open Database-Local.xcworkspace instead).
func v57(_ name: String) -> Package.Dependency {
  Context.environment["V57_LOCAL"] == nil
    ? .package(url: "https://github.com/v57/\(name).git", branch: "main") : .package(path: "../../\(name)")
}

/// This repository's libraries, the package at "..": SwiftPM names a path dependency after its folder, which is Database in
/// the main checkout and the worktree's own name in a worktree.
let kits = String(Context.packageDirectory.split(whereSeparator: { $0 == "/" || $0 == "\\" }).dropLast().last ?? "Database")

let package = Package(
  name: "DatabaseApp", platforms: [.macOS(.v14), .iOS(.v17)],
  products: [.library(name: "DatabaseApp", targets: ["DatabaseApp"])],
  dependencies: [
    .package(path: ".."),
    // The shared design, the vault's accounts, Code's highlighting and in-app updates (Dev's screenshot scenes are
    // added below, on Apple platforms only).
    v57("Component"), v57("Vault"), v57("Code"), v57("UpdateKit"),
  ],
  targets: [
    // The app, all of it but its entry point (Sources/Database/DatabaseMain.swift): Database.xcodeproj builds that
    // file into Database.app with Resources (the icon, asset catalog, Info.plist, entitlements and privacy manifest);
    // on Linux and Windows the Database target below does.
    .target(
      name: "DatabaseApp",
      dependencies: [
        .product(name: "DatabaseUI", package: kits), .product(name: "DatabaseKit", package: kits),
        .product(name: "ComponentKit", package: "Component"), .product(name: "VaultKit", package: "Vault"),
        .product(name: "VaultUI", package: "Vault"), .product(name: "CodeHighlighting", package: "Code"),
        // Updates from GitHub Releases outside the App Store (the iOS app updates through the App Store).
        .product(name: "UpdateKit", package: "UpdateKit", condition: .when(platforms: [.macOS, .linux, .windows])),
      ],
      swiftSettings: [
        .swiftLanguageMode(.v5), .defaultIsolation(MainActor.self), .enableUpcomingFeature("ApproachableConcurrency"),
        .enableUpcomingFeature("MemberImportVisibility"),
      ])
  ])

#if os(Windows) || os(Linux)
// Off Apple platforms SwiftUI is v57/SwiftUI. Only here: on Apple platforms the app uses Apple's SwiftUI, and
// v57/SwiftUI (with its swift-syntax) stays out of the package graph Xcode resolves. No DevScreenshots here: Dev's
// package depends on this repository's libraries on Linux.
package.dependencies += [v57("SwiftUI")]
#if os(Windows)
// On Apple platforms `import Foundation` brings Combine (ObservableObject, @Published), URLSession and the file APIs
// SwiftUIPortability adds along: every file gets them here too.
let appModules = ["Combine", "FoundationNetworking", "SwiftUIPortability"]
#else
// … and `import SwiftUI` brings Observation.
let appModules = ["Combine", "FoundationNetworking", "Observation", "SwiftUIPortability"]
#endif
let appSettings: [SwiftSetting] = [
  .swiftLanguageMode(.v5), .defaultIsolation(MainActor.self), .enableUpcomingFeature("ApproachableConcurrency"),
  .enableUpcomingFeature("MemberImportVisibility"),
  .unsafeFlags(appModules.flatMap { ["-Xfrontend", "-import-module", "-Xfrontend", $0] }),
]
for target in package.targets where target.name == "DatabaseApp" {
  target.dependencies += ["SwiftUI", "SwiftUIPortability"].map { .product(name: $0, package: "SwiftUI") }
  target.swiftSettings = appSettings
}
// The entry point, Sources/Database/DatabaseMain.swift, which Database.xcodeproj builds on Apple platforms.
#if os(Windows)
// The app: a DLL the SwiftUI WinUI host loads (SwiftUI's Windows/scripts/build-app.ps1 -PackagePath <this App folder>
// -Product DatabaseWinUI).
package.targets.append(
  .target(
    name: "Database", dependencies: ["DatabaseApp", .product(name: "SwiftUI", package: "SwiftUI")],
    swiftSettings: appSettings))
package.products.append(.library(name: "DatabaseWinUI", type: .dynamic, targets: ["Database"]))
#elseif os(Linux)
// The app on SwiftUI's GTK backend (in App/: V57_LOCAL=1 swift build --product Database; SwiftUI's
// Linux/scripts/build-app --package <this App folder> Database stages it).
package.targets.append(
  .executableTarget(
    name: "Database", dependencies: ["DatabaseApp", .product(name: "SwiftUI", package: "SwiftUI")],
    swiftSettings: appSettings))
package.products.append(.executable(name: "Database", targets: ["Database"]))
#endif
#else
// Screenshot scenes (Dev's DevScreenshots, behind `canImport` in the app), on Apple platforms only: Dev's package
// depends on this repository's libraries on Linux.
package.dependencies += [v57("Dev")]
for target in package.targets where target.name == "DatabaseApp" {
  target.dependencies += [.product(name: "DevScreenshots", package: "Dev")]
}
#endif
