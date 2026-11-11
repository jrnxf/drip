#if !os(WASI) // Walks the repo folder, which the browser's sandbox has not.
import Foundation
import Testing

/// Every relative link in a markdown file points at a file or folder that exists. Anchors and web links are not checked.
struct DocLinkTests {
    @Test func relativeMarkdownLinksPointAtFilesThatExist() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let skipped: Set = [".build", ".git", ".claude", "node_modules"]
        let localOnly: Set = ["LAUNCH-PLAN.md", "LAUNCH-FOLLOWUPS.md", "api-surface-audit.md"]
        let link = try NSRegularExpression(pattern: #"\[[^\]]*\]\(([^)\s]+)"#)
        var files: [URL] = []
        let walker = try #require(FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil))
        for case let url as URL in walker {
            if skipped.contains(url.lastPathComponent) { walker.skipDescendants() }
            else if url.pathExtension == "md", !localOnly.contains(url.lastPathComponent) { files.append(url) }
        }
        #expect(!files.isEmpty)
        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8)
            for match in link.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                let target = String(text[Range(match.range(at: 1), in: text)!])
                let path = String(target.split(separator: "#", omittingEmptySubsequences: false)[0])
                if path.isEmpty || ["http:", "https:", "mailto:"].contains(where: path.hasPrefix) { continue }
                let found = FileManager.default.fileExists(atPath: file.deletingLastPathComponent().appendingPathComponent(path).path)
                #expect(found, "\(file.lastPathComponent) links to \(target), which does not exist")
            }
        }
    }
}
#endif
