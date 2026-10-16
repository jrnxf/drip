import Foundation
import XCTest
#if canImport(AppKit)
import CoreGraphics
import ImageIO
#endif

/// Renders cards with `blip __render` and compares them with the PNGs in Tests/Snapshots.
///
/// A card without a reference is skipped. With `BLIP_RECORD_SNAPSHOTS=1` its rendering is saved as
/// the new reference instead; existing references are never overwritten. To regenerate one on
/// purpose, delete it and run scripts/mac-check.sh.
final class SnapshotTests: XCTestCase {
    func testPresetsOneLine() throws {
        try assertSnapshots(Self.presets.flatMap { preset in
            appearances("\(preset.kind)-one-line", [preset.kind, preset.title])
        })
    }

    func testPresetsTwoLines() throws {
        try assertSnapshots(Self.presets.flatMap { preset in
            appearances("\(preset.kind)-two-lines", [preset.kind, preset.title, "--detail", preset.detail])
        })
    }

    func testSizes() throws {
        try assertSnapshots(["compact", "large"].flatMap { size in
            appearances("ok-\(size)-two-lines", ["ok", "Build finished", "--detail", "blip: 42 tests passed in 3.1s",
                                                  "--size", size])
        })
    }

    func testLongTextIsCappedAt640Points() throws {
        let long = String(repeating: "A very long title that keeps going ", count: 9)
        try assertSnapshots(appearances("long-text", ["fail", long, "--detail", long]))
    }

    func testScripts() throws {
        try assertSnapshots([
            Snapshot(name: "scripts-light", arguments: ["info", "ビルド完了 🎉", "--detail", "שלום עולם: مرحبا بالعالم"]),
        ])
    }

    private static let presets: [(kind: String, title: String, detail: String)] = [
        ("ok", "Build finished", "blip: 42 tests passed in 3.1s"),
        ("warn", "Claude needs you", "blip"),
        ("fail", "Deploy failed", "exit 1 after 2m 14s"),
        ("info", "Dotfiles up to date", "pulled 1 commit: feat(nvim): show hidden files"),
    ]
}

/// One rendering to compare: a reference name and the arguments after `blip __render`.
struct Snapshot {
    var name: String
    var arguments: [String]
}

/// The same card in light and dark.
func appearances(_ name: String, _ arguments: [String]) -> [Snapshot] {
    ["light", "dark"].map { Snapshot(name: "\(name)-\($0)", arguments: arguments + ["--appearance", $0]) }
}

extension XCTestCase {
    func assertSnapshots(_ snapshots: [Snapshot], file: StaticString = #filePath, line: UInt = #line) throws {
        #if canImport(AppKit)
        let paths = SnapshotPaths()
        let blip = paths.products.appendingPathComponent("blip")
        guard FileManager.default.isExecutableFile(atPath: blip.path) else {
            XCTFail("\(blip.path) is missing; run swift build first", file: file, line: line)
            return
        }
        let record = ProcessInfo.processInfo.environment["BLIP_RECORD_SNAPSHOTS"] == "1"
        var missing: [String] = []
        var recorded: [String] = []
        for snapshot in snapshots {
            let rendered = paths.scratch.appendingPathComponent("\(snapshot.name).png")
            try render(blip, snapshot.arguments, to: rendered, paths: paths, file: file, line: line)
            let reference = paths.references.appendingPathComponent("\(snapshot.name).png")
            guard FileManager.default.fileExists(atPath: reference.path) else {
                if record {
                    try FileManager.default.createDirectory(at: paths.references, withIntermediateDirectories: true)
                    try FileManager.default.copyItem(at: rendered, to: reference)
                    recorded.append(snapshot.name)
                } else {
                    missing.append(snapshot.name)
                }
                continue
            }
            if let difference = imageDifference(reference: reference, rendered: rendered) {
                let failure = paths.failures.appendingPathComponent("\(snapshot.name).png")
                try FileManager.default.createDirectory(at: paths.failures, withIntermediateDirectories: true)
                try? FileManager.default.removeItem(at: failure)
                try FileManager.default.copyItem(at: rendered, to: failure)
                XCTFail("\(snapshot.name): \(difference); rendered at \(failure.path)", file: file, line: line)
            }
        }
        if !recorded.isEmpty {
            throw XCTSkip("recorded new references: \(recorded.joined(separator: ", "))")
        }
        if !missing.isEmpty {
            throw XCTSkip("no reference for \(missing.joined(separator: ", ")); run scripts/mac-check.sh")
        }
        #else
        throw XCTSkip("snapshot tests run on macOS")
        #endif
    }
}

#if canImport(AppKit)
struct SnapshotPaths {
    /// Where SwiftPM put the test bundle and the blip binary.
    var products: URL
    var references: URL
    var failures: URL
    var scratch: URL
    /// An empty config directory, so the user's config cannot change the renderings.
    var config: URL

    init() {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        products = Bundle.allBundles.first { $0.bundlePath.hasSuffix(".xctest") }?
            .bundleURL.deletingLastPathComponent() ?? root.appendingPathComponent(".build/debug")
        references = root.appendingPathComponent("Tests/Snapshots")
        failures = root.appendingPathComponent(".build/snapshot-failures")
        scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("blip-snapshots-\(ProcessInfo.processInfo.processIdentifier)")
        config = scratch.appendingPathComponent("config")
    }
}

private func render(
    _ blip: URL, _ arguments: [String], to output: URL, paths: SnapshotPaths, file: StaticString, line: UInt
) throws {
    try FileManager.default.createDirectory(at: paths.config, withIntermediateDirectories: true)
    var environment = ProcessInfo.processInfo.environment.filter { !$0.key.hasPrefix("BLIP_") }
    environment["XDG_CONFIG_HOME"] = paths.config.path

    let process = Process()
    process.executableURL = blip
    process.arguments = ["__render", "--out", output.path] + arguments
    process.environment = environment
    let errors = Pipe()
    process.standardError = errors
    try process.run()
    let message = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    process.waitUntilExit()
    if process.terminationStatus != 0 {
        XCTFail("blip __render \(arguments) exited \(process.terminationStatus): \(message)", file: file, line: line)
    }
}

/// Why two PNGs differ, or nil when they match within a small per-pixel tolerance.
private func imageDifference(reference: URL, rendered: URL) -> String? {
    guard let expected = RGBAImage(url: reference) else { return "cannot read the reference" }
    guard let actual = RGBAImage(url: rendered) else { return "cannot read the rendering" }
    guard expected.width == actual.width, expected.height == actual.height else {
        return "size \(actual.width)x\(actual.height) px, expected \(expected.width)x\(expected.height) px"
    }
    let channelTolerance = 8
    var differing = 0
    for pixel in 0..<(expected.width * expected.height) {
        let offset = pixel * 4
        for channel in offset..<(offset + 4)
        where abs(Int(expected.bytes[channel]) - Int(actual.bytes[channel])) > channelTolerance {
            differing += 1
            break
        }
    }
    let allowed = expected.width * expected.height / 500
    return differing > allowed ? "\(differing) pixels differ (at most \(allowed) may)" : nil
}

private struct RGBAImage {
    var width: Int
    var height: Int
    var bytes: [UInt8]

    init?(url: URL) {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
              let space = CGColorSpace(name: CGColorSpace.sRGB)
        else { return nil }
        width = image.width
        height = image.height
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = bytes.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress, width: image.width, height: image.height, bitsPerComponent: 8,
                bytesPerRow: image.width * 4, space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            return true
        }
        guard drawn else { return nil }
        self.bytes = bytes
    }
}
#endif
