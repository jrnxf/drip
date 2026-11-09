#if !os(WASI)
import Foundation

/// Adds drip's block to a shell's rc file on disk. A file that is a symlink or read-only, such
/// as one home-manager manages, is never written or replaced: drip says why and prints its block.
public struct SetupInstaller {
    public var environment: [String: String]
    /// When the backups are stamped.
    public var now: Date

    public init(environment: [String: String], now: Date = Date()) {
        self.environment = environment
        self.now = now
    }

    public enum Outcome: Equatable {
        /// The block is in place: what changed, for stdout, and anything to warn about.
        case done(lines: [String], warnings: [String])
        /// Nothing was changed: why, for stderr, and drip's block to add by hand, for stdout.
        case refused(reason: String, snippet: String)
        /// A write failed: what went wrong.
        case failed(String)
    }
    /// Why drip may not change the file at `path`, or nil when it may. A symlink belongs to whatever
    /// made it, and replacing it would cut the file off from it.
    func problem(writing path: String) -> String? {
        let manager = FileManager.default
        if (try? manager.destinationOfSymbolicLink(atPath: path)) != nil {
            return "is a symlink, as home-manager and other dotfile managers make"
        }
        if manager.fileExists(atPath: path), !manager.isWritableFile(atPath: path) {
            return "is read-only"
        }
        let directory = (path as NSString).deletingLastPathComponent
        if manager.fileExists(atPath: directory), !manager.isWritableFile(atPath: directory) {
            return "is in a read-only directory"
        }
        return nil
    }

    /// Writes the file whole, through a temporary file renamed over it, keeping its permissions, after
    /// copying the old one to a timestamped backup next to it. Returns the backup's path.
    func write(_ text: String, to path: String) throws -> String? {
        let manager = FileManager.default
        let directory = (path as NSString).deletingLastPathComponent
        try manager.createDirectory(atPath: directory, withIntermediateDirectories: true)
        var permissions = 0o644
        var backup: String?
        if manager.fileExists(atPath: path) {
            permissions = (try manager.attributesOfItem(atPath: path)[.posixPermissions] as? NSNumber)?.intValue ?? permissions
            let copy = backupPath(for: path)
            try manager.copyItem(atPath: path, toPath: copy)
            backup = copy
        }
        let name = (path as NSString).lastPathComponent
        let temporary = "\(directory)/.\(name).drip-\(ProcessInfo.processInfo.processIdentifier)"
        guard manager.createFile(
            atPath: temporary, contents: Data(text.utf8), attributes: [.posixPermissions: permissions])
        else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: temporary])
        }
        guard rename(temporary, path) == 0 else {
            let code = errno
            try? manager.removeItem(atPath: temporary)
            throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
        }
        return backup
    }

    /// `<path>.drip-backup-<local time>`, such as `settings.json.drip-backup-20261021-171500`, numbered
    /// when a backup from the same second is there.
    func backupPath(for path: String) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let base = "\(path).drip-backup-\(formatter.string(from: now))"
        var candidate = base
        var number = 2
        while FileManager.default.fileExists(atPath: candidate) {
            candidate = "\(base)-\(number)"
            number += 1
        }
        return candidate
    }

    /// A path with the home directory as `~`.
    func display(_ path: String) -> String {
        guard let home = environment["HOME"], !home.isEmpty, home != "/", path.hasPrefix(home + "/") else { return path }
        return "~" + path.dropFirst(home.count)
    }

    /// `A`, `A and B`, `A, B and C`.
    static func list(_ items: [String]) -> String {
        items.count < 2 ? items.joined() : items.dropLast().joined(separator: ", ") + " and " + items[items.count - 1]
    }
}
#endif
