#if canImport(AppKit)
import CoreGraphics
import Foundation

/// Whether the login session's screen is locked, from the session dictionary, which can be read
/// before NSApplication starts and without a run loop.
enum ScreenLock {
    static var isLocked: Bool {
        guard let session = CGSessionCopyCurrentDictionary() as? [String: Any] else { return false }
        return session["CGSSessionScreenIsLocked"] as? Bool ?? false
    }

    /// Returns once the screen is unlocked, or the session has gone.
    static func waitUntilUnlocked() {
        while isLocked {
            sleep(1)
        }
    }
}
#endif
