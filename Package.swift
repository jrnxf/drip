// swift-tools-version: 5.9
import Foundation
import PackageDescription

let package = Package(
    name: "drip",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "drip", targets: ["drip"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.5.0"),
    ],
    targets: [
        // Everything that can be tested without a screen. Builds on Linux too.
        .target(
            name: "DripCore",
            dependencies: [.product(name: "ArgumentParser", package: "swift-argument-parser")]
        ),
        // The command-line tool. AppKit code is guarded with `#if canImport(AppKit)`.
        .executableTarget(
            name: "drip",
            dependencies: ["DripCore"]
        ),
        .testTarget(
            name: "DripCoreTests",
            dependencies: ["DripCore"]
        ),
        // Renders cards with `drip __render` and compares them with the reference PNGs in
        // Tests/Snapshots. macOS only; skipped elsewhere and for cards that have no reference yet.
        .testTarget(name: "DripSnapshotTests"),
    ]
)

// The web page's WebAssembly module: DripCore behind plain wasm exports. Only for a Wasm build,
// which web/build.sh runs; it does not link natively.
if ProcessInfo.processInfo.environment["DRIP_WEB"] == "1" {
    package.targets.append(
        .executableTarget(
            name: "DripWeb",
            dependencies: ["DripCore"],
            path: "web/engine",
            swiftSettings: [.enableExperimentalFeature("Extern")],
            linkerSettings: [.unsafeFlags(["-Xclang-linker", "-mexec-model=reactor"])]
        ))
}
