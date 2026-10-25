// The one part of scripts/mac-e2e.sh that holds a macOS permission: Accessibility, which posting
// clicks and reading another app's accessibility actions need. It is an app of its own, launched
// with `open`, so the grant is its own and not that of the terminal running the script, and it does
// as little as it can with it: it clicks and moves the pointer only where drip's cards are, at the
// top middle of the main screen, reads or performs accessibility actions only of drip processes, and
// closes only the Terminal windows the harness opened, by their `drip-e2e-` title.
//
// scripts/mac-e2e.sh builds it with an ad-hoc signature, which the grant is tied to: the script
// rebuilds it only when this file changes, and then asks for the grant again.
//
// It answers requests the harness writes into a directory: `<n>.req`, one JSON object, answered by
// `<n>.res`. It writes `ready` once it starts, and exits on `quit` or once the harness is gone.
import AppKit
import ApplicationServices

let arguments = CommandLine.arguments
guard arguments.count >= 3, let harness = Int32(arguments[2]) else {
    FileHandle.standardError.write(Data("usage: helper <requests directory> <harness pid> [--prompt]\n".utf8))
    exit(2)
}
let directory = arguments[1]
let prompt = arguments.dropFirst(3).contains("--prompt")

func write(_ object: [String: Any], to name: String) {
    let path = (directory as NSString).appendingPathComponent(name)
    let temporary = path + ".tmp"
    guard let data = try? JSONSerialization.data(withJSONObject: object) else { return }
    FileManager.default.createFile(atPath: temporary, contents: data)
    rename(temporary, path)
}

/// Whether Accessibility is granted. Only the first call, the one that writes `ready`, may ask the
/// person; every later check just reads the answer, so polling it never raises the dialog again.
var asked = false
func trusted() -> Bool {
    let mayAsk = prompt && !asked
    asked = true
    return AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: mayAsk] as CFDictionary)
}

/// Whether `point`, in global coordinates with y down from the top of the main screen, is where
/// drip's cards are: within 360 points of the main screen's middle, and in its top 700 points.
func onCards(_ point: CGPoint) -> Bool {
    let screen = CGDisplayBounds(CGMainDisplayID())
    return abs(point.x - screen.midX) <= 360 && point.y >= screen.minY && point.y <= screen.minY + 700
}

/// Whether `pid` runs a program named drip.
func isDrip(_ pid: Int32) -> Bool {
    var buffer = [CChar](repeating: 0, count: 4096)
    guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return false }
    return (String(cString: buffer) as NSString).lastPathComponent == "drip"
}

func post(_ type: CGEventType, at point: CGPoint, button: CGMouseButton, flags: CGEventFlags, clicks: Int64 = 1) {
    guard let event = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: point, mouseButton: button)
    else { return }
    event.flags = flags
    event.setIntegerValueField(.mouseEventClickState, value: clicks)
    event.post(tap: .cghidEventTap)
}

/// The elements of drip's windows that carry a label or actions, as `[label, [action names]]`. A
/// custom action's raw name reads `Name:<name>\nTarget:...`; the name alone is kept, with the raw
/// name to perform it by.
func elements(of pid: Int32) -> [(label: String, actions: [(name: String, raw: String)], element: AXUIElement)] {
    let app = AXUIElementCreateApplication(pid)
    var found: [(String, [(String, String)], AXUIElement)] = []
    func visit(_ element: AXUIElement, depth: Int) {
        var label: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXDescriptionAttribute as CFString, &label)
        if label == nil || (label as? String)?.isEmpty == true {
            AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &label)
        }
        var names: CFArray?
        AXUIElementCopyActionNames(element, &names)
        let actions = ((names as? [String]) ?? []).compactMap { raw -> (String, String)? in
            guard raw.hasPrefix("Name:") else { return nil }
            let name = raw.dropFirst(5).split(separator: "\n", maxSplits: 1).first.map(String.init) ?? ""
            return (name, raw)
        }
        if !actions.isEmpty || (label as? String).map({ !$0.isEmpty }) == true {
            found.append(((label as? String) ?? "", actions, element))
        }
        guard depth < 6 else { return }
        var children: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &children)
        for child in (children as? [AXUIElement]) ?? [] { visit(child, depth: depth + 1) }
    }
    var windows: CFTypeRef?
    AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &windows)
    for window in (windows as? [AXUIElement]) ?? [] { visit(window, depth: 0) }
    return found.map { (label: $0.0, actions: $0.1.map { (name: $0.0, raw: $0.1) }, element: $0.2) }
}

func answer(_ request: [String: Any]) -> [String: Any] {
    let point = CGPoint(x: request["x"] as? Double ?? 0, y: request["y"] as? Double ?? 0)
    switch request["op"] as? String {
    case "trusted":
        return ["trusted": trusted()]
    case "move":
        guard onCards(point) else { return ["error": "refused: not where drip's cards are"] }
        post(.mouseMoved, at: point, button: .left, flags: [])
        return ["ok": true]
    case "click":
        guard onCards(point) else { return ["error": "refused: not where drip's cards are"] }
        let right = request["button"] as? String == "right"
        var flags: CGEventFlags = []
        let modifiers = request["modifiers"] as? [String] ?? []
        if modifiers.contains("control") { flags.insert(.maskControl) }
        if modifiers.contains("option") { flags.insert(.maskAlternate) }
        post(.mouseMoved, at: point, button: .left, flags: [])
        usleep(60_000)
        post(right ? .rightMouseDown : .leftMouseDown, at: point, button: right ? .right : .left, flags: flags)
        usleep(40_000)
        post(right ? .rightMouseUp : .leftMouseUp, at: point, button: right ? .right : .left, flags: flags)
        return ["ok": true]
    case "elements":
        guard let pid = request["pid"] as? Int, isDrip(Int32(pid)) else { return ["error": "refused: not a drip process"] }
        return ["elements": elements(of: Int32(pid)).map { ["label": $0.label, "actions": $0.actions.map(\.name)] }]
    case "perform":
        guard let pid = request["pid"] as? Int, isDrip(Int32(pid)), let name = request["name"] as? String
        else { return ["error": "refused: not a drip process"] }
        for element in elements(of: Int32(pid)) {
            if let action = element.actions.first(where: { $0.name == name }) {
                let result = AXUIElementPerformAction(element.element, action.raw as CFString)
                return result == .success ? ["ok": true] : ["error": "AXUIElementPerformAction failed: \(result.rawValue)"]
            }
        }
        return ["error": "no action named \(name)"]
    case "close":
        // The Terminal window a tmux check opened, which Terminal keeps once its shell has exited.
        guard let title = request["title"] as? String, title.hasPrefix("drip-e2e-") else {
            return ["error": "refused: not a window the harness opened"]
        }
        var closed = 0
        for app in NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.Terminal") {
            var windows: CFTypeRef?
            AXUIElementCopyAttributeValue(
                AXUIElementCreateApplication(app.processIdentifier), kAXWindowsAttribute as CFString, &windows)
            for window in (windows as? [AXUIElement]) ?? [] {
                var name: CFTypeRef?, button: CFTypeRef?
                AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &name)
                guard (name as? String)?.hasPrefix(title) == true,
                      AXUIElementCopyAttributeValue(window, kAXCloseButtonAttribute as CFString, &button) == .success,
                      let button
                else { continue }
                if AXUIElementPerformAction(button as! AXUIElement, kAXPressAction as CFString) == .success { closed += 1 }
            }
        }
        return ["closed": closed]
    case let op:
        return ["error": "unknown op \(op ?? "none")"]
    }
}

write(["trusted": trusted(), "pid": Int(getpid())], to: "ready")
let decoder = { (path: String) -> [String: Any]? in
    FileManager.default.contents(atPath: path).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
}
while kill(harness, 0) == 0, !FileManager.default.fileExists(atPath: (directory as NSString).appendingPathComponent("quit")) {
    let names = ((try? FileManager.default.contentsOfDirectory(atPath: directory)) ?? []).filter { $0.hasSuffix(".req") }.sorted()
    for name in names {
        let path = (directory as NSString).appendingPathComponent(name)
        let reply = decoder(path).map(answer) ?? ["error": "unreadable request"]
        unlink(path)
        write(reply, to: (name as NSString).deletingPathExtension + ".res")
    }
    usleep(10_000)
}
