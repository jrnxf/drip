// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "blip",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "blip", targets: ["blip"]),
    ],
    targets: [
        // Everything that can be tested without a screen. Builds on Linux too.
        .target(name: "BlipCore"),
        // The command-line tool. AppKit code is guarded with `#if canImport(AppKit)`.
        .executableTarget(
            name: "blip",
            dependencies: ["BlipCore"]
        ),
        .testTarget(
            name: "BlipCoreTests",
            dependencies: ["BlipCore"]
        ),
    ]
)
