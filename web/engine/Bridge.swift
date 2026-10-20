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
/// Request: `{"args": [...], "config": "<toml>", "notch": {"width": w, "height": h},
/// "run": {"status": n, "seconds": s}, "stdin": "<text piped in>"}`. `run` is the outcome of the command `drip run` wraps,
/// which the page fakes; without it a `drip run` reply asks for it.
@_expose(wasm, "drip_command")
@_cdecl("drip_command")
public func dripCommand(_ pointer: UnsafePointer<UInt8>, _ length: Int32) -> UnsafePointer<UInt8> {
    let input = request(pointer, length)
    let args = input["args"] as? [String] ?? []
    let notch = input["notch"] as? [String: Double] ?? [:]
    let notchWidth = notch["width"] ?? 185, notchHeight = notch["height"] ?? 32

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

    func cards(_ cards: [Card], extra: [String: Any] = [:]) -> UnsafePointer<UInt8> {
        var reply = extra
        reply["warnings"] = warnings
        reply["cards"] = cards.map { island(for: $0, notchWidth: notchWidth, notchHeight: notchHeight) }
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
        if flags.seconds == nil, resolver.config.seconds == nil { flags.seconds = 2 }
        warnings += DemoCommand.warnings(flags: flags)
        do {
            return cards(try DemoCommand.cards(resolver, flags: flags), extra: ["pauses": DemoCommand.samples.map(\.pause)])
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
        let layout = animator.content(for: shape)
        let field = DropletField(metrics: metrics, shape: shape)
        let touches = field.touchesNotch
        frameBuffer += [
            shape.pillTop, shape.pillWidth, shape.pillHeight, shape.progress, shape.blend,
            shape.contentWidth ?? metrics.pillWidth, shape.pillRadius(metrics),
            layout.iconCenter.x, layout.iconCenter.y, layout.iconSize,
            layout.ringCenter.x, layout.ringCenter.y, layout.ringSize,
            layout.textX, layout.textCenterY, layout.textRoom, touches ? 1 : 0,
        ]
        // As `IslandPath.addTraced` does: from just inside the notch, on a half-point grid.
        let loops = touches ? field.outline(above: field.anchor.bottom - 4 * metrics.scale, cell: 0.5) : []
        frameBuffer.append(Double(loops.count))
        for loop in loops {
            frameBuffer.append(Double(loop.count))
            for point in loop { frameBuffer += [point.x, point.y] }
        }
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

@_expose(wasm, "drip_version")
@_cdecl("drip_version")
public func dripVersionReply() -> UnsafePointer<UInt8> {
    send(["version": dripVersion])
}
