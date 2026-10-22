import Foundation
import Testing
#if canImport(AppKit)
import CoreGraphics
import ImageIO
#endif

/// Renders cards with `drip __render` and compares them with the PNGs in Tests/Snapshots.
///
/// A card without a reference is cancelled. With `DRIP_RECORD_SNAPSHOTS=1` its rendering is saved
/// as the new reference instead; existing references are never overwritten. To regenerate one on
/// purpose, delete it and run scripts/mac-check.sh.
#if canImport(AppKit)
struct SnapshotTests {
    @Test func presetsOneLine() throws {
        try assertSnapshots(Self.presets.map { preset in
            Snapshot(name: "\(preset.kind)-one-line", arguments: [preset.kind, preset.title])
        })
    }

    /// In light and dark: the system colours of the ring and the icon's disc follow the appearance.
    @Test func presetsTwoLines() throws {
        try assertSnapshots(Self.presets.flatMap { preset in
            appearances("\(preset.kind)-two-lines", [preset.kind, preset.title, "--detail", preset.detail])
        })
    }

    @Test func sizes() throws {
        try assertSnapshots(["compact", "large"].map { size in
            Snapshot(name: "ok-\(size)-two-lines", arguments: ["ok", "Build finished", "--detail",
                                                                "drip: 42 tests passed in 3.1s", "--size", size])
        })
    }

    /// A title wider than the island's text column used to keep the island from showing at all; each
    /// line now gets its own layer, fitted to it. These references guard the layout only, not the
    /// live panel.
    @Test func longText() throws {
        let word = "abcdefghijklmnopqrstuvwxyzabcdefghijklmnopqrstuvwxyzabcdefghijklmnopqrstuvwxyz"
        let spaced = String(repeating: "A very long title that keeps going ", count: 3)
        try assertSnapshots([Snapshot(name: "long-text", arguments: ["ok", word, "--detail", spaced])])
    }

    /// Titles wrap to two lines and details to three, the last ending in an ellipsis when the text
    /// runs on: in Latin, Japanese (which breaks between characters) and right-to-left text (which
    /// hugs the right edge), beside a button, and in the middle of the exit.
    @Test func wrapping() throws {
        let latinDetail: String = "drip: every suite ran on macOS 13, 14 and 15; the slowest was the snapshot suite "
            + "at 2m 41s, and nothing flaked"
        let latin = ["ok", "Nightly build finished: 1,284 tests passed, 3 skipped, coverage report is ready",
                     "--detail", latinDetail]
        let japaneseTitle: String = "夜間ビルドが完了しました。すべてのテストに合格し、カバレッジレポートの準備もできています。"
            + "次のリリース候補をいつでも作成してチームに配布できる状態になりました"
        let japaneseDetail: String = "ユニットテスト一二八四件、スナップショットテスト四十八件、統合テスト十二件がすべて成功しました。"
            + "最も時間がかかったのはスナップショットテストで、二分四十一秒でした。不安定なテストはひとつもありませんでした。"
        let japanese = ["info", japaneseTitle, "--detail", japaneseDetail]
        let arabicDetail: String = "اكتملت جميع الاختبارات على ثلاثة إصدارات من النظام، وكانت أبطأ مجموعة هي "
            + "اختبارات اللقطات بدقيقتين وإحدى وأربعين ثانية"
        let rightToLeft = ["warn", "הבנייה הלילית הסתיימה: כל הבדיקות עברו בהצלחה ודוח הכיסוי מוכן לעיון",
                           "--detail", arabicDetail]
        try assertSnapshots([
            Snapshot(name: "wrap", arguments: latin),
            Snapshot(name: "wrap-cjk", arguments: japanese),
            Snapshot(name: "wrap-rtl", arguments: rightToLeft),
            Snapshot(name: "wrap-button", arguments: latin + ["--open", "https://example.com",
                                                              "--button", "View the coverage"]),
            // The tall capsule gathering back into a drop.
            Snapshot(name: "wrap-leaving", arguments: latin + ["--at", "0.12", "--leaving"]),
        ])
    }

    @Test func customIconAndColor() throws {
        try assertSnapshots([
            Snapshot(name: "custom-icon-color", arguments: ["shipped", "--icon", "paperplane.fill", "--color", "#a78bfa"]),
        ])
    }

    @Test func scripts() throws {
        try assertSnapshots([
            Snapshot(name: "scripts", arguments: ["info", "ビルド完了 🎉", "--detail", "שלום עולם: مرحبا بالعالم"]),
        ])
    }

    @Test func motion() throws {
        let card = ["ok", "Build finished", "--detail", "drip: 42 tests passed in 3.1s"]
        try assertSnapshots([
            // Mid-entrance: the drop hanging on its neck; mid-exit: the drop merging back into the notch.
            Snapshot(name: "falling", arguments: card + ["--at", "0.2"]),
            Snapshot(name: "merging", arguments: card + ["--at", "0.34", "--leaving"]),
        ])
    }

    /// An agent's card: its app's own icon, never tinted, or its bundled mark, with the state in the
    /// ring. Terminal is on every Mac.
    @Test func agentIcons() throws {
        let asking = ["ask", "my-app needs you", "--detail", "Claude needs your permission to use Bash"]
        let done = ["ok", "my-app is done", "--detail", "All 246 tests pass. Pushed fix/notch."]
        let app = ["--icon", "app:com.apple.Terminal"]
        try assertSnapshots([
            Snapshot(name: "ask", arguments: asking),
            Snapshot(name: "ask-app", arguments: asking + app),
            Snapshot(name: "ok-app", arguments: done + app),
            Snapshot(name: "ask-no-app", arguments: asking + ["--icon", "terminal.fill"]),
            Snapshot(name: "ask-mark-claude", arguments: asking + ["--icon", "mark:claude"]),
            Snapshot(name: "ask-mark-codex", arguments: asking + ["--icon", "mark:codex"]),
            Snapshot(name: "ask-mark-gemini", arguments: asking + ["--icon", "mark:gemini"]),
            Snapshot(name: "ok-mark-claude", arguments: done + ["--icon", "mark:claude"]),
            Snapshot(name: "ask-image", arguments: asking + [
                "--icon", "/System/Library/CoreServices/CoreTypes.bundle/Contents/Resources/GenericApplicationIcon.icns",
            ]),
        ])
    }

    @Test func buttons() throws {
        try assertSnapshots([
            Snapshot(name: "button", arguments: ["ok", "Deploy finished", "--detail", "api · 2m 14s",
                                                 "--open", "https://example.com", "--button", "View run"]),
            Snapshot(name: "button-default-label", arguments: ["ok", "Build passed", "--open", "https://example.com"]),
        ])
    }

    /// A question with a no button left of its yes button, with no icon or mark.
    @Test func yesAndNo() throws {
        try assertSnapshots([
            Snapshot(name: "yes-no", arguments: ["ask", "Merge drip #23?", "--detail", "my-app · checks green, 1 approval",
                                                 "--yes", "Merge", "--no", "Later"]),
        ])
    }

    private static let presets: [(kind: String, title: String, detail: String)] = [
        ("ok", "Build finished", "drip: 42 tests passed in 3.1s"),
        ("warn", "Claude needs you", "drip"),
        ("fail", "Deploy failed", "exit 1 after 2m 14s"),
        ("info", "Dotfiles up to date", "pulled 1 commit: feat(nvim): show hidden files"),
        ("ask", "my-app needs you", "Claude needs your permission to use Bash"),
    ]
}

/// One rendering to compare: a reference name and the arguments after `drip __render`.
struct Snapshot {
    var name: String
    var arguments: [String]
}

/// The same card in light and dark.
func appearances(_ name: String, _ arguments: [String]) -> [Snapshot] {
    ["light", "dark"].map { Snapshot(name: "\(name)-\($0)", arguments: arguments + ["--appearance", $0]) }
}

func assertSnapshots(_ snapshots: [Snapshot], sourceLocation: SourceLocation = #_sourceLocation) throws {
    let paths = SnapshotPaths()
    let drip = paths.products.appendingPathComponent("drip")
    guard FileManager.default.isExecutableFile(atPath: drip.path) else {
        Issue.record("\(drip.path) is missing; run swift build first", sourceLocation: sourceLocation)
        return
    }
    let record = ProcessInfo.processInfo.environment["DRIP_RECORD_SNAPSHOTS"] == "1"
    var missing: [String] = []
    var recorded: [String] = []
    for snapshot in snapshots {
        let rendered = paths.scratch.appendingPathComponent("\(snapshot.name).png")
        try render(drip, snapshot.arguments, to: rendered, paths: paths, sourceLocation: sourceLocation)
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
            Issue.record("\(snapshot.name): \(difference); rendered at \(failure.path)", sourceLocation: sourceLocation)
        }
    }
    if !recorded.isEmpty {
        try Test.cancel("recorded new references: \(recorded.joined(separator: ", "))", sourceLocation: sourceLocation)
    }
    if !missing.isEmpty {
        try Test.cancel(
            "no reference for \(missing.joined(separator: ", ")); run scripts/mac-check.sh", sourceLocation: sourceLocation)
    }
}

struct SnapshotPaths {
    /// Where SwiftPM put the test bundle and the drip binary.
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
            .appendingPathComponent("drip-snapshots-\(ProcessInfo.processInfo.processIdentifier)")
        config = scratch.appendingPathComponent("config")
    }
}

private func render(
    _ drip: URL, _ arguments: [String], to output: URL, paths: SnapshotPaths, sourceLocation: SourceLocation
) throws {
    try FileManager.default.createDirectory(at: paths.config, withIntermediateDirectories: true)
    var environment = ProcessInfo.processInfo.environment.filter { !$0.key.hasPrefix("DRIP_") }
    environment["XDG_CONFIG_HOME"] = paths.config.path

    let process = Process()
    process.executableURL = drip
    process.arguments = ["__render", "--out", output.path] + arguments
    process.environment = environment
    let errors = Pipe()
    process.standardError = errors
    try process.run()
    let message = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    process.waitUntilExit()
    if process.terminationStatus != 0 {
        Issue.record(
            "drip __render \(arguments) exited \(process.terminationStatus): \(message)", sourceLocation: sourceLocation)
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
