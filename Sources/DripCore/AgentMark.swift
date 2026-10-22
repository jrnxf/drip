#if os(WASI)
import FoundationEssentials
import WASILibc
#else
import Foundation
#endif

/// A coding agent's own mark, bundled for an agent with no app installed: drawn in its real colours,
/// as vector paths, so it is sharp at every size. The marks belong to their
/// owners; drip is not affiliated with them. Each is unaltered: the path data and colours are copied
/// as published at `source`.
public struct AgentMark: Equatable, Sendable {
    /// The name `--icon mark:<name>` takes.
    public var name: String
    /// Whose mark it is, for the credit.
    public var owner: String
    /// Where the vector was taken from.
    public var source: String
    /// The SVG's viewBox: the coordinates the paths are in.
    public var width: Double
    public var height: Double
    /// The SVG's paths, painted in order, each with its fill.
    public var layers: [Layer]

    public struct Layer: Equatable, Sendable {
        /// SVG path data, verbatim.
        public var path: String
        public var fill: Paint
    }

    /// A path's fill: one colour, or an SVG linear gradient in the viewBox's coordinates
    /// (`gradientUnits="userSpaceOnUse"`), its end colours padding out past its ends.
    public enum Paint: Equatable, Sendable {
        case solid(SRGBColor)
        case linear(x1: Double, y1: Double, x2: Double, y2: Double, stops: [Stop])
    }

    /// A gradient stop: where it sits from 0 to 1, its colour and its opacity.
    public struct Stop: Equatable, Sendable {
        public var offset: Double
        public var color: SRGBColor
        public var opacity: Double
    }

    /// How much of the icon's side the mark's drawn shape spans, bare on the island's black.
    public static let markFraction = 0.8

    /// The prefix that names a bundled mark.
    public static let prefix = "mark:"

    /// Claude's spark, in Clay, from Anthropic's press kit.
    public static let claude = AgentMark(
        name: "claude", owner: "Anthropic",
        source: "https://www.anthropic.com/press-kit (Claude Spark - Clay.svg)",
        width: 94, height: 94,
        layers: [Layer(path: """
            M18.7657 62.4437L37.1822 52.1167L37.4857 51.2122L37.1822 50.7085H36.2715L33.1852 50.5208\
            L22.6615 50.2391L13.5545 49.8636L4.70044 49.3942L2.47428 48.9248L0.399902 46.1553L0.602281 44.794\
            L2.47428 43.5266L5.15579 43.7613L11.0754 44.1837L19.98 44.794L26.4055 45.1695L35.9679 46.1553\
            H37.4857L37.6881 45.545L37.1822 45.1695L36.7774 44.794L27.5692 38.5508L17.6021 31.9791\
            L12.3908 28.1769L9.60812 26.2524L8.19147 24.4686L7.58433 20.5256L10.1141 17.7091L13.5545 17.9438\
            L14.4146 18.1785L17.9056 20.8542L25.343 26.6279L35.0572 33.7629L36.4739 34.9364L37.0443 34.5514\
            L37.1316 34.2792L36.4739 33.1996L31.212 23.6706L25.596 13.9539L23.0663 9.91695L22.4086 7.52296\
            C22.1538 6.51831 22.0038 5.68714 22.0038 4.65957L24.8877 0.716544L26.5067 0.200195L30.4025 0.716544\
            L32.0215 2.12477L34.4501 7.66379L38.3458 16.3478L44.4172 28.1769L46.188 31.6975L47.1493 34.9364\
            L47.5035 35.9222H48.1106V35.3589L48.6166 28.6933L49.5273 20.5256L50.438 10.0108L50.7415 7.05356\
            L52.2088 3.48605L55.1433 1.56148L57.42 2.64112L59.292 5.31674L59.039 7.05356L57.926 14.2824\
            L55.7504 25.5952L54.3337 33.1996H55.1433L56.1046 32.2138L59.9497 27.1442L66.3752 19.0704\
            L69.2085 15.8784L72.5478 12.3579L74.6728 10.668H78.7203L81.6548 15.0804L80.3394 19.6337\
            L76.1906 24.8911L72.7502 29.3504L67.8172 35.9595L64.7562 41.2734L65.0307 41.7118L65.7681 41.6489\
            L76.8989 39.255L82.9197 38.1753L90.1041 36.9549L93.3422 38.457L93.6963 40.006L92.4315 43.151\
            L84.7411 45.0287L75.7353 46.8594L62.3244 50.0164L62.1759 50.1358L62.3512 50.3958L68.399 50.9432\
            L70.9794 51.084H77.3037L89.0922 51.9759L92.1785 53.9944L93.9999 56.4822L93.6963 58.4068\
            L88.9404 60.8008L82.5655 59.2987L67.6401 55.7312L62.5301 54.4638H61.8217V54.8862L66.0717 59.064\
            L73.9139 66.1051L83.6786 75.2116L84.1845 77.4648L82.9197 79.2485L81.6042 79.0608L73.0032 72.5829\
            L69.6639 69.6726L62.1759 63.3356H61.67V63.9928L63.3902 66.5276L72.5478 80.2812L73.0032 84.5059\
            L72.3454 85.8672L69.9675 86.7121L67.3871 86.2427L61.9735 78.6852L56.4587 70.2359L52.0064 62.6315\
            L51.4687 62.971L48.8189 91.2654L47.6047 92.7206L44.7714 93.8002L42.3934 92.0164L41.1286 89.1061\
            L42.3934 83.3324L43.9113 75.8219L45.1255 69.8604L46.2386 62.4437L46.9184 59.9661L46.8583 59.8003\
            L46.3153 59.8916L40.7238 67.5603L32.2239 79.0608L25.4948 86.2427L23.8758 86.8999L21.0931 85.4447\
            L21.3461 82.863L22.9145 80.5629L32.2239 68.7338L37.8399 61.3641L41.4594 57.1337L41.4242 56.5218\
            L41.2244 56.5048L16.489 72.6299L12.0873 73.1932L10.1647 71.4094L10.4176 68.4991L11.3283 67.5603\
            L18.7657 62.4437Z
            """, fill: .solid(SRGBColor(hex: 0xD97757)))])

    /// OpenAI's Blossom, in white, from OpenAI's brand page: Codex's mark, named for the agent.
    public static let codex = AgentMark(
        name: "codex", owner: "OpenAI",
        source: "https://cdn.openai.com/brand/OpenAI-Logos-2025.zip (OpenAI-white-monoblossom.svg)",
        width: 721, height: 721,
        layers: [Layer(path: """
            M304.246 295.411V249.828C304.246 245.989 305.687 243.109 309.044 241.191L400.692 188.412\
            C413.167 181.215 428.042 177.858 443.394 177.858C500.971 177.858 537.44 222.482 537.44 269.982\
            C537.44 273.34 537.44 277.179 536.959 281.018L441.954 225.358C436.197 222 430.437 222 424.68 225.358\
            L304.246 295.411ZM518.245 472.945V364.024C518.245 357.304 515.364 352.507 509.608 349.149\
            L389.174 279.096L428.519 256.543C431.877 254.626 434.757 254.626 438.115 256.543L529.762 309.323\
            C556.154 324.679 573.905 357.304 573.905 388.971C573.905 425.436 552.315 459.024 518.245 472.941\
            V472.945ZM275.937 376.982L236.592 353.952C233.235 352.034 231.794 349.154 231.794 345.315V239.756\
            C231.794 188.416 271.139 149.548 324.4 149.548C344.555 149.548 363.264 156.268 379.102 168.262\
            L284.578 222.964C278.822 226.321 275.942 231.119 275.942 237.838V376.986L275.937 376.982Z\
            M360.626 425.922L304.246 394.255V327.083L360.626 295.416L417.002 327.083V394.255L360.626 425.922Z\
            M396.852 571.789C376.698 571.789 357.989 565.07 342.151 553.075L436.674 498.374\
            C442.431 495.017 445.311 490.219 445.311 483.499V344.352L485.138 367.382\
            C488.495 369.299 489.936 372.179 489.936 376.018V481.577\
            C489.936 532.917 450.109 571.785 396.852 571.785V571.789ZM283.134 464.79L191.486 412.01\
            C165.094 396.654 147.343 364.029 147.343 332.362C147.343 295.416 169.415 262.309 203.48 248.393\
            V357.791C203.48 364.51 206.361 369.308 212.117 372.665L332.074 442.237L292.729 464.79\
            C289.372 466.707 286.491 466.707 283.134 464.79ZM277.859 543.48\
            C223.639 543.48 183.813 502.695 183.813 452.314C183.813 448.475 184.294 444.636 184.771 440.797\
            L279.295 495.498C285.051 498.856 290.812 498.856 296.568 495.498L417.002 425.927V471.509\
            C417.002 475.349 415.562 478.229 412.204 480.146L320.557 532.926\
            C308.081 540.122 293.206 543.48 277.854 543.48H277.859ZM396.852 600.576\
            C454.911 600.576 503.37 559.313 514.41 504.612C568.149 490.696 602.696 440.315 602.696 388.976\
            C602.696 355.387 588.303 322.762 562.392 299.25C564.791 289.173 566.231 279.096 566.231 269.024\
            C566.231 200.411 510.571 149.067 446.274 149.067C433.322 149.067 420.846 150.984 408.37 155.305\
            C386.775 134.192 357.026 120.758 324.4 120.758C266.342 120.758 217.883 162.02 206.843 216.721\
            C153.104 230.637 118.557 281.018 118.557 332.357C118.557 365.946 132.95 398.571 158.861 422.083\
            C156.462 432.16 155.022 442.237 155.022 452.309C155.022 520.922 210.682 572.266 274.978 572.266\
            C287.931 572.266 300.407 570.349 312.883 566.028C334.473 587.141 364.222 600.576 396.852 600.576Z
            """, fill: .solid(.white))])

    /// Gemini's spark, in its colours, from LobeHub's icons (MIT). Google publishes no vector of it
    /// outside its partner hub. The SVG fills one path four times: blue, then green, red and yellow
    /// gradients that fade out across it.
    public static let gemini = AgentMark(
        name: "gemini", owner: "Google",
        source: "https://lobehub.com/icons/gemini (@lobehub/icons-static-svg 1.96.0, gemini-color.svg)",
        width: 24, height: 24,
        layers: [
            Layer(path: geminiPath, fill: .solid(SRGBColor(hex: 0x3186FF))),
            Layer(path: geminiPath, fill: .fading(0x08B962, x1: 7, y1: 15.5, x2: 11, y2: 12, until: 1)),
            Layer(path: geminiPath, fill: .fading(0xF94543, x1: 8, y1: 5.5, x2: 11.5, y2: 11, until: 1)),
            Layer(path: geminiPath, fill: .fading(0xFABC12, x1: 3.5, y1: 13.5, x2: 17.5, y2: 12, until: 0.46)),
        ])

    private static let geminiPath = """
        M20.616 10.835\
        a14.147 14.147 0 01-4.45-3.001 14.111 14.111 0 01-3.678-6.452.503.503 0 00-.975 0 14.134 14.134 0 01-3.679 6.452 14.155 14.155 0 01-4.45 3.001\
        c-.65.28-1.318.505-2.002.678a.502.502 0 000 .975c.684.172 1.35.397 2.002.677\
        a14.147 14.147 0 014.45 3.001 14.112 14.112 0 013.679 6.453.502.502 0 00.975 0\
        c.172-.685.397-1.351.677-2.003\
        a14.145 14.145 0 013.001-4.45 14.113 14.113 0 016.453-3.678.503.503 0 000-.975 13.245 13.245 0 01-2.003-.678\
        z
        """

    /// Every bundled mark, in the order help text lists them.
    public static let all: [AgentMark] = [.claude, .codex, .gemini]

    public static func named(_ name: String) -> AgentMark? {
        all.first { $0.name == name }
    }

    /// Each layer's path as segments, in the viewBox's coordinates.
    public var outlines: [[PathSegment]] {
        layers.map { (try? PathSegment.parse($0.path)) ?? [] }
    }

    /// The box the drawn shape covers, in the viewBox's coordinates: the mark is fitted by it, so a
    /// file with room around its mark draws as large as one without.
    public var bounds: PathBounds {
        PathBounds(union: outlines.map(PathBounds.init))
    }

    /// Where the paths go in an icon `side` points square, its top-left corner at 0, 0, y down: each
    /// point scaled by `scale`, then moved by `x` and `y`, so the mark's longer side spans
    /// `markFraction` of the icon, centred on it.
    public func placement(side: Double) -> (scale: Double, x: Double, y: Double) {
        let box = bounds
        let scale = side * Self.markFraction / max(box.width, box.height, .leastNonzeroMagnitude)
        return (scale, side / 2 - (box.minX + box.width / 2) * scale, side / 2 - (box.minY + box.height / 2) * scale)
    }
}

extension AgentMark.Paint {
    /// A gradient from `hex`, opaque, to `hex` fully transparent at `until`, as the SVG writes it.
    static func fading(
        _ hex: UInt32, x1: Double, y1: Double, x2: Double, y2: Double, until: Double
    ) -> AgentMark.Paint {
        let color = SRGBColor(hex: hex)
        return .linear(x1: x1, y1: y1, x2: x2, y2: y2, stops: [
            AgentMark.Stop(offset: 0, color: color, opacity: 1),
            AgentMark.Stop(offset: until, color: color, opacity: 0),
        ])
    }
}

extension SRGBColor {
    init(hex: UInt32) {
        self.init(
            red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255)
    }
}

/// One piece of a path, absolute, with every curve as a cubic: what a Core Graphics path or an
/// HTML canvas draws.
public enum PathSegment: Equatable, Sendable {
    case move(Double, Double)
    case line(Double, Double)
    case cubic(Double, Double, Double, Double, Double, Double)
    case close

    /// The segments of SVG path data: every command, relative ones made absolute, quadratics and
    /// arcs turned into cubics. Throws on data that is not a path.
    public static func parse(_ data: String) throws -> [PathSegment] {
        var scanner = PathScanner(Array(data.utf8))
        var segments: [PathSegment] = []
        var current = (x: 0.0, y: 0.0), start = (x: 0.0, y: 0.0)
        // The last curve's second control point, for S and T, which mirror it.
        var lastCubic: (x: Double, y: Double)?, lastQuad: (x: Double, y: Double)?
        var command: UInt8?

        while true {
            scanner.skipSeparators()
            guard let next = scanner.peek else { break }
            if PathScanner.isCommand(next) {
                command = next
                scanner.index += 1
            } else if command == nil || command == UInt8(ascii: "z") || command == UInt8(ascii: "Z") {
                throw PathError(position: scanner.index)
            }
            guard let letter = command else { break }
            let relative = letter >= UInt8(ascii: "a")
            let dx = relative ? current.x : 0, dy = relative ? current.y : 0
            var cubic: (x: Double, y: Double)?, quad: (x: Double, y: Double)?

            switch letter | 0x20 {
            case UInt8(ascii: "m"):
                let x = try scanner.number() + dx, y = try scanner.number() + dy
                segments.append(.move(x, y))
                current = (x, y)
                start = current
                // Pairs after a moveto are linetos.
                command = relative ? UInt8(ascii: "l") : UInt8(ascii: "L")
            case UInt8(ascii: "l"):
                let x = try scanner.number() + dx, y = try scanner.number() + dy
                segments.append(.line(x, y))
                current = (x, y)
            case UInt8(ascii: "h"):
                current.x = try scanner.number() + dx
                segments.append(.line(current.x, current.y))
            case UInt8(ascii: "v"):
                current.y = try scanner.number() + dy
                segments.append(.line(current.x, current.y))
            case UInt8(ascii: "c"):
                let x1 = try scanner.number() + dx, y1 = try scanner.number() + dy
                let x2 = try scanner.number() + dx, y2 = try scanner.number() + dy
                let x = try scanner.number() + dx, y = try scanner.number() + dy
                segments.append(.cubic(x1, y1, x2, y2, x, y))
                cubic = (x2, y2)
                current = (x, y)
            case UInt8(ascii: "s"):
                let x1 = lastCubic.map { 2 * current.x - $0.x } ?? current.x
                let y1 = lastCubic.map { 2 * current.y - $0.y } ?? current.y
                let x2 = try scanner.number() + dx, y2 = try scanner.number() + dy
                let x = try scanner.number() + dx, y = try scanner.number() + dy
                segments.append(.cubic(x1, y1, x2, y2, x, y))
                cubic = (x2, y2)
                current = (x, y)
            case UInt8(ascii: "q"):
                let qx = try scanner.number() + dx, qy = try scanner.number() + dy
                let x = try scanner.number() + dx, y = try scanner.number() + dy
                segments.append(Self.quadratic(from: current, control: (qx, qy), to: (x, y)))
                quad = (qx, qy)
                current = (x, y)
            case UInt8(ascii: "t"):
                let qx = lastQuad.map { 2 * current.x - $0.x } ?? current.x
                let qy = lastQuad.map { 2 * current.y - $0.y } ?? current.y
                let x = try scanner.number() + dx, y = try scanner.number() + dy
                segments.append(Self.quadratic(from: current, control: (qx, qy), to: (x, y)))
                quad = (qx, qy)
                current = (x, y)
            case UInt8(ascii: "a"):
                let rx = try scanner.number(), ry = try scanner.number(), rotation = try scanner.number()
                let large = try scanner.flag(), sweep = try scanner.flag()
                let x = try scanner.number() + dx, y = try scanner.number() + dy
                segments += Self.arc(
                    from: current, to: (x, y), radii: (rx, ry), rotation: rotation, large: large, sweep: sweep)
                current = (x, y)
            case UInt8(ascii: "z"):
                segments.append(.close)
                current = start
            default:
                throw PathError(position: scanner.index - 1)
            }
            lastCubic = cubic
            lastQuad = quad
        }
        return segments
    }

    private static func quadratic(
        from p0: (x: Double, y: Double), control q: (x: Double, y: Double), to p: (x: Double, y: Double)
    ) -> PathSegment {
        .cubic(
            p0.x + 2 / 3 * (q.x - p0.x), p0.y + 2 / 3 * (q.y - p0.y),
            p.x + 2 / 3 * (q.x - p.x), p.y + 2 / 3 * (q.y - p.y), p.x, p.y)
    }

    /// An SVG elliptical arc as cubics of at most a quarter turn each, after the SVG spec's
    /// endpoint-to-center conversion (F.6.5), radii scaled up when they cannot reach.
    private static func arc(
        from p0: (x: Double, y: Double), to p: (x: Double, y: Double), radii: (Double, Double),
        rotation: Double, large: Bool, sweep: Bool
    ) -> [PathSegment] {
        var rx = abs(radii.0), ry = abs(radii.1)
        guard rx > 0, ry > 0, p0 != p else { return p0 == p ? [] : [.line(p.x, p.y)] }
        let phi = rotation * .pi / 180, cosPhi = cos(phi), sinPhi = sin(phi)
        let mx = (p0.x - p.x) / 2, my = (p0.y - p.y) / 2
        let x1 = cosPhi * mx + sinPhi * my, y1 = -sinPhi * mx + cosPhi * my
        let lambda = (x1 * x1) / (rx * rx) + (y1 * y1) / (ry * ry)
        if lambda > 1 {
            rx *= lambda.squareRoot()
            ry *= lambda.squareRoot()
        }
        let numerator = rx * rx * ry * ry - rx * rx * y1 * y1 - ry * ry * x1 * x1
        let denominator = rx * rx * y1 * y1 + ry * ry * x1 * x1
        var factor = (max(numerator, 0) / denominator).squareRoot()
        if large == sweep { factor = -factor }
        let cx1 = factor * rx * y1 / ry, cy1 = -factor * ry * x1 / rx
        let cx = cosPhi * cx1 - sinPhi * cy1 + (p0.x + p.x) / 2
        let cy = sinPhi * cx1 + cosPhi * cy1 + (p0.y + p.y) / 2
        func angle(_ ux: Double, _ uy: Double, _ vx: Double, _ vy: Double) -> Double {
            atan2(ux * vy - uy * vx, ux * vx + uy * vy)
        }
        let theta = angle(1, 0, (x1 - cx1) / rx, (y1 - cy1) / ry)
        var delta = angle((x1 - cx1) / rx, (y1 - cy1) / ry, (-x1 - cx1) / rx, (-y1 - cy1) / ry)
        if !sweep, delta > 0 { delta -= 2 * .pi }
        if sweep, delta < 0 { delta += 2 * .pi }

        let pieces = max(Int((abs(delta) / (.pi / 2)).rounded(.up)), 1)
        let step = delta / Double(pieces)
        let k = 4 / 3 * tan(step / 4)
        func point(_ t: Double) -> (x: Double, y: Double) {
            (cx + rx * cos(t) * cosPhi - ry * sin(t) * sinPhi, cy + rx * cos(t) * sinPhi + ry * sin(t) * cosPhi)
        }
        func tangent(_ t: Double) -> (x: Double, y: Double) {
            (-rx * sin(t) * cosPhi - ry * cos(t) * sinPhi, -rx * sin(t) * sinPhi + ry * cos(t) * cosPhi)
        }
        return (0..<pieces).map { index in
            let a = theta + Double(index) * step, b = a + step
            let start = point(a), end = index == pieces - 1 ? p : point(b)
            let ta = tangent(a), tb = tangent(b)
            return .cubic(start.x + k * ta.x, start.y + k * ta.y, end.x - k * tb.x, end.y - k * tb.y, end.x, end.y)
        }
    }
}

/// Path data that is not SVG path syntax.
public struct PathError: Error, Equatable {
    /// The byte offset where reading stopped.
    public var position: Int
}

/// The box a path's points and control points span, which holds the drawn shape.
public struct PathBounds: Equatable, Sendable {
    public var minX = Double.infinity, minY = Double.infinity
    public var maxX = -Double.infinity, maxY = -Double.infinity

    public var width: Double { max(maxX - minX, 0) }
    public var height: Double { max(maxY - minY, 0) }

    public init(_ segments: [PathSegment]) {
        for segment in segments {
            switch segment {
            case let .move(x, y), let .line(x, y):
                include(x, y)
            case let .cubic(x1, y1, x2, y2, x, y):
                include(x1, y1)
                include(x2, y2)
                include(x, y)
            case .close:
                break
            }
        }
    }

    public init(union boxes: [PathBounds]) {
        for box in boxes where box.minX <= box.maxX {
            include(box.minX, box.minY)
            include(box.maxX, box.maxY)
        }
    }

    private mutating func include(_ x: Double, _ y: Double) {
        minX = min(minX, x)
        minY = min(minY, y)
        maxX = max(maxX, x)
        maxY = max(maxY, y)
    }
}

/// Reads the numbers and flags of SVG path data.
private struct PathScanner {
    let bytes: [UInt8]
    var index = 0

    init(_ bytes: [UInt8]) {
        self.bytes = bytes
    }

    var peek: UInt8? { index < bytes.count ? bytes[index] : nil }

    static func isCommand(_ byte: UInt8) -> Bool {
        "MmLlHhVvCcSsQqTtAaZz".utf8.contains(byte)
    }

    mutating func skipSeparators() {
        while let byte = peek, byte == UInt8(ascii: " ") || byte == UInt8(ascii: ",") || byte == 0x09
            || byte == 0x0A || byte == 0x0D || byte == 0x0C
        {
            index += 1
        }
    }

    /// An arc's flag: a lone 0 or 1, which may run straight into the next number.
    mutating func flag() throws -> Bool {
        skipSeparators()
        guard let byte = peek, byte == UInt8(ascii: "0") || byte == UInt8(ascii: "1") else {
            throw PathError(position: index)
        }
        index += 1
        return byte == UInt8(ascii: "1")
    }

    /// A number: a sign, digits with at most one point, and an exponent. A second point or a sign
    /// starts the next number, as in `1.5.5` or `1-2`.
    mutating func number() throws -> Double {
        skipSeparators()
        let begin = index
        if let byte = peek, byte == UInt8(ascii: "-") || byte == UInt8(ascii: "+") { index += 1 }
        var digits = false, point = false
        while let byte = peek {
            if byte >= UInt8(ascii: "0"), byte <= UInt8(ascii: "9") {
                digits = true
            } else if byte == UInt8(ascii: "."), !point {
                point = true
            } else {
                break
            }
            index += 1
        }
        if digits, let byte = peek, byte == UInt8(ascii: "e") || byte == UInt8(ascii: "E") {
            let mark = index
            index += 1
            if let sign = peek, sign == UInt8(ascii: "-") || sign == UInt8(ascii: "+") { index += 1 }
            var exponent = false
            while let byte = peek, byte >= UInt8(ascii: "0"), byte <= UInt8(ascii: "9") {
                exponent = true
                index += 1
            }
            if !exponent { index = mark }
        }
        guard digits, let value = Double(String(decoding: bytes[begin..<index], as: UTF8.self)) else {
            throw PathError(position: begin)
        }
        return value
    }
}
