import Testing

@testable import DripCore

@Suite struct VisibleWindowsTests {
    let ghostty = "com.mitchellh.ghostty"
    func win(_ id: String?, pid: Int32, layer: Int = 0, display: Int = 0) -> VisibleWindow {
        VisibleWindow(bundleIdentifier: id, pid: pid, layer: layer, display: display)
    }

    @Test func topmostOnASingleDisplay() {
        let list = [win(ghostty, pid: 10), win("com.apple.Stickies", pid: 11)]
        #expect(VisibleWindows.topmost(list, target: ghostty, ownPID: 1) == ghostty)
    }

    @Test func coveredByAnotherApp() {
        let list = [win("com.apple.Stickies", pid: 11), win(ghostty, pid: 10)]
        #expect(VisibleWindows.topmost(list, target: ghostty, ownPID: 1) == nil)
    }

    @Test func dripsOwnWindowsAndOtherLayersAreSkipped() {
        let list = [win("co.jrnxf.drip", pid: 1), win("com.apple.dock", pid: 5, layer: 20), win(ghostty, pid: 10)]
        #expect(VisibleWindows.topmost(list, target: ghostty, ownPID: 1) == ghostty)
    }

    @Test func topmostOnAnyOfTwoDisplays() {
        let list = [win("com.apple.Stickies", pid: 11, display: 0), win(ghostty, pid: 10, display: 1)]
        #expect(VisibleWindows.topmost(list, target: ghostty, ownPID: 1) == ghostty)
        let covered = list + [win(ghostty, pid: 10, display: 0)]
        #expect(VisibleWindows.topmost(covered, target: "com.apple.Notes", ownPID: 1) == nil)
    }

    @Test func anActiveAppWithNoWindowOnTheCurrentSpaceIsNotInFront() {
        // After a swipe to another Space the terminal stays the active app, but the window list of
        // what is on screen holds none of its windows.
        let list = [win("com.apple.Safari", pid: 12)]
        #expect(VisibleWindows.topmost(list, target: ghostty, ownPID: 1) == nil)
        let front = WhenFocused.Front(app: VisibleWindows.topmost(list, target: ghostty, ownPID: 1) != nil, pane: true, idle: 0)
        let card = Card(preset: .ok, title: "api is done")
        #expect(WhenFocused.skip.apply(to: card, front: front) == card)
    }
}
