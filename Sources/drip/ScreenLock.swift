#if canImport(AppKit)
import CoreGraphics
import DripCore
import Foundation

/// Whether the login session's screen is locked, from the session dictionary, which can be read
/// before NSApplication starts and without a run loop.
enum ScreenLock {
    static var isLocked: Bool {
        guard let session = CGSessionCopyCurrentDictionary() as? [String: Any] else { return false }
        return session["CGSSessionScreenIsLocked"] as? Bool ?? false
    }
}

/// Whether a card would play to nobody now: the screen is locked, or `drip pause` holds cards.
/// Either way cards are held until it ends.
enum Away {
    static var isAway: Bool {
        ScreenLock.isLocked || DripPause(environment: ProcessInfo.processInfo.environment).isPaused()
    }

    /// Returns once the screen is unlocked and no pause holds cards, or the session has gone.
    static func waitUntilBack() {
        while isAway {
            sleep(1)
        }
    }
}
#endif
