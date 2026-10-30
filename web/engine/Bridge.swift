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
/// "widest": w, "run": {"status": n, "seconds": s}, "stdin": "<text piped in>"}`. `widest` caps how wide a card
/// gets, for a screen narrower than the app's widest card, so its text wraps sooner. `run` is the outcome
/// of the command `drip run` wraps, which the page fakes; without it a `drip run` reply asks for it.
///
/// The cards come in `deliveries`, shown one after another as the app shows them: each with its
/// `stack` settings, or none when the cards show one at a time. `adopting` says whether the stack
/// takes in later commands' cards while it shows, as the background drip does, and as a drip that
/// waits for its question's answer does while the question shows.
/// `adoptable` says whether a stack showing may take these cards in: not a question's, nor those of
/// a drip that waits for them.
@_expose(wasm, "drip_command")
@_cdecl("drip_command")
public func dripCommand(_ pointer: UnsafePointer<UInt8>, _ length: Int32) -> UnsafePointer<UInt8> {
    let input = request(pointer, length)
    let args = input["args"] as? [String] ?? []
    let notch = input["notch"] as? [String: Double] ?? [:]
    let notchWidth = notch["width"] ?? 185, notchHeight = notch["height"] ?? 32
    let widest = min(input["widest"] as? Double ?? .infinity, CardMetrics.maxWidth)
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

    // The page draws symbols and drip's bundled marks only: as the app does with an icon that cannot
    // load, a picture falls back to the preset's icon, with a warning.
    func prepared(_ cards: [Card]) -> [Card] {
        cards.map { card in
            var card = card
            switch card.icon {
            case let .image(path):
                warnings.append("the page cannot show the image '\(path)'; using the preset's icon")
                card.icon = card.fallbackIcon
            case let .app(identifier):
                warnings.append("no app with the bundle identifier '\(identifier)' is installed in this page; using the preset's icon")
                card.icon = card.fallbackIcon
            case .none, .symbol, .mark:
                break
            }
            return card
        }
    }

    func delivery(_ cards: [Card], stack: StackSettings?, adopting: Bool, adoptable: Bool) -> [String: Any] {
        var delivery: [String: Any] = [
            "cards": prepared(cards).map { island(for: $0, notchWidth: notchWidth, notchHeight: notchHeight, widest: widest) },
            "adopting": adopting,
            "adoptable": adoptable,
        ]
        // As the app: a stack only for cards with full motion.
        if let stack, let first = cards.first, first.motion == .full {
            delivery["stack"] = ["mode": stack.mode.rawValue, "max": stack.max] as [String: Any]
        }
        return delivery
    }
    // As the app: cards drip returns from at once go to the background drip, so a stack showing can
    // take them in; a question or --wait shows from this drip, in its turn.
    func cards(_ cards: [Card], wait: Bool, extra: [String: Any] = [:]) -> UnsafePointer<UInt8> {
        var reply = extra
        let background = Delivery.choose(for: cards, wait: wait) == .background
        reply["deliveries"] = [
            delivery(
                cards, stack: StackSettings.current(environment: environment, config: resolver.config),
                adopting: background || cards.contains(where: \.waitsForAnswer), adoptable: background)
        ]
        // After the deliveries, which can warn about an icon.
        reply["warnings"] = warnings
        return send(reply)
    }
    func failure(_ error: Error, status: Int32 = ExitStatus.usage, subcommand: String? = nil) -> UnsafePointer<UInt8> {
        let message = (error as? UsageError).map { CommandLineParser.usageMessage($0.message, subcommand: subcommand) }
        return send(["exit": status, "message": message ?? "drip: \(error)"])
    }

    switch CommandLineParser.parse(args) {
    case let .exit(status, message):
        return send(["exit": status, "message": message])
    case let .invocation(.show(command)):
        warnings += command.options.warnings
        do {
            let card = try resolver.resolve(
                kind: command.kind, title: command.title, rest: command.rest, flags: command.options.flags,
                standardInput: { input["stdin"] as? String })
            return cards([card], wait: command.options.flags.wait)
        } catch { return failure(error) }
    case let .invocation(.run(command)):
        warnings += command.options.warnings
        guard let run = input["run"] as? [String: Double] else {
            return send(["run": command.command])
        }
        do {
            let card = try resolver.resolveRun(
                command: command.command, status: Int32(run["status"] ?? 0), seconds: run["seconds"] ?? 0,
                flags: command.options.flags)
            return cards([card], wait: command.options.flags.wait, extra: ["status": Int32(run["status"] ?? 0)])
        } catch { return failure(error) }
    case let .invocation(.hook(command)):
        warnings += command.options.warnings
        var flags = command.options.flags
        do {
            guard let payload = command.payload ?? input["stdin"] as? String else {
                throw UsageError("no hook payload: pass it as an argument or on stdin")
            }
            // A hook that takes a waiting card away shows nothing, as on a Mac, and nor does one from
            // a session nobody attends, or with DRIP_HOOK=off; DRIP_HOOK=attention also skips done cards.
            guard try AgentHook.speaks(for: command.agent, environment: environment),
                  case let .card(event) = try AgentHook.outcome(agent: command.agent, payload: payload, environment: environment)
            else {
                return send(["deliveries": [Any](), "warnings": warnings])
            }
            flags = event.filling(flags)
            // No app is installed in a web page.
            flags.icon = flags.icon ?? command.agent.icon { _ in false }
            return cards([try resolver.resolve(kind: event.kind, title: event.title, flags: flags)], wait: flags.wait)
        } catch {
            return failure(error, status: ExitStatus.hookFailed, subcommand: HookCommand.configuration.commandName)
        }
    case let .invocation(.setup(command)):
        guard let agent = command.agent else {
            return send(["exit": ExitStatus.shown, "message": RemoteHook.script])
        }
        if command.printOnly || command.remote {
            return send(["exit": ExitStatus.shown, "message": AgentSetup.snippet(for: agent, remote: command.remote)])
        }
        return send([
            "exit": ExitStatus.setupFailed,
            "message": "drip: drip setup adds hooks to your agent's settings on your Mac, not in this page. "
                + "drip setup \(agent.rawValue) --print shows them here.",
        ])
    case .invocation(.follow):
        return send(["exit": ExitStatus.followFailed, "message": "drip: drip follow reads another machine over ssh from your Mac, not from this page"])
    case let .invocation(.dismiss(command)):
        // The page takes its own cards away, those with the id when one is given.
        return send(["dismiss": command.id.map { ["id": $0] } ?? [String: Any]()])
    case .invocation(.history):
        return send(["exit": 1, "message": "drip: the history lives on your Mac, not in this page"])
    case .invocation(.debug):
        return send(["exit": 1, "message": "drip: the debug log lives on your Mac, not in this page"])
    case .invocation(.pause), .invocation(.resume):
        return send(["exit": 1, "message": "drip: a pause holds the cards on your Mac, not in this page"])
    case .invocation(.render), .invocation(.background):
        return send(["exit": ExitStatus.noGUISession, "message": "drip: not in a browser"])
    }
}

/// Lays a card out as the island draws it: the text wrapped to the island's column with the page's
/// fonts, and an animator for its entrance and exit. Mirrors `IslandLayers.init` in the app.
func island(for card: Card, notchWidth: Double, notchHeight: Double, widest: Double) -> [String: Any] {
    let scale = card.size.scale
    let hasIcon = card.showsIconAtNotch
    func buttonWidth(_ label: String) -> Double { measure(2, scale, label).rounded(.up) + 24 * scale }
    let declineWidth = card.action?.decline.map(buttonWidth) ?? 0
    let actionWidth = card.action.map {
        IslandMetrics.buttonsWidth(yes: buttonWidth($0.label), no: $0.decline.map(buttonWidth), scale: scale)
    } ?? 0
    func metrics(width: Double, height: Double, titleLines: Int, detailLines: Int) -> IslandMetrics {
        IslandMetrics(
            notchWidth: notchWidth, notchHeight: notchHeight, scale: scale, textWidth: width, textHeight: height,
            titleLines: titleLines, detailLines: detailLines, hasIcon: hasIcon, actionWidth: actionWidth,
            declineWidth: declineWidth, widestPill: widest)
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
            "maxHeight": islandMetrics.maxHeight, "actionWidth": actionWidth, "declineWidth": declineWidth,
            "buttonGap": islandMetrics.buttonGap, "hasIcon": hasIcon,
        ] as [String: Any],
        "textEdge": IslandUpdate.textEdge * scale,
        // How long it stays when nothing holds, clicks or replaces it; `waits` when it has no
        // countdown, `waitsForAnswer` when it never gives way, `waitingMark` when the waiting dot
        // stands where the ring would, and `ringGlyph` the state's mark the ring shows around it, or
        // "" for none.
        "seconds": card.duration,
        "waits": card.waits,
        "waitsForAnswer": card.waitsForAnswer,
        "waitingMark": card.showsWaitingMark,
        "ringGlyph": card.ringGlyph ?? "",
    ]
    if case let .mark(name) = card.icon, let mark = AgentMark.named(name) {
        reply["mark"] = drawing(of: mark)
    }
    if card.action != nil {
        let (red, green, blue) = lightRGB(card.color)
        let palette = ButtonPalette(accent: SRGBColor(red: red, green: green, blue: blue))
        reply["buttonColor"] = [palette.fill.red, palette.fill.green, palette.fill.blue]
    }
    return reply
}

/// A bundled mark as the page draws it at the notch, bare on the island's black, in a `size` icon
/// centred on 0, 0: each layer's fill and its path in the icon's points, as opcodes and coordinates: 0 move x y,
/// 1 line x y, 2 cubic x1 y1 x2 y2 x y, 3 close. A fill is `solid` red, green, blue, or `linear`
/// x1 y1 x2 y2 with `stops` of offset, red, green, blue, opacity. Laid out for a 1 point icon; the
/// page scales it.
func drawing(of mark: AgentMark) -> [String: Any] {
    let place = mark.placement(side: 1)
    func point(_ x: Double, _ y: Double) -> [Double] { [x * place.scale + place.x - 0.5, y * place.scale + place.y - 0.5] }
    let layers = zip(mark.layers, mark.outlines).map { layer, segments -> [String: Any] in
        let path = segments.flatMap { segment -> [Double] in
            switch segment {
            case let .move(x, y): return [0] + point(x, y)
            case let .line(x, y): return [1] + point(x, y)
            case let .cubic(x1, y1, x2, y2, x, y): return [2] + point(x1, y1) + point(x2, y2) + point(x, y)
            case .close: return [3]
            }
        }
        let fill: [String: Any]
        switch layer.fill {
        case let .solid(color):
            fill = ["solid": [color.red, color.green, color.blue]]
        case let .linear(x1, y1, x2, y2, stops):
            fill = [
                "linear": point(x1, y1) + point(x2, y2),
                "stops": stops.map { [$0.offset, $0.color.red, $0.color.green, $0.color.blue, $0.opacity] },
            ]
        }
        return ["fill": fill, "path": path]
    }
    return ["layers": layers]
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

// MARK: - Stacks

/// One stack of cards at a notch, laid out as their islands. A page can show several notches, each
/// with its own stack, at once.
final class StackSession {
    let stack: CardStack
    /// Whether the stack takes in later commands' cards, as the app's background drip does, or, for
    /// one that waits for its question's answer, while the question shows.
    let adopts: Bool
    /// Whether one of its own cards is a question that waits for its answer: the stack then takes in
    /// only cards that count down while its own cards show, and once they have gone, any card, as
    /// the background drip the app's hands its cards on to does.
    let asks: Bool
    /// The islands of the stack's own cards still waiting, in order.
    var own: [Int32]
    /// Later commands' islands, waiting for the stack to take them or to show them in place of a
    /// card with the same id.
    var adoptable: [Int32] = []
    /// The island each card of the stack shows, by `CardStack.Entry.id`.
    var islandOf: [Int: Int32] = [:]
    /// The islands of the cards that gave way and wait to come back, in `CardStack.tucked`'s order:
    /// the page keeps them.
    var tucked: [Int32] = []
    var clock = 0.0
    /// Where the pointer last was on the stack, nil while it is off it.
    var pointer: IslandPoint?

    init(stack: CardStack, adopts: Bool, own: [Int32]) {
        self.stack = stack
        self.own = own
        asks = stack.waiting.contains(where: \.waitsForAnswer)
        self.adopts = adopts && !asks
        stack.measureCount = { measure(2, 1, $0) }
        // As the app's background drip: a card that waits for you and gives way comes back.
        stack.tucks = self.adopts
    }

    /// Later commands' cards still offered, oldest first.
    var offered: [Card] { adoptable.compactMap { islands[$0]?.card } }

    /// Whether the stack takes `card` in now. A question never is.
    func takes(_ card: Card) -> Bool {
        !card.asksQuestion && (adopts || (asks && (stack.ownCardsGone || !card.waits)))
    }
}

nonisolated(unsafe) var stacks: [Int32: StackSession] = [:]
nonisolated(unsafe) var nextStack: Int32 = 1

/// Starts a stack of the islands `handles`, from a delivery's settings: `{"mode": "chain", "max": 3,
/// "adopting": true, "handles": [...]}`. Its clock starts at 0. Returns its handle.
@_expose(wasm, "drip_stack_start")
@_cdecl("drip_stack_start")
public func dripStackStart(_ pointer: UnsafePointer<UInt8>, _ length: Int32) -> Int32 {
    let input = request(pointer, length)
    let handles = (input["handles"] as? [Double] ?? []).map { Int32($0) }.filter { islands[$0] != nil }
    let settings = StackSettings(
        mode: StackSettings.Mode(rawValue: input["mode"] as? String ?? "") ?? .chain,
        max: Int(input["max"] as? Double ?? Double(Defaults.stackMax)))
    let handle = nextStack
    nextStack += 1
    stacks[handle] = StackSession(
        stack: CardStack(settings: settings, cards: handles.compactMap { islands[$0]?.card }),
        adopts: input["adopting"] as? Bool ?? false, own: handles)
    return handle
}

/// Hands a later command's island to the stack, which shows it in place of a card with the same id,
/// or takes it in when there is room. A newer island with the same id as one still waiting takes
/// that one's place. Replies `{"taken": bool, "dropped": handle}`, `dropped` the waiting island it
/// replaced (0 for none), which the page releases; nothing is taken when the stack does not adopt
/// it, and the page then shows it in its turn.
@_expose(wasm, "drip_stack_offer")
@_cdecl("drip_stack_offer")
public func dripStackOffer(_ stackHandle: Int32, _ handle: Int32) -> UnsafePointer<UInt8> {
    guard let session = stacks[stackHandle], let island = islands[handle], session.takes(island.card) else {
        return send(["taken": false, "dropped": 0])
    }
    var dropped: Int32 = 0
    if let id = island.card.id,
       let index = session.adoptable.firstIndex(where: { islands[$0]?.card.id == id })
    {
        dropped = session.adoptable.remove(at: index)
    }
    session.adoptable.append(handle)
    return send(["taken": true, "dropped": dropped])
}

/// Moves the stack's clock to `time`, as the app's stack does every tick. When the stack is at rest
/// it takes in a later command's card, first one that shows in place of a card with the same id,
/// then its own next card. Then it counts down, sends cards off and closes the gaps. `othersWaiting`
/// is 1 while a later command's cards wait for the stack to finish, such as a question: cards that
/// wait for you give way to them, as they do to a newer drip waiting for its turn. Replies
/// `{"entered": [{handle, start, cues, countdownFrom, waits}], "swapped": [{handle, old, time, kept,
/// newState, inRing, waits}], "stoppedWaiting": [handle], "left": [{handle, cues, time, clicked}],
/// "gone": [handle], "done": bool}`. `kept` says which of the new card's lines, title then detail,
/// stay as they were, `newState` whether its state changed and `inRing` whether that lands in the
/// ring, as the app's crossfade reads them. `waits` says the card waits for you, with no countdown,
/// until it is in `stoppedWaiting`. `done` once nothing is left to show.
@_expose(wasm, "drip_stack_step")
@_cdecl("drip_stack_step")
public func dripStackStep(_ stackHandle: Int32, _ time: Double, _ othersWaiting: Int32) -> UnsafePointer<UInt8> {
    guard let session = stacks[stackHandle] else { return send(["done": true]) }
    let stack = session.stack
    let elapsed = max(time - session.clock, 0)
    session.clock = time
    var entered: [[String: Any]] = []
    var swapped: [[String: Any]] = []
    func enter(_ handle: Int32, own: Bool) {
        guard let island = islands[handle] else { return }
        let entry = stack.enter(island.card, metrics: island.animator.metrics, own: own, decided: time, at: time)
        session.islandOf[entry.id] = handle
        guard case let .entering(start, entryCues) = entry.phase else { return }
        entered.append([
            "handle": handle, "start": start, "cues": cues(entryCues), "countdownFrom": entry.countdownFrom,
            "waits": entry.isWaiting,
        ])
    }
    // As StackPresenter.admit: one change at a time, into a stack at rest, and while no card waits
    // past a full stack; else the next card grows out of the overflow drop when it can.
    admit: if stack.isReady(at: time) {
        for handle in session.adoptable {
            guard let island = islands[handle] else { continue }
            if let id = island.card.id,
               let shown = stack.live.first(where: { $0.card.id == id && $0.isShown }),
               CardReplacement.canSwap(shown.card, for: island.card),
               let old = session.islandOf[shown.id], let before = islands[old]
            {
                session.adoptable.removeAll { $0 == handle }
                stack.swap(shown, for: island.card, metrics: island.animator.metrics, at: time, reduced: false)
                session.islandOf[shown.id] = handle
                swapped.append([
                    "handle": handle, "old": old, "time": time,
                    "kept": IslandUpdate.unchanged(
                        oldTitle: before.titleLines, oldDetail: before.detailLines,
                        newTitle: island.titleLines, newDetail: island.detailLines,
                        from: before.animator.metrics, to: island.animator.metrics),
                    "newState": IslandUpdate.changesState(from: before.card, to: island.card),
                    "inRing": IslandUpdate.landsInRing(from: before.card, to: island.card),
                    "waits": shown.isWaiting,
                ])
                continue
            }
            guard stack.overflow == nil, stack.waiting.isEmpty, stack.hasRoom else { break }
            session.adoptable.removeAll { $0 == handle }
            enter(handle, own: false)
            break admit
        }
        if stack.overflow == nil, stack.nextOwn() != nil {
            enter(session.own.removeFirst(), own: true)
        } else if stack.overflow == nil, session.adoptable.isEmpty, let tucked = stack.nextTucked() {
            enter(session.tucked.removeFirst(), own: tucked.own)
        }
    }
    func release() {
        guard stack.canRelease(at: time) else { return }
        var next: (handle: Int32, own: Bool)?
        if stack.nextOwn() != nil {
            next = (session.own.removeFirst(), true)
        } else if let handle = session.adoptable.first(where: { islands[$0].map { !stack.swapsInPlace($0.card) } ?? false }) {
            session.adoptable.removeAll { $0 == handle }
            next = (handle, false)
        } else if let tucked = stack.nextTucked() {
            next = (session.tucked.removeFirst(), tucked.own)
        }
        if let next, let island = islands[next.handle],
           let release = stack.release(island.card, metrics: island.animator.metrics, own: next.own, at: time)
        {
            session.islandOf[release.entry.id] = next.handle
            if case let .entering(start, entryCues) = release.entry.phase {
                entered.append([
                    "handle": next.handle, "start": start, "cues": cues(entryCues),
                    "countdownFrom": release.entry.countdownFrom, "waits": release.entry.isWaiting,
                    "fromDrop": release.last ? release.count : 0,
                    "handOver": [CardStack.handOver.duration, CardStack.handOver.bounce, CardStack.handOver.settlingTime],
                    "rollsUp": stack.handOverRollsUp,
                ])
            }
        }
    }
    release()
    // Later commands' cards still offered want room, and those the stack did not take want it to
    // finish; cards that wait for you give way to them.
    let changes = stack.advance(
        to: time, elapsed: elapsed, lead: 0, needsRoom: !session.adoptable.isEmpty, othersWaiting: othersWaiting != 0,
        queued: session.offered)
    // As StackPresenter.tick: a card leaving makes room for the next card waiting in the overflow
    // drop, which grows out of it from the same moment.
    if !changes.left.isEmpty { release() }
    peek(stack, at: session.pointer, time: time)
    let stoppedWaiting = changes.stoppedWaiting.compactMap { session.islandOf[$0.id] }
    let left: [[String: Any]] = changes.left.compactMap { left in
        session.islandOf[left.entry.id].map {
            ["handle": $0, "cues": cues(left.cues), "time": left.time, "clicked": left.clicked]
        }
    }
    // A card that gave way keeps its island, to come back on.
    session.tucked += changes.tucked.compactMap { session.islandOf[$0.id] }
    let gone = changes.gone.compactMap { entry -> Int32? in
        guard let handle = session.islandOf.removeValue(forKey: entry.id) else { return nil }
        return session.tucked.contains(handle) ? nil : handle
    }
    let done = stack.entries.isEmpty && stack.waiting.isEmpty && stack.tucked.isEmpty && session.adoptable.isEmpty
        && stack.overflow == nil
    if done { stacks[stackHandle] = nil }
    return send([
        "entered": entered, "swapped": swapped, "stoppedWaiting": stoppedWaiting, "left": left, "gone": gone,
        "done": done, "overflow": stack.overflow.map(overflowState) ?? [String: Any](),
    ])
}

/// The overflow drop as the page paints its count: `count` and the `previous` count it rolled from
/// at `changedAt`, up when `rollsUp`, on the `handOver` spring, as duration, bounce and settling time, when a card grew out of it;
/// `phase` "forming" from `start` with the count fading in at `cue`, "shown",
/// "releasing" or "leaving" from `start`; `peeking` since `peekChangedAt`, or back to its count
/// since then, listing `titles`. An empty object for no drop.
func overflowState(_ overflow: CardStack.Overflow) -> [String: Any] {
    var state: [String: Any] = [
        "count": overflow.count, "previous": overflow.previous, "changedAt": overflow.changedAt,
        "handOver": overflow.handedOver ? [CardStack.handOver.duration, CardStack.handOver.bounce, CardStack.handOver.settlingTime] : [Double](),
        "peeking": overflow.peeking, "peekChangedAt": overflow.peekChangedAt, "titles": overflow.peekText,
        "scale": overflow.metrics.scale, "rollsUp": overflow.rollsUp,
    ]
    switch overflow.phase {
    case let .forming(start, cues):
        state["phase"] = "forming"
        state["start"] = start
        state["cue"] = CardStack.countCue(cues)
    case .shown:
        state["phase"] = "shown"
    case .releasing:
        state["phase"] = "releasing"
    case let .leaving(start, _):
        state["phase"] = "leaving"
        state["start"] = start
    }
    return state
}

/// Ends the stack at once, as when the page is reset. Replies with every island it still holds,
/// waiting ones included, for the page to release.
@_expose(wasm, "drip_stack_end")
@_cdecl("drip_stack_end")
public func dripStackEnd(_ stackHandle: Int32) -> UnsafePointer<UInt8> {
    guard let session = stacks.removeValue(forKey: stackHandle) else { return send(["handles": [Int32]()]) }
    return send(["handles": Array(session.islandOf.values) + session.own + session.adoptable + session.tucked])
}

/// The pointer at x, y (x from the notch's center, y down from the screen's top) at `time`, or off
/// the stack when `inside` is 0. While it is on a card or on the overflow drop nothing moves and no
/// countdown runs, and on the drop, the drop springs wide to list the titles waiting. Replies with
/// the island under it, 0 for none, the button of that card it is on: "yes", a question's "no", or
/// "" for none, and whether it is on the drop.
@_expose(wasm, "drip_stack_pointer")
@_cdecl("drip_stack_pointer")
public func dripStackPointer(_ stackHandle: Int32, _ x: Double, _ y: Double, _ inside: Int32, _ time: Double) -> UnsafePointer<UInt8> {
    guard let session = stacks[stackHandle] else { return send(["handle": 0, "button": "", "drop": false]) }
    let point = IslandPoint(x, y)
    let stack = session.stack
    let moved = (inside != 0 ? point : nil) != session.pointer
    session.pointer = inside != 0 ? point : nil
    let under = inside != 0 ? stack.entry(at: point, time: time) : nil
    let onDrop = peek(stack, at: session.pointer, time: time)
    // Held while the pointer moves on it, as on a Mac, and let go once it rests.
    stack.hover(under != nil || onDrop, moved: moved, at: time)
    return send([
        "handle": under.flatMap { session.islandOf[$0.id] } ?? 0,
        "button": named(under.flatMap { stack.button(of: $0, at: point, time: time) }), "drop": onDrop,
    ])
}

/// Springs the overflow drop wide to list the titles waiting while `point` is on it, or back to its
/// count when it is not, at `time`. Returns whether `point` is on the drop.
@discardableResult
func peek(_ stack: CardStack, at point: IslandPoint?, time: Double) -> Bool {
    let onDrop = point.map { stack.isOnOverflow($0, time: time) } ?? false
    stack.peek(width: onDrop ? stack.overflow.map { measure(1, 1, $0.peekText) } : nil, at: time)
    return onDrop
}

/// A button as the page names it: "yes", "no", or "" for none.
func named(_ answer: CardAnswer?) -> String {
    switch answer {
    case .yes: return "yes"
    case .no: return "no"
    case nil: return ""
    }
}

/// A click at x, y at `time`: on a button it runs the button's action, anywhere else on a card it
/// brings the sending app forward, and either way that card goes. Replies as `drip_stack_pointer`.
@_expose(wasm, "drip_stack_click")
@_cdecl("drip_stack_click")
public func dripStackClick(_ stackHandle: Int32, _ x: Double, _ y: Double, _ time: Double) -> UnsafePointer<UInt8> {
    let point = IslandPoint(x, y)
    guard let session = stacks[stackHandle], let entry = session.stack.entry(at: point, time: time) else {
        return send(["handle": 0, "button": ""])
    }
    let answer = session.stack.button(of: entry, at: point, time: time)
    if answer != nil, entry.dismissed == nil { entry.answer = answer }
    entry.dismissed = answer != nil || (entry.dismissed ?? false)
    return send(["handle": session.islandOf[entry.id] ?? 0, "button": named(answer)])
}

/// Takes the card of the island `handle` away, as `drip dismiss` does on a Mac. Replies 1 when it
/// shows, and goes as cards go; 2 when it was still to come, and is dropped, for the page to release
/// its island; 0 when the stack does not hold it.
@_expose(wasm, "drip_stack_dismiss")
@_cdecl("drip_stack_dismiss")
public func dripStackDismiss(_ stackHandle: Int32, _ handle: Int32) -> Int32 {
    guard let session = stacks[stackHandle] else { return 0 }
    if let entry = session.stack.live.first(where: { session.islandOf[$0.id] == handle }) {
        entry.dismissed = entry.dismissed ?? false
        return 1
    }
    if let index = session.own.firstIndex(of: handle) {
        session.own.remove(at: index)
        session.stack.dropWaiting(at: index)
        return 2
    }
    if let index = session.adoptable.firstIndex(of: handle) {
        session.adoptable.remove(at: index)
        return 2
    }
    if let index = session.tucked.firstIndex(of: handle) {
        session.tucked.remove(at: index)
        session.stack.dropTucked(at: index)
        return 2
    }
    return 0
}

/// Every card of the stack at `time`, top to bottom, leaving cards included, as doubles: the card
/// count, then for each card its island's handle, the seconds left on its countdown, where its
/// capsule's top is heading, how solid its black shape is, and its frame as `drip_frame` lays one
/// out, the outline traced where its drop melts into the notch or the card above it. The page reads
/// `drip_frame_length` doubles.
@_expose(wasm, "drip_stack_frame")
@_cdecl("drip_stack_frame")
public func dripStackFrame(_ stackHandle: Int32, _ time: Double) -> UnsafePointer<Double> {
    frameBuffer.removeAll(keepingCapacity: true)
    let session = stacks[stackHandle]
    let entries = session?.stack.entries ?? []
    let pieces = session?.stack.outline.pieces(at: time) ?? []
    frameBuffer.append(Double(entries.count))
    for (entry, piece) in zip(entries, pieces) {
        let shape = entry.animator.shape(at: time)
        frameBuffer += [Double(session?.islandOf[entry.id] ?? 0), entry.remaining, entry.animator.targetTop, shape.opacity]
        var field: DropletField?
        if case let .traced(traced) = piece { field = traced }
        appendFrame(shape: shape, metrics: entry.metrics, layout: entry.animator.content(for: shape), traced: field)
    }
    return frameBuffer.withUnsafeBufferPointer { $0.baseAddress ?? UnsafePointer(bitPattern: 8)! }
}

/// The overflow drop at `time`, as doubles: 0 for none, else 1, its capsule's pillTop, pillWidth,
/// pillHeight and pillRadius, then the pieces of the outline it adds, the drop's own first, then
/// each card dripping into it: their count, then each as 1, a loop count and each loop as its point
/// count and x, y pairs, for a piece traced where it melts into something, or as 0, pillTop,
/// pillWidth, pillHeight and pillRadius for a plain capsule. The page reads `drip_frame_length`
/// doubles.
@_expose(wasm, "drip_stack_overflow_frame")
@_cdecl("drip_stack_overflow_frame")
public func dripStackOverflowFrame(_ stackHandle: Int32, _ time: Double) -> UnsafePointer<Double> {
    frameBuffer.removeAll(keepingCapacity: true)
    guard let stack = stacks[stackHandle]?.stack, let overflow = stack.overflow else {
        frameBuffer.append(0)
        return frameBuffer.withUnsafeBufferPointer { $0.baseAddress ?? UnsafePointer(bitPattern: 8)! }
    }
    let shape = overflow.animator.shape(at: time)
    frameBuffer += [1, shape.pillTop, shape.pillWidth, shape.pillHeight, shape.pillRadius(overflow.animator.metrics)]
    let pieces = stack.outline.overflowPieces(at: time)
    frameBuffer.append(Double(pieces.count))
    for piece in pieces {
        switch piece {
        case let .traced(field):
            let loops = field.outline(above: field.traceTop, cell: 0.5)
            frameBuffer += [1, Double(loops.count)]
            for loop in loops {
                frameBuffer.append(Double(loop.count))
                for point in loop { frameBuffer += [point.x, point.y] }
            }
        case let .capsule(shape, metrics):
            frameBuffer += [0, shape.pillTop, shape.pillWidth, shape.pillHeight, shape.pillRadius(metrics)]
        }
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
    let loops = field.map { $0.outline(above: $0.traceTop, cell: 0.5) } ?? []
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
