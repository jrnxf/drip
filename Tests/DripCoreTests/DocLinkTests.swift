#if !os(WASI) // Runs git and reads the repo folder, which the browser's sandbox has not.
import Foundation
import Testing

/// Every relative link in a tracked markdown file points at a file or folder that exists.
/// Not checked: anchors, web links, angle-bracket or paren targets, HTML tags, reference definitions, letter case.
struct DocLinkTests {
    @Test func relativeMarkdownLinksPointAtFilesThatExist() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let git = Process()
        git.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        git.arguments = ["git", "ls-files", "-z", "*.md"]
        git.currentDirectoryURL = root
        // CI checks the repo out as another user, which git calls dubious ownership.
        git.environment = ProcessInfo.processInfo.environment.merging([
            "GIT_CONFIG_COUNT": "1", "GIT_CONFIG_KEY_0": "safe.directory", "GIT_CONFIG_VALUE_0": "*",
        ]) { $1 }
        let pipe = Pipe()
        let errors = Pipe()
        git.standardOutput = pipe
        git.standardError = errors
        try git.run()
        let listing = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        let stderr = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        git.waitUntilExit()
        #expect(git.terminationStatus == 0, "git ls-files failed: \(stderr)")
        let files = listing.split(separator: "\0").map(String.init)
        #expect(!files.isEmpty)

        let link = try NSRegularExpression(pattern: #"\[[^\]]*\]\(([^)\s]+)"#)
        let codeSpan = try NSRegularExpression(pattern: "`[^`]*`")
        for file in files {
            var fenced = false
            // A listed file can be missing from the working tree (deleted or renamed, not yet staged).
            guard let text = try? String(contentsOf: root.appendingPathComponent(file), encoding: .utf8) else { continue }
            for var line in text.components(separatedBy: "\n") {
                let isFence = line.trimmingCharacters(in: .whitespaces).hasPrefix("```")
                if isFence { fenced.toggle() }
                if fenced || isFence { continue }
                line = codeSpan.stringByReplacingMatches(in: line, range: NSRange(line.startIndex..., in: line), withTemplate: "")
                for match in link.matches(in: line, range: NSRange(line.startIndex..., in: line)) {
                    let target = String(line[Range(match.range(at: 1), in: line)!])
                    var path = String(target.prefix { $0 != "#" && $0 != "?" })
                    if path.isEmpty || path.range(of: #"^([A-Za-z][A-Za-z0-9+.-]*:|//)"#, options: .regularExpression) != nil { continue }
                    path = path.removingPercentEncoding ?? path
                    let base = path.hasPrefix("/") ? root : root.appendingPathComponent(file).deletingLastPathComponent()
                    let found = FileManager.default.fileExists(atPath: base.appendingPathComponent(path).path)
                    #expect(found, "\(file) links to \(target), which does not exist")
                }
            }
        }
    }
}
#endif
