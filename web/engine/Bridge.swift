// The browser's way into DripCore: plain WebAssembly exports that take and return JSON, plus one
// import, the page's text measurer. The page draws; everything it draws comes from here.
import DripCore
#if os(WASI)
import FoundationEssentials
import WASILibc
#else
import Foundation
#endif

// MARK: - The page's side

/// The drawn width of `text` in one of the island's fonts: 0 the title, 1 the detail, 2 the button.
@_extern(wasm, module: "drip", name: "measure")
func pageMeasure(_ font: Int32, _ scale: Double, _ text: UnsafePointer<UInt8>?, _ length: Int32) -> Double

func measure(_ font: Int32, _ scale: Double, _ text: String) -> Double {
    var text = text
    return text.withUTF8 { pageMeasure(font, scale, $0.baseAddress, Int32($0.count)) }
}

// MARK: - Memory the page writes requests into and reads replies from

@_expose(wasm, "drip_alloc")
@_cdecl("drip_alloc")
public func dripAlloc(_ size: Int32) -> UnsafeMutableRawPointer {
    UnsafeMutableRawPointer.allocate(byteCount: Int(max(size, 1)), alignment: 8)
}

@_expose(wasm, "drip_free")
@_cdecl("drip_free")
public func dripFree(_ pointer: UnsafeMutableRawPointer) {
    pointer.deallocate()
}

/// The last reply, kept until the next one so the page can copy it out.
nonisolated(unsafe) var reply: [UInt8] = []
nonisolated(unsafe) var frameBuffer: [Double] = []

@_expose(wasm, "drip_reply_length")
@_cdecl("drip_reply_length")
public func dripReplyLength() -> Int32 { Int32(reply.count) }

func send(_ object: Any) -> UnsafePointer<UInt8> {
    reply = Array(JSONText.write(object).utf8)
    return reply.withUnsafeBufferPointer { $0.baseAddress! }
}

func request(_ pointer: UnsafePointer<UInt8>, _ length: Int32) -> [String: Any] {
    JSONText.read(Data(bytes: pointer, count: Int(length))) as? [String: Any] ?? [:]
}

/// JSON to and from plain values, as JSONSerialization would, which FoundationEssentials does not have.
enum JSONText {
    private enum Value: Decodable {
        case null, bool(Bool), number(Double), string(String), array([Value]), object([String: Value])

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if container.decodeNil() { self = .null }
            else if let value = try? container.decode(Bool.self) { self = .bool(value) }
            else if let value = try? container.decode(Double.self) { self = .number(value) }
            else if let value = try? container.decode(String.self) { self = .string(value) }
            else if let value = try? container.decode([Value].self) { self = .array(value) }
            else { self = .object(try container.decode([String: Value].self)) }
        }

        var plain: Any? {
            switch self {
            case .null: return nil
            case let .bool(value): return value
            case let .number(value): return value
            case let .string(value): return value
            case let .array(values): return values.map { $0.plain as Any }
            case let .object(values): return values.compactMapValues(\.plain)
            }
        }
    }

    static func read(_ data: Data) -> Any? {
        (try? JSONDecoder().decode(Value.self, from: data))?.plain
    }

    static func write(_ value: Any) -> String {
        switch value {
        case let value as String: return quoted(value)
        case let value as Bool: return value ? "true" : "false"
        case let value as Int: return String(value)
        case let value as Int32: return String(value)
        case let value as Double: return value.isFinite ? "\(value)" : "null"
        case let values as [String: Any]:
            return "{" + values.keys.sorted().map { quoted($0) + ":" + write(values[$0]!) }.joined(separator: ",") + "}"
        case let values as [Any]: return "[" + values.map(write).joined(separator: ",") + "]"
        default: return "null"
        }
    }

    private static func quoted(_ text: String) -> String {
        var result = "\""
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\"": result += "\\\""
            case "\\": result += "\\\\"
            case "\n": result += "\\n"
            case "\r": result += "\\r"
            case "\t": result += "\\t"
            case _ where scalar.value < 0x20:
                let hex = String(scalar.value, radix: 16)
                result += "\\u" + String(repeating: "0", count: 4 - hex.count) + hex
            default: result.unicodeScalars.append(scalar)
            }
        }
        return result + "\""
    }
}

// MARK: - Commands

/// Islands the page is animating, by handle.
nonisolated(unsafe) var islands: [Int32: Island] = [:]
nonisolated(unsafe) var nextHandle: Int32 = 1

struct Island {
    var card: Card
    var animator: IslandAnimator
    var titleLines: [String]
    var detailLines: [String]
}

/// Runs a drip command line as the CLI would, up to the point where it hands cards to the screen.
///
/// Request: `{"args": [...], "env": {"DRIP_STACK": "push"}, "config": "<toml>", "notch": {"width": w, "height": h},
/// "run": {"status": n, "seconds": s}, "stdin": "<text piped in>"}`. `run` is the outcome of the command `drip run` wraps,
/// which the page fakes; without it a `drip run` reply asks for it.
///
/// The cards come in `deliveries`, shown one after another as the app shows them: each with its
/// `stack` settings, or none when the cards show one at a time. `adopting` says whether the stack
/// takes in later commands' cards while it shows, as the background drip does; `drip demo` does not.
@_expose(wasm, "drip_command")
@_cdecl("drip_command")
public func dripCommand(_ pointer: UnsafePointer<UInt8>, _ length: Int32) -> UnsafePointer<UInt8> {
    let input = request(pointer, length)
    let args = input["args"] as? [String] ?? []
    let notch = input["notch"] as? [String: Double] ?? [:]
    let notchWidth = notch["width"] ?? 185, notchHeight = notch["height"] ?? 32
    let environment = input["env"] as? [String: String] ?? [:]

    var warnings: [String] = []
    var resolver = CardResolver()
    if let text = input["config"] as? String, !text.isEmpty {
        do {
            let file = try ConfigLoader.parse(text, path: "~/.config/drip/config.toml")
            warnings += file.warnings
            resolver = CardResolver(config: file.config)
        } catch {
            return send(["exit": ExitStatus.invalidConfig, "message": "drip: \(error)"])
        }
    }

    func delivery(_ cards: [Card], stack: StackSettings?, adopting: Bool) -> [String: Any] {
        var delivery: [String: Any] = [
            "cards": cards.map { island(for: $0, notchWidth: notchWidth, notchHeight: notchHeight) },
            "adopting": adopting,
        ]
        // As the app: a stack only for notch cards with full motion.
        if let stack, let first = cards.first, first.position == .notch, first.motion == .full {
            delivery["stack"] = ["mode": stack.mode.rawValue, "max": stack.max, "pauses": stack.pauses] as [String: Any]
        }
        return delivery
    }
    func cards(_ cards: [Card], extra: [String: Any] = [:]) -> UnsafePointer<UInt8> {
        var reply = extra
        reply["warnings"] = warnings
        reply["deliveries"] = [
            delivery(cards, stack: StackSettings.current(environment: environment, config: resolver.config), adopting: true)
        ]
        return send(reply)
    }
    func failure(_ error: Error, status: Int32 = ExitStatus.usage) -> UnsafePointer<UInt8> {
        send(["exit": status, "message": "drip: \(error)"])
    }

    switch CommandLineParser.parse(args) {
    case let .exit(status, message):
        return send(["exit": status, "message": message])
    case let .invocation(.show(command)):
        do {
            let card = try resolver.resolve(
                kind: command.kind, title: command.title, flags: command.options.flags,
                standardInput: { input["stdin"] as? String })
            return cards([card])
        } catch { return failure(error) }
    case let .invocation(.run(command)):
        guard let run = input["run"] as? [String: Double] else {
            return send(["run": command.command])
        }
        do {
            let card = try resolver.resolveRun(
                command: command.command, status: Int32(run["status"] ?? 0), seconds: run["seconds"] ?? 0,
                flags: command.options.flags)
            return cards([card], extra: ["status": Int32(run["status"] ?? 0)])
        } catch { return failure(error) }
    case let .invocation(.demo(command)):
        var flags = command.options.flags
        // Short, unless a flag or the config says otherwise.
        if flags.seconds == nil, resolver.config.seconds == nil { flags.seconds = 2 }
        warnings += DemoCommand.warnings(flags: flags)
        do {
            let cards = try DemoCommand.cards(resolver, flags: flags)
            // Chained, then pushed, unless the command names one; each a stack of its own cards.
            let deliveries = command.stacks.map { mode in
                delivery(cards, stack: DemoCommand.stack(mode, environment: environment, config: resolver.config), adopting: false)
            }
            return send(["warnings": warnings, "deliveries": deliveries])
        } catch { return failure(error) }
    case let .invocation(.hook(command)):
        var flags = command.options.flags
        do {
            guard let payload = command.payload ?? input["stdin"] as? String else {
                throw UsageError("no hook payload: pass it as an argument or on stdin")
            }
            let event = try AgentHook.event(agent: command.agent, payload: payload)
            flags.id = flags.id ?? event.id
            flags.detail = flags.detail ?? event.detail
            return cards([try resolver.resolve(kind: event.kind, title: event.title, flags: flags)])
        } catch { return failure(error, status: ExitStatus.hookFailed) }
    case .invocation(.history):
        return send(["exit": 1, "message": "drip: the history lives on your Mac, not in this page"])
    case .invocation(.render), .invocation(.background):
        return send(["exit": ExitStatus.noGUISession, "message": "drip: not in a browser"])
    }
}

/// Lays a card out as the island draws it: the text wrapped to the island's column with the page's
/// fonts, and an animator for its entrance and exit. Mirrors `IslandLayers.init` in the app.
func island(for card: Card, notchWidth: Double, notchHeight: Double) -> [String: Any] {
    let scale = card.size.scale
    let hasIcon = card.icon != .none
    let buttonWidth = card.action.map { (measure(2, scale, $0.label)).rounded(.up) + 24 * scale } ?? 0
    func metrics(width: Double, height: Double, titleLines: Int, detailLines: Int) -> IslandMetrics {
        IslandMetrics(
            notchWidth: notchWidth, notchHeight: notchHeight, scale: scale, textWidth: width, textHeight: height,
            titleLines: titleLines, detailLines: detailLines, hasIcon: hasIcon, actionWidth: buttonWidth)
    }
    let column = metrics(width: 0, height: 0, titleLines: 0, detailLines: 0).textColumn
    let title = CardText.wrap(card.title, width: column, maxLines: Defaults.titleLines) { measure(0, scale, $0) }
    let detail = card.detail.map {
        CardText.wrap($0, width: column, maxLines: Defaults.detailLines) { measure(1, scale, $0) }
    } ?? []
    // AppKit's line heights for SF Pro at these sizes: ascender plus descender, rounded up.
    let titleHeight = (14 * scale * 1.193).rounded(.up), detailHeight = (12 * scale * 1.193).rounded(.up)
    let widths = title.map { min(measure(0, scale, $0).rounded(.up), column) }
        + detail.map { min(measure(1, scale, $0).rounded(.up), column) }
    let spacing = detail.isEmpty ? 0 : 3 * scale
    let height = Double(title.count) * titleHeight + Double(detail.count) * detailHeight + spacing
    let islandMetrics = metrics(
        width: widths.max() ?? 0, height: height, titleLines: title.count, detailLines: detail.count)

    let handle = nextHandle
    nextHandle += 1
    islands[handle] = Island(
        card: card, animator: IslandAnimator(metrics: islandMetrics), titleLines: title, detailLines: detail)

    let encoded = (try? JSONEncoder().encode(card)).flatMap(JSONText.read) ?? [:]
    var reply: [String: Any] = [
        "handle": handle,
        "card": encoded,
        "titleLines": title,
        "detailLines": detail,
        "titleLineHeight": titleHeight,
        "detailLineHeight": detailHeight,
        "detailSpacing": spacing,
        "metrics": [
            "notchWidth": islandMetrics.notchWidth, "notchHeight": islandMetrics.notchHeight,
            "notchRadius": islandMetrics.notchRadius, "scale": scale,
            "textWidth": islandMetrics.textWidth, "textHeight": islandMetrics.textHeight,
            "textColumn": islandMetrics.textColumn, "pillWidth": islandMetrics.pillWidth,
            "pillHeight": islandMetrics.pillHeight, "pillTop": islandMetrics.pillTop,
            "pillCornerRadius": islandMetrics.pillCornerRadius.isFinite ? islandMetrics.pillCornerRadius : -1,
            "dropSize": islandMetrics.dropSize, "maxWidth": islandMetrics.maxWidth,
            "maxHeight": islandMetrics.maxHeight, "actionWidth": buttonWidth, "hasIcon": hasIcon,
        ] as [String: Any],
        "textEdge": IslandUpdate.textEdge * scale,
        "seconds": card.seconds,
    ]
    if card.action != nil {
        let (red, green, blue) = lightRGB(card.color)
        let palette = WashPalette(accent: SRGBColor(red: red, green: green, blue: blue))
        reply["buttonColor"] = [palette.top.red, palette.top.green, palette.top.blue]
    }
    return reply
}

/// The accent as AppKit resolves it in the light appearance, which the island's button darkens.
func lightRGB(_ color: CardColor) -> (Double, Double, Double) {
    switch color {
    case let .rgb(red, green, blue): return (Double(red) / 255, Double(green) / 255, Double(blue) / 255)
    case let .system(name):
        let hex: UInt32
        switch name {
        case .green: hex = 0x34C759
        case .orange: hex = 0xFF9500
        case .red: hex = 0xFF3B30
        case .blue: hex = 0x007AFF
        case .purple: hex = 0xAF52DE
        case .pink: hex = 0xFF2D55
        case .yellow: hex = 0xFFCC00
        case .gray: hex = 0x8E8E93
        }
        return (Double(hex >> 16) / 255, Double(hex >> 8 & 0xFF) / 255, Double(hex & 0xFF) / 255)
    }
}

func cues(_ cues: IslandCues) -> [String: Any] {
    ["sides": cues.sides, "title": cues.title, "detail": cues.detail]
}

// MARK: - Motion

/// Starts the island's entrance at `time`. Replies with the content's fade cues.
@_expose(wasm, "drip_enter")
@_cdecl("drip_enter")
public func dripEnter(_ handle: Int32, _ time: Double) -> UnsafePointer<UInt8> {
    guard var island = islands[handle] else { return send([:]) }
    let reply = cues(island.animator.enter(at: time))
    islands[handle] = island
    return send(reply)
}

/// Starts the island's exit at `time`. Replies with the content's fade cues.
@_expose(wasm, "drip_exit")
@_cdecl("drip_exit")
public func dripExit(_ handle: Int32, _ time: Double) -> UnsafePointer<UInt8> {
    guard var island = islands[handle] else { return send([:]) }
    let reply = cues(island.animator.exit(at: time))
    islands[handle] = island
    return send(reply)
}

/// Jumps the island straight to fully open, as the app does when motion is not full.
@_expose(wasm, "drip_open")
@_cdecl("drip_open")
public func dripOpen(_ handle: Int32) {
    islands[handle]?.animator.open()
}

/// When every spring of the island has settled.
@_expose(wasm, "drip_end")
@_cdecl("drip_end")
public func dripEnd(_ handle: Int32) -> Double {
    islands[handle]?.animator.end ?? 0
}

@_expose(wasm, "drip_release")
@_cdecl("drip_release")
public func dripRelease(_ handle: Int32) {
    islands[handle] = nil
}

/// The island at `time`, as doubles: the shape, where the content sits, and the outline the app traces
/// while the drop and the notch melt together (empty once it floats free, when it is a plain capsule).
///
/// Layout: pillTop, pillWidth, pillHeight, progress, blend, contentWidth, pillRadius, iconX, iconY,
/// iconSize, ringX, ringY, ringSize, textX, textCenterY, textRoom, touchesNotch, loop count, then
/// each loop as its point count and x, y pairs. The page reads `drip_frame_length` doubles.
@_expose(wasm, "drip_frame")
@_cdecl("drip_frame")
public func dripFrame(_ handle: Int32, _ time: Double) -> UnsafePointer<Double> {
    frameBuffer.removeAll(keepingCapacity: true)
    if let island = islands[handle] {
        let animator = island.animator, metrics = animator.metrics
        let shape = animator.shape(at: time)
        let field = DropletField(metrics: metrics, shape: shape)
        appendFrame(shape: shape, metrics: metrics, layout: animator.content(for: shape), traced: field.touchesNotch ? field : nil)
    }
    return frameBuffer.withUnsafeBufferPointer { $0.baseAddress ?? UnsafePointer(bitPattern: 8)! }
}

@_expose(wasm, "drip_frame_length")
@_cdecl("drip_frame_length")
public func dripFrameLength() -> Int32 { Int32(frameBuffer.count) }

/// A spring's progress at `time`, for plotting the engine's curves.
@_expose(wasm, "drip_spring")
@_cdecl("drip_spring")
public func dripSpring(_ duration: Double, _ bounce: Double, _ time: Double) -> Double {
    Spring(duration: duration, bounce: bounce).progress(at: time)
}

// MARK: - The stack

/// The cards stacked at the notch, laid out as their islands; one stack at a time.
nonisolated(unsafe) var stack: CardStack?
/// Whether the stack takes in later commands' cards.
nonisolated(unsafe) var stackAdopts = false
/// The islands of the stack's own cards still waiting, in order.
nonisolated(unsafe) var stackOwn: [Int32] = []
/// Later commands' islands, waiting for the stack to take them.
nonisolated(unsafe) var stackAdoptable: [Int32] = []
/// The island each card of the stack shows, by `CardStack.Entry.id`.
nonisolated(unsafe) var stackIslands: [Int: Int32] = [:]
nonisolated(unsafe) var stackClock = 0.0

/// Starts a stack of the islands `handles`, from a delivery's settings: `{"mode": "chain", "max": 3,
/// "pauses": [...], "adopting": true, "handles": [...]}`. Its clock starts at 0.
@_expose(wasm, "drip_stack_start")
@_cdecl("drip_stack_start")
public func dripStackStart(_ pointer: UnsafePointer<UInt8>, _ length: Int32) {
    let input = request(pointer, length)
    let handles = (input["handles"] as? [Double] ?? []).map { Int32($0) }.filter { islands[$0] != nil }
    let settings = StackSettings(
        mode: StackSettings.Mode(rawValue: input["mode"] as? String ?? "") ?? .chain,
        max: Int(input["max"] as? Double ?? Double(Defaults.stackMax)),
        pauses: input["pauses"] as? [Double] ?? [])
    stack = CardStack(settings: settings, cards: handles.compactMap { islands[$0]?.card })
    stackAdopts = input["adopting"] as? Bool ?? false
    stackOwn = handles
    stackAdoptable = []
    stackIslands = [:]
    stackClock = 0
}

/// Hands a later command's island to the stack, which takes it in when there is room. Returns 0
/// when the stack does not take cards in.
@_expose(wasm, "drip_stack_adopt")
@_cdecl("drip_stack_adopt")
public func dripStackAdopt(_ handle: Int32) -> Int32 {
    guard stack != nil, stackAdopts, islands[handle] != nil else { return 0 }
    stackAdoptable.append(handle)
    return 1
}

/// Moves the stack's clock to `time`, as the app's stack does every tick: lets a card in when the
/// stack is ready for one, a later command's first, then counts down, sends cards off and closes the
/// gaps. Replies `{"entered": [{handle, start, cues, countdownFrom}], "left": [{handle, cues, time,
/// clicked}], "gone": [handle], "done": bool}`; `done` once nothing is left to show.
@_expose(wasm, "drip_stack_step")
@_cdecl("drip_stack_step")
public func dripStackStep(_ time: Double) -> UnsafePointer<UInt8> {
    guard let stack else { return send(["done": true]) }
    let elapsed = max(time - stackClock, 0)
    stackClock = time
    var entered: [[String: Any]] = []
    func enter(_ handle: Int32, own: Bool) {
        guard let island = islands[handle] else { return }
        let entry = stack.enter(island.card, metrics: island.animator.metrics, own: own, decided: time, at: time)
        stackIslands[entry.id] = handle
        guard case let .entering(start, entryCues) = entry.phase else { return }
        entered.append(["handle": handle, "start": start, "cues": cues(entryCues), "countdownFrom": entry.countdownFrom])
    }
    if stack.isReady(at: time) {
        if let handle = stackAdoptable.first, stack.waiting.isEmpty, stack.hasRoom {
            stackAdoptable.removeFirst()
            enter(handle, own: false)
        } else if stack.nextOwn(at: time) != nil {
            enter(stackOwn.removeFirst(), own: true)
        }
    }
    let changes = stack.advance(to: time, elapsed: elapsed, lead: 0)
    let left: [[String: Any]] = changes.left.compactMap { left in
        stackIslands[left.entry.id].map {
            ["handle": $0, "cues": cues(left.cues), "time": left.time, "clicked": left.clicked]
        }
    }
    let gone = changes.gone.compactMap { stackIslands.removeValue(forKey: $0.id) }
    let done = stack.entries.isEmpty && stack.waiting.isEmpty && stackAdoptable.isEmpty
    if done { dripStackEnd() }
    return send(["entered": entered, "left": left, "gone": gone, "done": done])
}

/// Ends the stack at once, as when the page is reset.
@_expose(wasm, "drip_stack_end")
@_cdecl("drip_stack_end")
public func dripStackEnd() {
    stack = nil
    stackOwn = []
    stackAdoptable = []
    stackIslands = [:]
}

/// The pointer at x, y (x from the notch's center, y down from the screen's top) at `time`, or off
/// the stack when `inside` is 0. While it is on a card nothing moves and no countdown runs. Replies
/// with the island under it, 0 for none, and whether it is on that card's button.
@_expose(wasm, "drip_stack_pointer")
@_cdecl("drip_stack_pointer")
public func dripStackPointer(_ x: Double, _ y: Double, _ inside: Int32, _ time: Double) -> UnsafePointer<UInt8> {
    guard let stack else { return send(["handle": 0, "button": false]) }
    let point = IslandPoint(x, y)
    let under = inside != 0 ? stack.entry(at: point, time: time) : nil
    stack.hover(under != nil)
    return send([
        "handle": under.flatMap { stackIslands[$0.id] } ?? 0,
        "button": under.map { stack.isOnButton(of: $0, at: point, time: time) } ?? false,
    ])
}

/// A click at x, y at `time`: on a button it runs the button's action, anywhere else on a card it
/// brings the sending app forward, and either way that card goes. Replies as `drip_stack_pointer`.
@_expose(wasm, "drip_stack_click")
@_cdecl("drip_stack_click")
public func dripStackClick(_ x: Double, _ y: Double, _ time: Double) -> UnsafePointer<UInt8> {
    guard let stack else { return send(["handle": 0, "button": false]) }
    let point = IslandPoint(x, y)
    guard let entry = stack.entry(at: point, time: time) else { return send(["handle": 0, "button": false]) }
    let button = stack.isOnButton(of: entry, at: point, time: time)
    entry.dismissed = button || (entry.dismissed ?? false)
    return send(["handle": stackIslands[entry.id] ?? 0, "button": button])
}

/// Every card of the stack at `time`, top to bottom, leaving cards included, as doubles: the card
/// count, then for each card its island's handle, the seconds left on its countdown, where its
/// capsule's top is heading, and its frame as `drip_frame` lays one out, the outline traced where its
/// drop melts into the notch or the card above it. The page reads `drip_frame_length` doubles.
@_expose(wasm, "drip_stack_frame")
@_cdecl("drip_stack_frame")
public func dripStackFrame(_ time: Double) -> UnsafePointer<Double> {
    frameBuffer.removeAll(keepingCapacity: true)
    let entries = stack?.entries ?? []
    let pieces = stack?.outline.pieces(at: time) ?? []
    frameBuffer.append(Double(entries.count))
    for (entry, piece) in zip(entries, pieces) {
        frameBuffer += [Double(stackIslands[entry.id] ?? 0), entry.remaining, entry.animator.targetTop]
        let shape = entry.animator.shape(at: time)
        var field: DropletField?
        if case let .traced(traced) = piece { field = traced }
        appendFrame(shape: shape, metrics: entry.metrics, layout: entry.animator.content(for: shape), traced: field)
    }
    return frameBuffer.withUnsafeBufferPointer { $0.baseAddress ?? UnsafePointer(bitPattern: 8)! }
}

/// One island's frame, as `drip_frame` lays it out.
func appendFrame(shape: IslandShape, metrics: IslandMetrics, layout: IslandContentLayout, traced field: DropletField?) {
    frameBuffer += [
        shape.pillTop, shape.pillWidth, shape.pillHeight, shape.progress, shape.blend,
        shape.contentWidth ?? metrics.pillWidth, shape.pillRadius(metrics),
        layout.iconCenter.x, layout.iconCenter.y, layout.iconSize,
        layout.ringCenter.x, layout.ringCenter.y, layout.ringSize,
        layout.textX, layout.textCenterY, layout.textRoom, field != nil ? 1 : 0,
    ]
    // As `IslandPath.addTraced` does: from just inside what it melts into, on a half-point grid.
    let loops = field.map { $0.outline(above: $0.anchor.bottom - 4 * metrics.scale, cell: 0.5) } ?? []
    frameBuffer.append(Double(loops.count))
    for loop in loops {
        frameBuffer.append(Double(loop.count))
        for point in loop { frameBuffer += [point.x, point.y] }
    }
}

@_expose(wasm, "drip_version")
@_cdecl("drip_version")
public func dripVersionReply() -> UnsafePointer<UInt8> {
    send(["version": dripVersion])
}
