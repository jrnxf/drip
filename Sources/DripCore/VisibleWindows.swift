/// A window the window server lists as on screen, with only what drip needs to tell which app is
/// looking at you: never its title, which would need the Screen Recording permission.
public struct VisibleWindow: Equatable, Sendable {
    public var bundleIdentifier: String?
    public var pid: Int32
    /// 0 for an ordinary window; floating panels, menus and the card sit on other layers.
    public var layer: Int
    public var display: Int

    public init(bundleIdentifier: String?, pid: Int32, layer: Int = 0, display: Int = 0) {
        self.bundleIdentifier = bundleIdentifier
        self.pid = pid
        self.layer = layer
        self.display = display
    }
}

public enum VisibleWindows {
    /// The bundle identifier of the app whose ordinary window is topmost on some display, from
    /// `windows` listed front to back, or nil when `target` has none on top. After a swipe to
    /// another Space, macOS keeps the app last clicked active, though another is what you see.
    /// drip's own windows (`ownPID`) and windows off layer 0 are not what you are looking at.
    public static func topmost(
        _ windows: [VisibleWindow], target: String, ownPID: Int32
    ) -> String? {
        var seen = Set<Int>()
        for window in windows where window.layer == 0 && window.pid != ownPID {
            guard seen.insert(window.display).inserted else { continue }
            if window.bundleIdentifier == target { return target }
        }
        return nil
    }
}
