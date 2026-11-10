#if !os(WASI) // Runs the built drip, which WebAssembly cannot.
import Foundation
import Testing

/// Runs the drip this test run built as a script or an agent runs it: in a home, config, state
/// directory and queue of its own, with only the environment given.
struct DripProcess {
    static let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent()

    /// The drip next to this test bundle, where SwiftPM builds both, whatever the build path or
    /// configuration, else in .build/debug. Not found through `Bundle.allBundles`: on Linux that walks
    /// CoreFoundation's bundle list without a lock and crashes while other tests run beside it.
    static let drip: URL = {
        let fallback = repo.appendingPathComponent(".build/debug/drip")
        #if os(Linux)
        // The test bundle is the executable this process runs.
        guard let path = try? FileManager.default.destinationOfSymbolicLink(atPath: "/proc/self/exe") else {
            return fallback
        }
        let products = URL(fileURLWithPath: path).deletingLastPathComponent()
        #else
        let products = Bundle(for: BundleMarker.self).bundleURL.deletingLastPathComponent()
        #endif
        let built = products.appendingPathComponent("drip")
        return FileManager.default.isExecutableFile(atPath: built.path) ? built : fallback
    }()

    struct Outcome {
        var status: Int32
        var output: String
        var error: String
    }

    /// Runs drip with `arguments`, `input` on its standard input and `environment` added. `config`
    /// is the config file's text, if there is one. With `stateBroken`, the state directory is a file,
    /// so nothing can be written there, not even by root.
    static func run(
        _ arguments: [String], input: Data = Data(), config: String? = nil, stateBroken: Bool = false,
        environment extra: [String: String] = [:], sourceLocation: SourceLocation = #_sourceLocation
    ) throws -> Outcome {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("drip-run-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let configDirectory = home.appendingPathComponent("config")
        try FileManager.default.createDirectory(
            at: configDirectory.appendingPathComponent("drip"), withIntermediateDirectories: true)
        if let config {
            try config.write(
                to: configDirectory.appendingPathComponent("drip/config.toml"), atomically: false, encoding: .utf8)
        }
        let state = home.appendingPathComponent("state")
        if stateBroken { try Data().write(to: state) }
        // A file, not a pipe: input past what drip reads is not read to its end, and a write to the
        // pipe of a process that has stopped reading would fail.
        let inputFile = home.appendingPathComponent("input")
        try input.write(to: inputFile)
        let output = home.appendingPathComponent("output")
        let error = home.appendingPathComponent("error")
        FileManager.default.createFile(atPath: output.path, contents: nil)
        FileManager.default.createFile(atPath: error.path, contents: nil)

        let process = Process()
        process.executableURL = drip
        process.arguments = arguments
        process.environment = [
            "PATH": "/usr/bin:/bin", "HOME": home.path, "XDG_CONFIG_HOME": configDirectory.path,
            "XDG_STATE_HOME": state.path, "DRIP_QUEUE_DIR": home.appendingPathComponent("queue").path,
        ].merging(extra) { $1 }
        process.standardInput = try FileHandle(forReadingFrom: inputFile)
        process.standardOutput = try FileHandle(forWritingTo: output)
        process.standardError = try FileHandle(forWritingTo: error)
        try process.run()
        let deadline = Date().addingTimeInterval(30)
        while process.isRunning, Date() < deadline { Thread.sleep(forTimeInterval: 0.02) }
        #expect(!process.isRunning, "drip \(arguments.joined(separator: " ")) did not end", sourceLocation: sourceLocation)
        if process.isRunning { process.terminate() }
        process.waitUntilExit()
        return Outcome(
            status: process.terminationStatus,
            output: (try? String(contentsOf: output, encoding: .utf8)) ?? "",
            error: (try? String(contentsOf: error, encoding: .utf8)) ?? "")
    }
}

#if !os(Linux)
/// A class in this test bundle, for `Bundle(for:)` to find the bundle by.
private final class BundleMarker {}
#endif
#endif
