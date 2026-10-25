// Drives the Mac checks of drip's cards without a person, for scripts/mac-e2e.sh, which builds and
// runs it: each check says ok or FAIL, and the run exits 1 when any fails.
//
// It runs the branch's own release build in a world of its own: its own state, config and queue
// (`XDG_STATE_HOME`, `XDG_CONFIG_HOME`, `DRIP_QUEUE_DIR`) and its own Claude Code and Codex settings
// (`CLAUDE_CONFIG_DIR`, `CODEX_HOME`), all in a scratch directory it deletes, so it never touches
// the drip, the history or the agents' settings in use on the Mac. Other drips' cards still come up
// at the notch now and then: a check waits for them to go first, and runs again when one came up
// while it ran and it failed.
//
// What it looks at is what a person would: whether drip has a window on screen, what drip recorded
// in its history, which app is in front, tmux's own word on which pane is selected, and pixels at the
// notch, over a plain white backdrop it puts behind the cards. Clicks and accessibility actions go
// through the helper app (Helper.swift), the only part that needs a permission.
import AppKit
import CoreGraphics
import Darwin
import ImageIO

// MARK: - Options

struct Options {
    var repo = ""
    var helper: String?
    var out = ""
    var only: Set<Int>?
    var judgeCheck: String?
    var prompt = true
}

func parseOptions() -> Options {
    var options = Options()
    var arguments = Array(CommandLine.arguments.dropFirst())
    func value() -> String {
        guard !arguments.isEmpty else {
            FileHandle.standardError.write(Data("mac-e2e: a value is missing\n".utf8))
            exit(2)
        }
        return arguments.removeFirst()
    }
    while !arguments.isEmpty {
        switch arguments.removeFirst() {
        case "--repo": options.repo = value()
        case "--helper": options.helper = value()
        case "--out": options.out = value()
        case "--only": options.only = Set(value().split(separator: ",").compactMap { Int($0) })
        case "--judge-check": options.judgeCheck = value()
        case "--no-prompt": options.prompt = false
        case let other:
            FileHandle.standardError.write(Data("mac-e2e: unknown option \(other)\n".utf8))
            exit(2)
        }
    }
    return options
}

let options = parseOptions()

// MARK: - Reporting

var failed = 0
var passed = 0
var skipped = 0

func say(_ line: String) {
    print(line)
    fflush(stdout)
}

func skip(_ check: Int, _ text: String) {
    skipped += 1
    say("skip  \(check)  \(text)")
}

/// One check's expectations, printed once the check has run for the last time.
struct Expectations {
    var lines: [(ok: Bool, text: String)] = []
    var passed: Bool { lines.allSatisfy(\.ok) }

    mutating func expect(_ condition: Bool, _ text: String) {
        lines.append((condition, text))
    }

    /// Expects `elapsed`, the seconds something took, within `limit`; nil when it never happened.
    mutating func within(_ limit: Double, _ elapsed: Double?, _ text: String) {
        let took = elapsed.map { String(format: "%.2f s", $0) } ?? "never, waited \(limit) s"
        expect((elapsed ?? .infinity) <= limit, "\(text) (\(took))")
    }
}

// MARK: - Processes

let fileManager = FileManager.default
let scratch: String = {
    let path = (NSTemporaryDirectory() as NSString).appendingPathComponent("drip-e2e-\(getpid())")
    try? fileManager.createDirectory(atPath: path, withIntermediateDirectories: true)
    return (path as NSString).resolvingSymlinksInPath
}()

func path(_ parts: String...) -> String {
    parts.dropFirst().reduce(parts[0]) { ($0 as NSString).appendingPathComponent($1) }
}

struct Ran {
    var status: Int32
    var out: String
    var err: String
}

var runs = 0

/// Runs `arguments`, a program found on `PATH` and its arguments, and waits up to `timeout`.
@discardableResult
func run(_ arguments: [String], environment: [String: String]? = nil, input: Data? = nil, in directory: String? = nil,
         timeout: Double = 60) -> Ran
{
    runs += 1
    let out = path(scratch, "run-\(runs).out"), err = path(scratch, "run-\(runs).err")
    fileManager.createFile(atPath: out, contents: nil)
    fileManager.createFile(atPath: err, contents: nil)
    defer {
        unlink(out)
        unlink(err)
    }
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = arguments
    if let environment { process.environment = environment }
    if let directory { process.currentDirectoryURL = URL(fileURLWithPath: directory) }
    process.standardOutput = FileHandle(forWritingAtPath: out)
    process.standardError = FileHandle(forWritingAtPath: err)
    let pipe = Pipe()
    process.standardInput = input == nil ? FileHandle.nullDevice : pipe
    do {
        try process.run()
    } catch {
        return Ran(status: 127, out: "", err: "\(error)")
    }
    if let input {
        pipe.fileHandleForWriting.write(input)
        try? pipe.fileHandleForWriting.close()
    }
    let deadline = Date().addingTimeInterval(timeout)
    while process.isRunning, Date() < deadline { usleep(10_000) }
    if process.isRunning { process.terminate() }
    process.waitUntilExit()
    let took = Date().timeIntervalSince(deadline) + timeout
    if took > 5 { say("      slow: \(arguments.prefix(3).joined(separator: " ")) took \(Int(took)) s") }
    let read = { (file: String) in (try? String(contentsOfFile: file, encoding: .utf8)) ?? "" }
    return Ran(status: process.terminationStatus, out: read(out), err: read(err))
}

/// Lets the run loop run, so AppKit draws the backdrop, for `seconds`.
func pause(_ seconds: Double) {
    let end = Date().addingTimeInterval(seconds)
    repeat {
        notice()
        RunLoop.current.run(until: min(end, Date().addingTimeInterval(0.1)))
    } while Date() < end
}

/// Polls `condition` until it holds or `timeout` passes; the seconds it took, or nil.
func wait(_ timeout: Double, every interval: Double = 0.05, _ condition: () -> Bool) -> Double? {
    let start = Date()
    while true {
        if condition() { return Date().timeIntervalSince(start) }
        if Date().timeIntervalSince(start) >= timeout { return nil }
        pause(interval)
    }
}

/// The path of the program the process `pid` runs, with symlinks resolved; nil when it is gone.
func executable(of pid: Int32) -> String? {
    var buffer = [CChar](repeating: 0, count: 4096)
    guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
    return String(cString: buffer)
}

func parent(of pid: Int32) -> Int32? {
    var info = kinfo_proc()
    var size = MemoryLayout<kinfo_proc>.stride
    var name: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
    guard sysctl(&name, UInt32(name.count), &info, &size, nil, 0) == 0, size > 0 else { return nil }
    return info.kp_eproc.e_ppid
}

/// Every process running `program`.
func processes(running program: String) -> [Int32] {
    let count = proc_listallpids(nil, 0)
    var pids = [Int32](repeating: 0, count: Int(count) + 64)
    let found = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<Int32>.stride))
    return pids.prefix(Int(max(found, 0))).filter { $0 > 0 && executable(of: $0) == program }
}

/// The app that runs `pid`, or one of its parents.
func app(running pid: Int32) -> NSRunningApplication? {
    var current = pid
    for _ in 0..<24 {
        if let app = NSRunningApplication(processIdentifier: current), app.bundleIdentifier != nil { return app }
        guard let next = parent(of: current), next > 1, next != current else { return nil }
        current = next
    }
    return nil
}

/// The bundle identifier of the app in front, as Launch Services says now.
func frontApp() -> String? {
    let asn = run(["lsappinfo", "front"]).out.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !asn.isEmpty else { return nil }
    let info = run(["lsappinfo", "info", "-only", "bundleid", asn]).out
    // "CFBundleIdentifier"="com.apple.Terminal"
    let parts = info.components(separatedBy: "\"")
    return parts.count > 3 ? parts[3] : nil
}

/// Brings an app forward the way the Dock would.
func bringForward(_ bundle: String) {
    run(["open", "-b", bundle])
    _ = wait(3) { frontApp() == bundle }
}

// MARK: - The drip under test

let drip = path(options.repo, ".build/release/drip")
let dripProgram = (drip as NSString).resolvingSymlinksInPath
let project = path(scratch, "projects", "e2e-app")
let claudeHome = path(scratch, "claude")
let codexHome = path(scratch, "codex")
for directory in ["state", "config", "queue", "bin", "shots", "projects/e2e-app", "claude", "codex"] {
    try? fileManager.createDirectory(atPath: path(scratch, directory), withIntermediateDirectories: true)
}
// The hooks `drip setup` writes run `drip`, found on PATH: this one.
try? fileManager.createSymbolicLink(atPath: path(scratch, "bin", "drip"), withDestinationPath: dripProgram)

/// The environment every drip, hook and tmux pane here runs with. A click on a card brings Terminal
/// forward, an app every Mac has, unless a check says otherwise.
let environment: [String: String] = {
    var environment = ProcessInfo.processInfo.environment.filter { !$0.key.hasPrefix("DRIP_") }
    for name in ["TMUX", "TMUX_PANE", "WEZTERM_PANE"] { environment.removeValue(forKey: name) }
    environment["XDG_STATE_HOME"] = path(scratch, "state")
    environment["XDG_CONFIG_HOME"] = path(scratch, "config")
    environment["DRIP_QUEUE_DIR"] = path(scratch, "queue")
    environment["CLAUDE_CONFIG_DIR"] = claudeHome
    environment["CODEX_HOME"] = codexHome
    environment["PATH"] = path(scratch, "bin") + ":" + (environment["PATH"] ?? "/usr/bin:/bin")
    environment["__CFBundleIdentifier"] = "com.apple.Terminal"
    return environment
}()

@discardableResult
func dripRun(_ arguments: [String], input: Data? = nil, extra: [String: String] = [:]) -> Ran {
    run([drip] + arguments, environment: environment.merging(extra) { $1 }, input: input, in: project)
}

/// Runs a hook command as an agent does: through the shell, its payload on stdin, in the project.
@discardableResult
func hook(_ command: String, _ payload: [String: Any], extra: [String: String] = [:]) -> Ran {
    var payload = payload
    payload["cwd"] = payload["cwd"] ?? project
    let data = (try? JSONSerialization.data(withJSONObject: payload)) ?? Data()
    return run(["/bin/sh", "-c", command], environment: environment.merging(extra) { $1 }, input: data, in: project)
}

/// A card kept in drip's history, as `drip history --json` writes it.
struct Recorded {
    var card: [String: Any]
    var missed: Bool
    var id: String? { card["id"] as? String }
    var title: String { card["title"] as? String ?? "" }
    var sound: String { card["sound"] as? String ?? "none" }
}

func history() -> [Recorded] {
    dripRun(["history", "--json"]).out.split(separator: "\n").compactMap { line in
        guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
              let card = object["card"] as? [String: Any]
        else { return nil }
        return Recorded(card: card, missed: object["missed"] as? Bool ?? false)
    }
}

func recorded(_ id: String) -> [Recorded] {
    history().filter { $0.id == id }
}

/// A fresh id for a card or an agent session, so nothing left over from another check matches it.
var serial = 0
func fresh(_ name: String) -> String {
    serial += 1
    return "e2e-\(getpid())-\(serial)-\(name)"
}

// MARK: - The screen

let screen = CGDisplayBounds(CGMainDisplayID())
let scale = NSScreen.screens.first?.backingScaleFactor ?? 2
/// Where cards come out, in global points, y down from the top of the main screen: wide enough for
/// the widest card, from just under the menu bar.
let menuBar = (NSScreen.screens.first.map { $0.frame.maxY - $0.visibleFrame.maxY } ?? 24) + 2
let notchArea = CGRect(x: screen.midX - 360, y: menuBar, width: 720, height: 480)

/// drip's windows on screen: this run's, and every other drip's, such as the Mac's own.
func dripWindows() -> (ours: [CGRect], others: [CGRect]) {
    let ours = Set(processes(running: dripProgram))
    let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
        as? [[String: Any]] ?? []
    var result: (ours: [CGRect], others: [CGRect]) = ([], [])
    for window in list {
        guard let pid = window[kCGWindowOwnerPID as String] as? Int32,
              let owner = window[kCGWindowOwnerName as String] as? String,
              (window[kCGWindowAlpha as String] as? Double ?? 1) > 0,
              let bounds = window[kCGWindowBounds as String] as? NSDictionary,
              let rect = CGRect(dictionaryRepresentation: bounds)
        else { continue }
        if ours.contains(pid) {
            result.ours.append(rect)
        } else if owner == "drip" {
            result.others.append(rect)
        }
    }
    return result
}

var showing: Bool { !dripWindows().ours.isEmpty }

/// Whether another drip's card came up, or someone moved the pointer, since the check started,
/// which may be why it failed.
var disturbed = false
/// Where the harness last put the pointer.
var placed: CGPoint?
func notice() {
    if !dripWindows().others.isEmpty { disturbed = true }
    if let placed, let now = CGEvent(source: nil)?.location, hypot(now.x - placed.x, now.y - placed.y) > 2 {
        disturbed = true
    }
}

/// A plain white backdrop under the cards, so their black reads clearly whatever is behind them. It
/// takes no clicks.
let backdrop: NSWindow = {
    _ = NSApplication.shared
    NSApp.setActivationPolicy(.accessory)
    let main = NSScreen.screens.first?.frame ?? .zero
    let frame = NSRect(
        x: notchArea.minX, y: main.maxY - notchArea.maxY, width: notchArea.width, height: notchArea.height)
    let window = NSWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
    window.backgroundColor = .white
    window.isOpaque = true
    window.hasShadow = false
    window.ignoresMouseEvents = true
    window.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue - 1)
    window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
    return window
}()

/// A screenshot of `rect`, in global points, with its pixels.
struct Shot {
    var rect: CGRect
    var width: Int
    var height: Int
    var pixels: [UInt8]

    init?(_ rect: CGRect, saving file: String? = nil) {
        let target = file ?? path(scratch, "shot.png")
        let region = "\(Int(rect.minX)),\(Int(rect.minY)),\(Int(rect.width)),\(Int(rect.height))"
        guard run(["screencapture", "-x", "-R", region, target]).status == 0,
              let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: target) as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else { return nil }
        self.rect = rect
        width = image.width
        height = image.height
        pixels = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return nil }
    }

    var perPoint: Double { Double(width) / rect.width }

    /// Whether the pixel at column `x`, row `y` from the top is a card's black.
    func dark(_ x: Int, _ y: Int) -> Bool {
        let index = (y * width + x) * 4
        return pixels[index] < 48 && pixels[index + 1] < 48 && pixels[index + 2] < 48
    }

    /// The cards in the shot, top to bottom, in global points: the bands of black on the backdrop.
    var cards: [CGRect] {
        var rows: [Int] = []
        for y in 0..<height {
            var count = 0
            for x in stride(from: 0, to: width, by: 2) where dark(x, y) { count += 1 }
            if Double(count * 2) > 40 * perPoint { rows.append(y) }
        }
        var bands: [ClosedRange<Int>] = []
        for row in rows {
            if let last = bands.last, row - last.upperBound <= 2 {
                bands[bands.count - 1] = last.lowerBound...row
            } else {
                bands.append(row...row)
            }
        }
        return bands.filter { Double($0.count) > 30 * perPoint }.map { band in
            // The widest the black reaches in the band's middle rows, past the text and icons on it.
            var left = width, right = 0
            let middle = band.count / 4
            for y in (band.lowerBound + middle)...(band.upperBound - middle) {
                if let first = (0..<width).first(where: { dark($0, y) }) { left = min(left, first) }
                if let last = (0..<width).last(where: { dark($0, y) }) { right = max(right, last) }
            }
            return CGRect(
                x: rect.minX + Double(left) / perPoint, y: rect.minY + Double(band.lowerBound) / perPoint,
                width: Double(right - left + 1) / perPoint, height: Double(band.count) / perPoint)
        }
    }

    /// How different `other` is from this shot inside `area`, in global points: the share of its
    /// pixels that changed clearly.
    func change(from other: Shot, in area: CGRect, by threshold: Int = 12) -> Double {
        let box = area.intersection(rect).intersection(other.rect)
        guard !box.isEmpty, other.width == width, other.height == height else { return 1 }
        let x0 = Int((box.minX - rect.minX) * perPoint), x1 = Int((box.maxX - rect.minX) * perPoint)
        let y0 = Int((box.minY - rect.minY) * perPoint), y1 = Int((box.maxY - rect.minY) * perPoint)
        var changed = 0, total = 0
        for y in y0..<y1 {
            for x in x0..<x1 {
                let index = (y * width + x) * 4
                let delta = (0..<3).map { abs(Int(pixels[index + $0]) - Int(other.pixels[index + $0])) }.max() ?? 0
                if delta > threshold { changed += 1 }
                total += 1
            }
        }
        return total == 0 ? 0 : Double(changed) / Double(total)
    }
}

/// The cards on screen once they have settled.
func cardsOnScreen() -> [CGRect] {
    pause(0.2)
    return Shot(notchArea)?.cards ?? []
}

// MARK: - Screenshots to judge by eye

struct Judged {
    var name: String
    var expected: String
}

var judged: [Judged] = []

/// Keeps a screenshot of the cards for a person or a model to judge, with what it should show.
func keep(_ name: String, _ expected: String, around cards: [CGRect]) {
    let union = cards.reduce(CGRect.null) { $0.union($1) }
    let rect = union.isNull ? notchArea : union.insetBy(dx: -24, dy: -16).intersection(notchArea)
    let number = String(format: "%02d", judged.count + 1)
    let file = path(options.out, "\(number)-\(name).png")
    guard Shot(rect, saving: file) != nil else { return }
    try? (expected + "\n").write(toFile: path(options.out, "\(number)-\(name).txt"), atomically: true, encoding: .utf8)
    judged.append(Judged(name: "\(number)-\(name)", expected: expected))
}

/// Draws every kept screenshot, one under another with what it should show, into one image.
func contactSheet() {
    let images = judged.compactMap { item -> (Judged, CGImage)? in
        guard let source = CGImageSourceCreateWithURL(
            URL(fileURLWithPath: path(options.out, item.name + ".png")) as CFURL, nil),
            let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else { return nil }
        return (item, image)
    }
    guard !images.isEmpty else { return }
    let margin = 40
    let width = (images.map(\.1.width).max() ?? 0) + margin * 2
    let captions = images.map { item, _ in
        NSAttributedString(string: "\(item.name): \(item.expected)", attributes: [
            .font: NSFont.systemFont(ofSize: 22), .foregroundColor: NSColor.black,
        ])
    }
    let heights = captions.map {
        Int($0.boundingRect(with: CGSize(width: width - margin * 2, height: 10_000), options: .usesLineFragmentOrigin)
            .height.rounded(.up)) + 16
    }
    let height = zip(images, heights).reduce(margin) { $0 + $1.0.1.height + $1.1 + margin }
    guard let context = CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { return }
    context.setFillColor(CGColor(gray: 0.93, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
    var top = height - margin
    for ((_, image), (text, caption)) in zip(images, zip(captions, heights)) {
        top -= image.height
        context.draw(image, in: CGRect(x: margin, y: top, width: image.width, height: image.height))
        text.draw(with: CGRect(x: margin, y: top - caption, width: width - margin * 2, height: caption - 8),
                  options: .usesLineFragmentOrigin)
        top -= caption + margin
    }
    NSGraphicsContext.current = nil
    guard let image = context.makeImage(),
          let destination = CGImageDestinationCreateWithURL(
              URL(fileURLWithPath: path(options.out, "contact-sheet.png")) as CFURL, "public.png" as CFString, 1, nil)
    else { return }
    CGImageDestinationAddImage(destination, image, nil)
    CGImageDestinationFinalize(destination)
}

/// The instructions a model, or a person, follows to judge the kept screenshots.
func judgingInstructions() {
    var text = """
        # Judge drip's cards

        Each PNG below is a screenshot of drip's cards at the notch, over a plain white backdrop the
        harness puts behind them. Look at each image, compare it with what it should show, and write
        one line per image into `verdicts.txt` next to this file:

            <name> PASS
            <name> FAIL <what is wrong>

        Judge only what the description says; ignore the white backdrop and anything outside the
        black cards. Then run `scripts/mac-e2e.sh --judge-check \(options.out)`.

        """
    for item in judged {
        text += "\n## \(item.name)\n\n![\(item.name)](\(item.name).png)\n\nShould show: \(item.expected)\n"
    }
    try? text.write(toFile: path(options.out, "judge.md"), atomically: true, encoding: .utf8)
}

// MARK: - The pointer

/// The helper app, when it runs and holds Accessibility; nil otherwise.
final class Helper {
    let directory: String
    var serial = 0
    var trusted = false

    init?(app: String, prompt: Bool) {
        directory = path(scratch, "helper")
        try? fileManager.createDirectory(atPath: directory, withIntermediateDirectories: true)
        var arguments = ["open", "-g", "-n", app, "--args", directory, String(getpid())]
        if prompt { arguments.append("--prompt") }
        guard run(arguments).status == 0 else { return nil }
        let ready = path(directory, "ready")
        guard wait(15, { fileManager.fileExists(atPath: ready) }) != nil,
              let data = fileManager.contents(atPath: ready),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        trusted = object["trusted"] as? Bool ?? false
    }

    func call(_ request: [String: Any]) -> [String: Any] {
        serial += 1
        let name = String(format: "%06d", serial)
        let file = path(directory, name + ".req")
        let data = (try? JSONSerialization.data(withJSONObject: request)) ?? Data()
        fileManager.createFile(atPath: file + ".tmp", contents: data)
        rename(file + ".tmp", file)
        let reply = path(directory, name + ".res")
        guard wait(10, every: 0.01, { fileManager.fileExists(atPath: reply) }) != nil,
              let answer = fileManager.contents(atPath: reply),
              let object = try? JSONSerialization.jsonObject(with: answer) as? [String: Any]
        else { return ["error": "the helper did not answer"] }
        unlink(reply)
        return object
    }

    func quit() {
        fileManager.createFile(atPath: path(directory, "quit"), contents: nil)
    }
}

var helper: Helper?
var canClick: Bool { helper?.trusted == true }
/// What the checks that click or read VoiceOver's actions say while the helper waits for its grant.
let ungranted = "skipped until granted: turn on \"drip e2e helper\" in System Settings > Privacy & Security > "
    + "Accessibility, then run scripts/mac-e2e.sh again"

/// Where the pointer rests between checks: off the cards, still on the main screen.
let parking = CGPoint(x: screen.midX, y: screen.minY + 600)

/// Moves the pointer: with a real mouse event through the helper when it can, else by warping it,
/// which drip's stack, which follows the pointer's position, notices just the same.
func point(at target: CGPoint) {
    placed = target
    if canClick, notchArea.insetBy(dx: -10, dy: -200).contains(target),
       helper?.call(["op": "move", "x": target.x, "y": target.y])["ok"] != nil
    {
        return
    }
    CGWarpMouseCursorPosition(target)
}

func click(_ target: CGPoint, button: String = "left", modifiers: [String] = []) -> Bool {
    placed = target
    return helper?.call(["op": "click", "x": target.x, "y": target.y, "button": button, "modifiers": modifiers])["ok"] != nil
}

/// The accessibility elements of this run's drips, with their labels and action names.
func accessibility() -> [(label: String, actions: [String])] {
    guard let helper else { return [] }
    return processes(running: dripProgram).flatMap { pid -> [(label: String, actions: [String])] in
        let reply = helper.call(["op": "elements", "pid": Int(pid)])
        return (reply["elements"] as? [[String: Any]] ?? []).map {
            ($0["label"] as? String ?? "", $0["actions"] as? [String] ?? [])
        }
    }
}

func perform(_ action: String) -> Bool {
    guard let helper else { return false }
    for pid in processes(running: dripProgram)
    where helper.call(["op": "perform", "pid": Int(pid), "name": action])["ok"] != nil {
        return true
    }
    return false
}

// MARK: - Running checks

/// Takes this run's cards away and waits until none of them, and no other drip's, shows.
func clearScreen() {
    point(at: parking)
    if showing {
        dripRun(["dismiss"])
        _ = wait(5) { !showing }
    }
    // Another drip's card, from an agent at work on this Mac, gets the notch to itself first.
    if let waited = wait(90, { dripWindows().others.isEmpty }), waited > 5 {
        say("      waited \(Int(waited)) s for another drip's card to go")
    }
}

/// Runs a check up to three times while another drip's card that came up during it may be why it
/// failed, then prints what it expected.
func check(_ number: Int, _ title: String, _ body: (inout Expectations) -> Void) {
    guard options.only?.contains(number) ?? true else { return }
    var expectations = Expectations()
    for attempt in 1...3 {
        clearScreen()
        disturbed = false
        expectations = Expectations()
        body(&expectations)
        if expectations.passed || !disturbed || attempt == 3 { break }
        say("      \(number)  \(title): another drip's card came up, or the pointer moved, so again")
    }
    for line in expectations.lines {
        if line.ok { passed += 1 } else { failed += 1 }
        say("\(line.ok ? "ok  " : "FAIL")  \(number)  \(title): \(line.text)")
    }
}

/// Shows a card from `arguments` and waits for it; the cards on screen once it has settled.
func show(_ arguments: [String], extra: [String: String] = [:]) -> [CGRect] {
    dripRun(arguments, extra: extra)
    guard wait(5, { showing }) != nil else { return [] }
    pause(1.2)
    return cardsOnScreen()
}

// MARK: - The agents' hooks, as `drip setup` writes them

func readJSON(_ file: String) -> [String: Any]? {
    fileManager.contents(atPath: file).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
}

/// The commands of the hooks for `event` in a settings file, those whose matcher takes `value`.
func hookCommands(_ file: String, event: String, matching value: String? = nil) -> [String] {
    let groups = (readJSON(file)?["hooks"] as? [String: Any])?[event] as? [[String: Any]] ?? []
    return groups.filter { group in
        guard let matcher = group["matcher"] as? String, !matcher.isEmpty, matcher != "*", let value else { return true }
        return value.range(of: "^(?:\(matcher))$", options: .regularExpression) != nil
    }.flatMap { ($0["hooks"] as? [[String: Any]] ?? []).compactMap { $0["command"] as? String } }
}

/// Runs every hook a Claude Code event runs, as Claude Code would.
func claude(_ event: String, _ payload: [String: Any], matching value: String? = nil) {
    var payload = payload
    payload["hook_event_name"] = event
    for command in hookCommands(path(claudeHome, "settings.json"), event: event, matching: value) {
        hook(command, payload)
    }
}

func codex(_ event: String, _ payload: [String: Any], extra: [String: String] = [:]) {
    var payload = payload
    payload["hook_event_name"] = event
    for command in hookCommands(path(codexHome, "hooks.json"), event: event) { hook(command, payload, extra: extra) }
}

// MARK: - Cleaning up

var launched: [pid_t] = []
var tmuxSocket: String?
let frontAtStart = frontApp()
/// Whether Terminal, which the cards bring forward, ran before: if not, it goes again at the end.
let terminalRan = !NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.Terminal").isEmpty
let pointerAtStart = CGEvent(source: nil)?.location ?? parking

func cleanUp() {
    helper?.quit()
    if let socket = tmuxSocket { run(["tmux", "-S", socket, "kill-server"]) }
    for pid in launched { kill(pid, SIGTERM) }
    for pid in processes(running: dripProgram) { kill(pid, SIGTERM) }
    usleep(500_000)
    for pid in launched + processes(running: dripProgram) where kill(pid, 0) == 0 { kill(pid, SIGKILL) }
    if !terminalRan {
        NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.Terminal").forEach { $0.terminate() }
    }
    backdrop.orderOut(nil)
    CGWarpMouseCursorPosition(pointerAtStart)
    if let frontAtStart, frontApp() != frontAtStart { run(["open", "-b", frontAtStart]) }
    try? fileManager.removeItem(atPath: scratch)
}

var signalSources: [DispatchSourceSignal] = []
for signal in [SIGINT, SIGTERM, SIGHUP] {
    let source = DispatchSource.makeSignalSource(signal: signal, queue: .main)
    Darwin.signal(signal, SIG_IGN)
    source.setEventHandler {
        say("mac-e2e: stopped; cleaning up")
        cleanUp()
        exit(130)
    }
    source.resume()
    signalSources.append(source)
}

// MARK: - Judging by a model

if let directory = options.judgeCheck {
    let names = ((try? fileManager.contentsOfDirectory(atPath: directory)) ?? [])
        .filter { $0.hasSuffix(".png") && $0 != "contact-sheet.png" }.map { ($0 as NSString).deletingPathExtension }.sorted()
    let verdicts = ((try? String(contentsOfFile: path(directory, "verdicts.txt"), encoding: .utf8)) ?? "")
        .split(separator: "\n").map { $0.split(separator: " ", maxSplits: 2).map(String.init) }
    var bad = 0
    for name in names {
        let verdict = verdicts.first { $0.first == name }
        let ok = verdict?.dropFirst().first == "PASS"
        if !ok { bad += 1 }
        let why = verdict.map { $0.dropFirst().joined(separator: " ") } ?? "no verdict in verdicts.txt"
        say("\(ok ? "ok  " : "FAIL")  judged  \(name)\(ok ? "" : ": " + why)")
    }
    // Nothing ran, so cleanUp() has nothing to stop; only the scratch directory made at start is left.
    try? fileManager.removeItem(atPath: scratch)
    exit(names.isEmpty || bad > 0 ? 1 : 0)
}

// MARK: - The checks

say("mac-e2e: drip \(dripRun(["--version"]).out.trimmingCharacters(in: .whitespacesAndNewlines)), scratch \(scratch)")
say("mac-e2e: hands off the mouse until it is done; it moves the pointer and clicks cards at the notch")
if let locked = (CGSessionCopyCurrentDictionary() as? [String: Any])?["CGSSessionScreenIsLocked"] as? Bool, locked {
    say("mac-e2e: the screen is locked, and drip holds cards while it is: unlock it first")
    cleanUp()
    exit(1)
}
if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
    say("mac-e2e: Reduce Motion is on, so cards fade instead of stacking; the stack checks may fail")
}
if let app = options.helper {
    helper = Helper(app: app, prompt: options.prompt)
    if helper == nil { say("mac-e2e: the helper app did not start") }
}
if !canClick {
    say("mac-e2e: clicks and VoiceOver's actions are \(ungranted)")
}
backdrop.orderFrontRegardless()
backdrop.display()
pause(0.3)

// 1. mac-check's permission card and drip dismiss.
check(1, "a permission card goes when its tool runs") { expect in
    let session = fresh("claude")
    let tool = "toolu_\(serial)"
    hook("drip hook claude", [
        "hook_event_name": "PermissionRequest", "session_id": session, "tool_name": "Bash",
        "tool_input": ["command": "swift test"], "tool_use_id": tool,
    ])
    expect.within(3, wait(3) { showing }, "the permission card shows")
    pause(1.2)
    let cards = cardsOnScreen()
    expect.expect(cards.count == 1, "one card at the notch (found \(cards.count))")
    keep("permission-card", "One black card: Claude's icon (an orange spark, or the Claude app's icon) on the left; "
        + "title 'e2e-app needs you'; grey detail 'Claude wants to run swift test'; a white dot on the right.", around: cards)
    hook("drip hook claude", ["hook_event_name": "PostToolUse", "session_id": session, "tool_name": "Bash", "tool_use_id": "toolu_other"])
    pause(1)
    expect.expect(showing, "another tool's run leaves it")
    hook("drip hook claude", ["hook_event_name": "PostToolUse", "session_id": session, "tool_name": "Bash", "tool_use_id": tool])
    expect.within(1.5, wait(3) { !showing }, "its own tool's run takes it away")
}
check(1, "drip dismiss takes a card away") { expect in
    let id = fresh("dismiss")
    let front = frontApp()
    expect.expect(!show(["info", "drip dismiss", "-d", "mac-e2e", "--stay", "--id", id]).isEmpty, "the card shows")
    dripRun(["dismiss", "--id", "e2e-another-card"])
    pause(1)
    expect.expect(showing, "drip dismiss --id for another card leaves it")
    dripRun(["dismiss"])
    expect.within(1.5, wait(3) { !showing }, "drip dismiss takes it away")
    expect.expect(frontApp() == front, "the app in front stays \(front ?? "none") (now \(frontApp() ?? "none"))")
}

// 2. Hovering: the × and the arrow.
check(2, "hovering a card") { expect in
    let id = fresh("hover")
    let cards = show(["info", "e2e hover", "-d", "the pointer comes and goes", "--stay", "--id", id])
    guard let card = cards.first, cards.count == 1 else {
        expect.expect(false, "one card shows (found \(cards.count))")
        return
    }
    keep("not-hovered", "One black card: a blue round 'i' icon on the left; title 'e2e hover'; grey detail "
        + "'the pointer comes and goes'; a small white dot on the right. No x, no arrow.", around: [card])
    let resting = Shot(notchArea)
    point(at: CGPoint(x: card.midX, y: card.midY))
    pause(0.5)
    let hovered = Shot(notchArea)
    keep("hovered", "The same card with the pointer on its text: a grey disc with a white x where the 'i' icon was, "
        + "and a white arrow pointing up and to the right where the dot was. Title and detail unchanged.", around: [card])
    point(at: CGPoint(x: card.minX + card.height * 0.45, y: card.midY))
    pause(0.4)
    let onClose = Shot(notchArea)
    keep("hovered-close", "The same card with the pointer on the x: a light grey disc with a white x on the left, "
        + "lighter than the dark grey disc it shows with the pointer elsewhere on the card; a white arrow on the right.",
        around: [card])
    let icon = CGRect(x: card.minX + 4, y: card.minY + 4, width: card.height - 8, height: card.height - 8)
    let ring = CGRect(x: card.maxX - card.height + 4, y: card.minY + 4, width: card.height - 8, height: card.height - 8)
    let text = CGRect(x: card.minX + card.height + 8, y: card.minY + 4, width: card.width - card.height * 2 - 16,
                      height: card.height - 8)
    if let resting, let hovered, let onClose {
        expect.expect(hovered.change(from: resting, in: icon) > 0.05, "the x takes the icon's place")
        expect.expect(hovered.change(from: resting, in: ring) > 0.01, "the arrow takes the dot's place")
        expect.expect(hovered.change(from: resting, in: text) < 0.01, "the text stays as it was")
        expect.expect(onClose.change(from: hovered, in: icon) > 0.02, "the x lightens with the pointer on it")
    } else {
        expect.expect(false, "screenshots of the notch (Screen Recording for the terminal?)")
    }
    point(at: parking)
    pause(0.5)
    // The waiting dot pings now and then, so the ring's place is compared with the arrow, not the dot.
    if let after = Shot(notchArea), let resting, let hovered {
        expect.expect(after.change(from: resting, in: icon) < 0.02 && after.change(from: hovered, in: ring) > 0.01,
                      "both go again once the pointer leaves")
    }
}

// 3. Clicks: the x and secondary clicks take a card away with nothing brought forward; a plain click
// brings the sending app forward.
let away: [(name: String, button: String, modifiers: [String], onClose: Bool)] = [
    ("a click on the x", "left", [], true), ("a right-click", "right", [], false),
    ("a Control-click", "left", ["control"], false), ("an Option-click", "left", ["option"], false),
]
/// An app to have in front that is none of `avoided`, the apps a card brings forward: one running
/// already, so bringing it forward opens no window, such as the app that was in front or the one
/// running this.
func anotherApp(than avoided: [String]) -> String {
    let running = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }
        .compactMap(\.bundleIdentifier)
    let candidates = [frontAtStart, app(running: getpid())?.bundleIdentifier].compactMap { $0 } + running
    return candidates.first { !avoided.contains($0) && $0 != "com.apple.finder" } ?? "com.apple.finder"
}
let elsewhere = anotherApp(than: ["com.apple.Terminal"])
if canClick {
    for variant in away {
        check(3, variant.name) { expect in
            bringForward(elsewhere)
            let cards = show(["info", "e2e \(variant.name)", "-d", "takes the card away", "--stay", "--id", fresh("click")])
            guard let card = cards.first else {
                expect.expect(false, "the card shows")
                return
            }
            let front = frontApp()
            let target = variant.onClose ? CGPoint(x: card.minX + card.height * 0.45, y: card.midY)
                : CGPoint(x: card.midX, y: card.midY)
            if variant.onClose {
                point(at: CGPoint(x: card.midX, y: card.midY))
                pause(0.3)
            }
            expect.expect(click(target, button: variant.button, modifiers: variant.modifiers), "the helper clicks")
            expect.within(1.5, wait(3) { !showing }, "it takes the card away")
            pause(0.5)
            expect.expect(frontApp() == front, "\(front ?? "none") stays in front (now \(frontApp() ?? "none"))")
        }
    }
    check(3, "a plain click") { expect in
        bringForward(elsewhere)
        guard let card = show(["info", "e2e plain click", "-d", "brings Terminal forward", "--stay", "--id", fresh("click")]).first
        else {
            expect.expect(false, "the card shows")
            return
        }
        expect.expect(click(CGPoint(x: card.midX, y: card.midY)), "the helper clicks")
        expect.within(1.5, wait(3) { !showing }, "it takes the card away")
        expect.within(3, wait(3) { frontApp() == "com.apple.Terminal" }, "Terminal, the app it came from, comes forward")
    }
} else if options.only?.contains(3) ?? true {
    skip(3, "clicks: \(ungranted)")
}

// 4. Claude Code, through the hooks `drip setup claude` writes.
check(4, "drip setup claude") { expect in
    let settings = path(claudeHome, "settings.json")
    // An older drip's Notification hook, and one of the person's own, which setup keeps.
    let old: [String: Any] = ["hooks": [
        "Notification": [["matcher": "permission_prompt|elicitation_dialog",
                          "hooks": [["type": "command", "command": "drip hook claude"]]]],
        "Stop": [["hooks": [["type": "command", "command": "echo mine"]]]],
    ]]
    fileManager.createFile(atPath: settings, contents: try? JSONSerialization.data(withJSONObject: old))
    let setup = dripRun(["setup", "claude"])
    expect.expect(setup.status == 0, "it exits 0 (\(setup.status))")
    for event in ["PermissionRequest", "Stop", "StopFailure", "PostToolUse", "PostToolUseFailure", "UserPromptSubmit",
                  "ElicitationResult"]
    {
        expect.expect(hookCommands(settings, event: event).contains("drip hook claude"), "it adds the \(event) hook")
    }
    expect.expect(hookCommands(settings, event: "Notification", matching: "permission_prompt").isEmpty
        && !hookCommands(settings, event: "Notification", matching: "elicitation_dialog").isEmpty,
        "it brings the Notification hook's matcher up to elicitation_dialog")
    expect.expect(hookCommands(settings, event: "Stop").contains("echo mine"), "it keeps the person's own hook")
    let files = (try? fileManager.contentsOfDirectory(atPath: claudeHome)) ?? []
    expect.expect(files.contains { $0.hasPrefix("settings.json.drip-backup-") }, "it backs the old file up")
    expect.expect(setup.out.contains("Claude Code can also notify you itself"), "it says Claude Code can notify too")
}
check(4, "approving in the terminal") { expect in
    let session = fresh("claude")
    let tool = "toolu_\(serial)"
    let ask: [String: Any] = ["session_id": session, "permission_mode": "default", "tool_name": "Bash",
                              "tool_input": ["command": "swift test", "description": "Run the tests"], "tool_use_id": tool]
    claude("PermissionRequest", ask)
    // The Notification Claude Code sends for the same prompt, to an older drip's matcher too.
    hook("drip hook claude", ["hook_event_name": "Notification", "session_id": session, "notification_type": "permission_prompt",
                              "message": "Claude needs your permission to use Bash"])
    claude("Notification", ["session_id": session, "notification_type": "permission_prompt",
                            "message": "Claude needs your permission to use Bash"], matching: "permission_prompt")
    expect.within(3, wait(3) { showing }, "the permission card shows")
    pause(1)
    let cards = cardsOnScreen()
    expect.expect(cards.count == 1, "PermissionRequest and the Notification show one card, not two (found \(cards.count))")
    let kept = recorded("claude:\(session)")
    expect.expect(kept.count == 1, "one card in the history (found \(kept.count))")
    expect.expect(kept.first?.card["detail"] as? String == "Run the tests", "it says what Claude wants: \(kept.first?.card["detail"] ?? "none")")
    expect.expect(kept.first?.sound == "Tink", "it asks for its sound, Tink (\(kept.first?.sound ?? "none"))")
    claude("PostToolUse", ["session_id": session, "tool_name": "Bash", "tool_use_id": tool,
                           "tool_input": ["command": "swift test"], "tool_response": ["stdout": "ok"]])
    expect.within(1.5, wait(3) { !showing }, "approving, so the tool runs, takes it away")
}
check(4, "sending a prompt") { expect in
    let session = fresh("claude")
    claude("Notification", ["session_id": session, "notification_type": "elicitation_dialog",
                            "message": "Claude has a question for you"], matching: "elicitation_dialog")
    expect.within(3, wait(3) { showing }, "the question card shows")
    pause(1)
    expect.expect(showing, "it stays")
    claude("UserPromptSubmit", ["session_id": session, "prompt": "go on"])
    expect.within(1.5, wait(3) { !showing }, "sending a prompt takes it away")
}
check(4, "a done card after a waiting one") { expect in
    let session = fresh("claude")
    claude("PermissionRequest", ["session_id": session, "tool_name": "Bash", "tool_input": ["command": "ls"], "tool_use_id": "toolu_x"])
    expect.within(3, wait(3) { showing }, "the permission card shows")
    pause(1)
    claude("Stop", ["session_id": session, "last_assistant_message": "**Listed** the files."], matching: nil)
    // The card replaces the waiting one in place; how long that takes depends on what ran before, so
    // wait for it, and fail only if it never comes.
    let appeared = wait(5) { cardsOnScreen().count == 1 }
    expect.within(5, appeared, "the done card takes its place, one card")
    let cards = cardsOnScreen()
    keep("done-card", "One black card: Claude's icon on the left; title 'e2e-app is done'; grey detail 'Listed the files.' "
        + "without asterisks; on the right a green ring with a check mark in it.", around: cards)
    let kept = recorded("claude:\(session)")
    expect.expect(kept.map(\.card).compactMap { $0["kind"] as? String } == ["info", "ok"], "the history keeps both, info then ok")
}

// 5. Whether Claude Code notifies through the terminal too is about other apps: not checked here.
if options.only?.contains(5) ?? true {
    skip(5, "Claude Code's own notifications through iTerm2, kitty or Ghostty: a fact about Claude Code, in the PR")
}

// 6. tmux: a card from another window brings the terminal showing it forward and selects the pane.
func tmux(_ arguments: [String]) -> String {
    guard let socket = tmuxSocket else { return "" }
    return run(["tmux", "-S", socket] + arguments, environment: environment).out.trimmingCharacters(in: .whitespacesAndNewlines)
}

/// Attaches a tmux client in a terminal app, which `open` starts; the client's app, once it shows.
func attach(_ opening: [String]) -> NSRunningApplication? {
    let before = Set(tmux(["list-clients", "-F", "#{client_pid}"]).split(separator: "\n"))
    run(opening)
    var found: NSRunningApplication?
    _ = wait(15) {
        let clients = tmux(["list-clients", "-F", "#{client_pid}"]).split(separator: "\n")
        guard let new = clients.first(where: { !before.contains($0) }), let pid = Int32(new) else { return false }
        found = app(running: pid)
        return found != nil
    }
    return found
}

/// Runs the Claude hook from window 2's pane, as an agent there would.
func hookFromWindow2(_ session: String) {
    let payload = path(scratch, "payload-\(session).json")
    let data = try? JSONSerialization.data(withJSONObject: [
        "hook_event_name": "PermissionRequest", "session_id": session, "cwd": project, "tool_name": "Bash",
        "tool_input": ["command": "make"], "tool_use_id": "toolu_tmux",
    ])
    fileManager.createFile(atPath: payload, contents: data)
    _ = tmux(["send-keys", "-t", "e2e:1", "drip hook claude < '\(payload)'", "Enter"])
}

if options.only?.contains(6) ?? true {
    let socket = path(scratch, "tmux.sock")
    tmuxSocket = socket
    run(["tmux", "-S", socket, "-f", "/dev/null", "new-session", "-d", "-s", "e2e", "-x", "120", "-y", "30", "/bin/sh"],
        environment: environment)
    _ = tmux(["new-window", "-d", "-t", "e2e:1", "/bin/sh"])
    // Its name is the title of the Terminal window it runs in, which the helper closes by it.
    let attachScript = path(scratch, "drip-e2e-attach.command")
    let tmuxProgram = run(["/bin/sh", "-c", "command -v tmux"]).out.trimmingCharacters(in: .whitespacesAndNewlines)
    try? "#!/bin/sh\n'\(tmuxProgram)' -S '\(socket)' attach -t e2e\nexit 0\n"
        .write(toFile: attachScript, atomically: true, encoding: .utf8)
    chmod(attachScript, 0o755)
    let mine = app(running: getpid())?.processIdentifier
    // Ghostty first, in an instance of its own that goes afterwards; then Terminal, whose window
    // stays once its shell has exited, so only when the helper can close it.
    if let ghostty = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.mitchellh.ghostty") {
        let running = { Set(NSRunningApplication.runningApplications(withBundleIdentifier: "com.mitchellh.ghostty")
            .map(\.processIdentifier)) }
        let before = running()
        // Not in the background: an instance opened with -g may never open its window to run the script.
        let first = attach(["open", "-n", "-a", ghostty.path, "--args", "-e", attachScript])
        // The instance it opened goes at the end, whether or not it attached.
        launched += running().subtracting(before).filter { $0 != mine }
        if first == nil {
            say("      tmux: \(tmux(["list-sessions"])); clients: \(tmux(["list-clients"]))")
        }
        check(6, "a card from tmux window 2 while window 1 shows") { expect in
            expect.expect(first?.bundleIdentifier == "com.mitchellh.ghostty", "Ghostty attaches to the tmux session")
            _ = tmux(["select-window", "-t", "e2e:0"])
            let session = fresh("tmux")
            hookFromWindow2(session)
            expect.within(5, wait(5) { showing }, "the card shows")
            pause(1)
            let kept = recorded("claude:\(session)").first
            expect.expect(kept?.card["activate"] as? String == "com.mitchellh.ghostty",
                          "it brings Ghostty forward, the app showing the session (\(kept?.card["activate"] ?? "none"))")
            guard canClick, let card = cardsOnScreen().first else { return }
            bringForward(anotherApp(than: ["com.apple.Terminal", "com.mitchellh.ghostty"]))
            let pane = tmux(["display-message", "-p", "-t", "e2e:1", "#{pane_id}"])
            expect.expect(click(CGPoint(x: card.midX, y: card.midY)), "the helper clicks")
            expect.within(3, wait(3) { frontApp() == "com.mitchellh.ghostty" }, "a click brings Ghostty forward")
            expect.within(2, wait(2) { tmux(["display-message", "-p", "-t", "e2e", "#{window_index} #{pane_id}"]) == "1 \(pane)" },
                          "and selects window 2's pane")
        }
    } else {
        skip(6, "Ghostty is not installed, so no terminal to attach first")
    }
    if canClick {
        let second = attach(["open", "-a", "Terminal", attachScript])
        check(6, "attached from a second terminal app") { expect in
            expect.expect(second?.bundleIdentifier == "com.apple.Terminal", "Terminal attaches too")
            _ = tmux(["select-window", "-t", "e2e:0"])
            let session = fresh("tmux")
            hookFromWindow2(session)
            expect.within(5, wait(5) { showing }, "the card shows")
            pause(1)
            let kept = recorded("claude:\(session)").first
            expect.expect(kept?.card["activate"] as? String == "com.apple.Terminal",
                          "it brings Terminal forward, which attached last (\(kept?.card["activate"] ?? "none"))")
            guard let card = cardsOnScreen().first else { return }
            bringForward(anotherApp(than: ["com.apple.Terminal"]))
            expect.expect(click(CGPoint(x: card.midX, y: card.midY)), "the helper clicks")
            expect.within(3, wait(3) { frontApp() == "com.apple.Terminal" }, "a click brings Terminal forward")
        }
    } else {
        skip(6, "clicks, and Terminal as the second app: \(ungranted)")
    }
    run(["tmux", "-S", socket, "kill-server"])
    tmuxSocket = nil
    if canClick {
        pause(0.5)
        _ = helper?.call(["op": "close", "title": "drip-e2e-attach"])
    }
}

// 7. drip pause takes a card that stays away, and drip resume brings it back.
check(7, "pausing") { expect in
    let id = fresh("pause")
    expect.expect(!show(["info", "e2e pause", "-d", "goes for the pause", "--stay", "--id", id]).isEmpty, "the card shows")
    dripRun(["pause", "10m"])
    expect.within(1.5, wait(3) { !showing }, "drip pause takes it away")
    pause(2)
    expect.expect(!showing, "it stays away while paused")
    dripRun(["resume"])
    expect.within(3, wait(4) { showing }, "drip resume shows it again")
    let kept = recorded(id)
    expect.expect(kept.count == 1 && kept.first?.missed == false, "the history keeps it once, not as missed")
    dripRun(["resume"])
}

// 8. The pointer resting on a stack: it holds for 5 seconds, then lets go; moving it holds again.
check(8, "the pointer resting on a stack") { expect in
    for name in ["one", "two", "three"] {
        dripRun(["ok", "e2e stack \(name)", "-d", "counts down 2 s", "--seconds", "2", "--id", fresh("stack")])
    }
    var cards: [CGRect] = []
    _ = wait(6) {
        cards = cardsOnScreen()
        return cards.count == 3
    }
    expect.expect(cards.count == 3, "three cards stack (found \(cards.count))")
    guard let top = cards.first else { return }
    point(at: CGPoint(x: top.midX, y: top.midY))
    let rested = Date()
    keep("stack", "Three separate black cards stacked one under another, titled 'e2e stack one', 'e2e stack two' and "
        + "'e2e stack three' from the top, each with the grey detail 'counts down 2 s'. The top card, under the "
        + "pointer, shows a grey disc with a white x on the left and a white arrow on the right; the other two show "
        + "a green check icon on the left and a green ring on the right.", around: cards)
    pause(4.6 - Date().timeIntervalSince(rested))
    expect.expect(cardsOnScreen().count == 3, "all three hold for the first 5 s of the rest")
    let went = wait(9, { !showing }) != nil
    let after = Date().timeIntervalSince(rested)
    expect.expect(went && after > 5 && after < 10, String(format: "then they count down and go (%.1f s after the rest began)", after))
}
check(8, "moving the pointer after a rest") { expect in
    dripRun(["ok", "e2e held again", "-d", "counts down 2 s", "--seconds", "2", "--id", fresh("stack")])
    guard wait(5, { showing }) != nil else {
        expect.expect(false, "the card shows")
        return
    }
    pause(1.2)
    guard let card = cardsOnScreen().first else {
        expect.expect(false, "the card shows")
        return
    }
    point(at: CGPoint(x: card.midX, y: card.midY))
    let rested = Date()
    pause(5.4)
    expect.expect(showing, "it holds while the pointer rests, then lets go")
    point(at: CGPoint(x: card.midX + 6, y: card.midY + 1))
    // Let go, it would have gone 1.5 s after the 5 s rest, and out of the notch half a second later.
    pause(8.5 - Date().timeIntervalSince(rested))
    expect.expect(showing, String(format: "moving it holds the card again (%.1f s after the rest began)", Date().timeIntervalSince(rested)))
    point(at: parking)
    expect.within(4, wait(4) { !showing }, "and it goes once the pointer leaves")
}

// 9. VoiceOver's actions: Dismiss on each card, Open on one with an app to bring forward.
if canClick {
    check(9, "VoiceOver's actions") { expect in
        bringForward(elsewhere)
        dripRun(["info", "e2e sender", "-d", "has an app", "--stay", "--id", fresh("ax")])
        dripRun(["info", "e2e no sender", "-d", "has none", "--stay", "--activate", "none", "--id", fresh("ax")])
        _ = wait(5) { showing }
        pause(1.5)
        let actions = accessibility().flatMap(\.actions)
        for expected in ["Open: e2e sender", "Dismiss: e2e sender", "Dismiss: e2e no sender"] {
            expect.expect(actions.contains(expected), "it offers \(expected)")
        }
        expect.expect(!actions.contains("Open: e2e no sender"), "no Open for the card with no app")
        expect.expect(perform("Dismiss: e2e no sender"), "VoiceOver's Dismiss runs")
        pause(1.2)
        expect.expect(!accessibility().flatMap(\.actions).contains("Dismiss: e2e no sender") && showing,
                      "it takes that card away and leaves the other")
        expect.expect(perform("Open: e2e sender"), "VoiceOver's Open runs")
        expect.within(3, wait(3) { frontApp() == "com.apple.Terminal" }, "it brings Terminal forward")
        expect.within(3, wait(3) { !showing }, "and takes the card away")
    }
} else if options.only?.contains(9) ?? true {
    skip(9, "VoiceOver's actions: \(ungranted)")
}

// 10. Codex, through the hooks `drip setup codex` writes.
check(10, "drip setup codex") { expect in
    try? "notify = [\"drip\", \"hook\", \"codex\"]\nmodel = \"gpt-5.5\"\n"
        .write(toFile: path(codexHome, "config.toml"), atomically: true, encoding: .utf8)
    let setup = dripRun(["setup", "codex"])
    expect.expect(setup.status == 0, "it exits 0 (\(setup.status))")
    let hooks = path(codexHome, "hooks.json")
    for event in ["PermissionRequest", "Stop", "PostToolUse", "UserPromptSubmit"] {
        expect.expect(hookCommands(hooks, event: event).contains("drip hook codex"), "it adds the \(event) hook")
    }
    let config = (try? String(contentsOfFile: path(codexHome, "config.toml"), encoding: .utf8)) ?? ""
    expect.expect(!config.contains("notify") && config.contains("model"), "it takes drip's notify out of config.toml, and keeps the rest")
    expect.expect(setup.out.contains("/hooks"), "it says to trust the hooks with /hooks")
}
check(10, "approving a Codex command") { expect in
    let session = fresh("codex")
    let turn = "turn-\(serial)"
    codex("PermissionRequest", ["session_id": session, "turn_id": turn, "transcript_path": NSNull(), "model": "gpt-5.5",
                                "permission_mode": "default", "tool_name": "Bash",
                                "tool_input": ["command": "npm install", "description": NSNull()]])
    expect.within(3, wait(3) { showing }, "the permission card shows")
    pause(1.2)
    let cards = cardsOnScreen()
    keep("codex-card", "One black card: the Codex or ChatGPT app's icon, or OpenAI's mark, on the left; title "
        + "'e2e-app needs you'; grey detail 'Codex wants to run npm install'; a white dot on the right.", around: cards)
    let kept = recorded("codex:\(session)").first
    expect.expect(kept?.sound == "Tink", "it asks for its sound, Tink (\(kept?.sound ?? "none"))")
    codex("PostToolUse", ["session_id": session, "turn_id": turn, "tool_name": "Bash", "tool_use_id": "call_1",
                          "tool_input": ["description": NSNull(), "command": "npm install"], "tool_response": "ok"])
    expect.within(1.5, wait(3) { !showing }, "running it takes the card away")
}
check(10, "Codex's done card while its terminal is in front") { expect in
    // Run from the app in front, as Codex in the terminal you are watching would be.
    let session = fresh("codex")
    codex("Stop", ["session_id": session, "turn_id": "t", "last_assistant_message": "Installed."],
          extra: ["__CFBundleIdentifier": frontApp() ?? elsewhere])
    expect.within(3, wait(3) { showing }, "the done card shows")
    let kept = recorded("codex:\(session)").first
    expect.expect(kept?.sound == "none", "it comes without a sound, as when_focused = quiet says (\(kept?.sound ?? "none"))")
}

// MARK: - Done

clearScreen()
contactSheet()
judgingInstructions()
cleanUp()
say("")
say("mac-e2e: \(passed) ok, \(failed) FAIL, \(skipped) skipped")
if !judged.isEmpty {
    say("mac-e2e: screenshots to judge by eye: \(path(options.out, "contact-sheet.png"))")
    say("mac-e2e: a model can judge them: follow \(path(options.out, "judge.md"))")
}
exit(failed > 0 ? 1 : 0)
