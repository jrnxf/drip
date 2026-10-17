import Foundation

// The droplet is drawn as liquid: the notch and the drop are melted together with a smooth union of
// their signed distance fields, and the outline is traced where the field crosses zero. As the drop
// falls, the bridge between them thins into a neck that pinches off on its own; as it rises, the two
// reach for each other and merge. No neck is drawn by hand.

/// The notch and the drop as one field, negative inside.
public struct DropletField: Sendable {
    public let metrics: IslandMetrics
    public let shape: IslandShape

    public init(metrics: IslandMetrics, shape: IslandShape) {
        self.metrics = metrics
        self.shape = shape
    }

    /// Whether the drop is close enough to the notch for the two to melt together. Otherwise the
    /// drop is a plain capsule, hidden behind the notch or floating free of it.
    public var touchesNotch: Bool {
        let top = shape.pillTop, bottom = shape.pillTop + shape.pillHeight
        return shape.blend > 0.01 && top < metrics.notchHeight + shape.blend
            && bottom > metrics.notchHeight - shape.blend
    }

    public func value(x: Double, y: Double) -> Double {
        let notch = Self.roundedBox(
            x: x, y: y, centerX: 0, centerY: 0, halfWidth: metrics.notchWidth / 2,
            halfHeight: metrics.notchHeight, radius: metrics.notchRadius)
        let halfWidth = shape.pillWidth / 2, halfHeight = shape.pillHeight / 2
        let drop = Self.roundedBox(
            x: x, y: y, centerX: 0, centerY: shape.pillTop + halfHeight, halfWidth: halfWidth,
            halfHeight: halfHeight, radius: min(halfWidth, halfHeight))
        return Self.smoothMin(notch, drop, blend: shape.blend)
    }

    /// The cubic smooth minimum: a plain union far apart, a fillet of about `blend` close up whose
    /// curvature runs on into the shapes' own, so the join never kinks.
    static func smoothMin(_ a: Double, _ b: Double, blend: Double) -> Double {
        guard blend > 0 else { return min(a, b) }
        let h = max(blend - abs(a - b), 0) / blend
        return min(a, b) - h * h * h * blend / 6
    }

    static func roundedBox(
        x: Double, y: Double, centerX: Double, centerY: Double, halfWidth: Double, halfHeight: Double,
        radius: Double
    ) -> Double {
        let r = min(radius, halfWidth, halfHeight)
        let qx = abs(x - centerX) - halfWidth + r
        let qy = abs(y - centerY) - halfHeight + r
        let outside = (max(qx, 0) * max(qx, 0) + max(qy, 0) * max(qy, 0)).squareRoot()
        return outside + min(max(qx, qy), 0) - r
    }

    /// The outline of everything below `top` (a line inside the notch) and within a blend of the drop,
    /// as closed loops wound the same way as the notch's own path. `cell` is the grid's spacing.
    public func outline(above top: Double, cell: Double) -> [[IslandPoint]] {
        let halfWidth = shape.pillWidth / 2 + shape.blend + 2 * cell
        let bottom = max(shape.pillTop + shape.pillHeight, metrics.notchHeight) + shape.blend + 2 * cell
        guard bottom > top else { return [] }
        let columns = Int((2 * halfWidth / cell).rounded(.up)) + 1
        let rows = Int(((bottom - top) / cell).rounded(.up)) + 1
        let x0 = -Double(columns - 1) * cell / 2
        // The grid's border is held outside, so every loop closes; inside the notch, where the
        // border cuts through, the notch's own shape covers the seam.
        var values = [Double](repeating: 1, count: columns * rows)
        for row in 1..<(rows - 1) {
            let y = top + Double(row) * cell
            for column in 1..<(columns - 1) {
                values[row * columns + column] = value(x: x0 + Double(column) * cell, y: y)
            }
        }
        return MarchingSquares.loops(values: values, columns: columns, rows: rows).map { loop in
            let points = loop.map { IslandPoint(x0 + $0.x * cell, top + $0.y * cell) }
            return MarchingSquares.signedArea(points) > 0 ? points.reversed() : points
        }
    }
}

/// Traces the zero crossings of a sampled field into closed loops.
enum MarchingSquares {
    /// One crossing on a grid edge: `column, row` is its first corner, `vertical` its direction.
    private struct Edge: Hashable {
        var column: Int
        var row: Int
        var vertical: Bool
    }

    /// Loops in grid units, from `values` laid out row by row. The border must be outside (positive).
    static func loops(values: [Double], columns: Int, rows: Int) -> [[IslandPoint]] {
        func value(_ column: Int, _ row: Int) -> Double { values[row * columns + column] }
        func point(_ edge: Edge) -> IslandPoint {
            let a = value(edge.column, edge.row)
            let b = edge.vertical ? value(edge.column, edge.row + 1) : value(edge.column + 1, edge.row)
            let t = a / (a - b)
            return edge.vertical
                ? IslandPoint(Double(edge.column), Double(edge.row) + t)
                : IslandPoint(Double(edge.column) + t, Double(edge.row))
        }

        // Each crossing joins two others, one in each cell it borders.
        var links: [Edge: [Edge]] = [:]
        func link(_ a: Edge, _ b: Edge) {
            links[a, default: []].append(b)
            links[b, default: []].append(a)
        }
        for row in 0..<(rows - 1) {
            for column in 0..<(columns - 1) {
                let corners = [value(column, row), value(column + 1, row), value(column + 1, row + 1),
                               value(column, row + 1)]
                var index = 0
                for (bit, corner) in corners.enumerated() where corner < 0 { index |= 1 << bit }
                if index == 0 || index == 15 { continue }
                let top = Edge(column: column, row: row, vertical: false)
                let right = Edge(column: column + 1, row: row, vertical: true)
                let bottom = Edge(column: column, row: row + 1, vertical: false)
                let left = Edge(column: column, row: row, vertical: true)
                switch index {
                case 1, 14: link(left, top)
                case 2, 13: link(top, right)
                case 3, 12: link(left, right)
                case 4, 11: link(right, bottom)
                case 6, 9: link(top, bottom)
                case 7, 8: link(left, bottom)
                case 5, 10:
                    // A saddle: the cell's center decides whether the two insides connect.
                    let centerInside = corners.reduce(0, +) / 4 < 0
                    if (index == 5) == centerInside {
                        link(left, bottom)
                        link(top, right)
                    } else {
                        link(left, top)
                        link(right, bottom)
                    }
                default: break
                }
            }
        }

        var loops: [[IslandPoint]] = []
        var visited = Set<Edge>()
        for start in links.keys.sorted(by: { ($0.row, $0.column, $0.vertical ? 1 : 0) < ($1.row, $1.column, $1.vertical ? 1 : 0) })
        where !visited.contains(start) {
            var loop: [IslandPoint] = []
            var previous: Edge?
            var current = start
            while !visited.contains(current) {
                visited.insert(current)
                loop.append(point(current))
                guard let next = links[current]?.first(where: { $0 != previous && !visited.contains($0) }) else {
                    break
                }
                previous = current
                current = next
            }
            if loop.count > 2 { loops.append(loop) }
        }
        return loops
    }

    /// Twice the signed area, positive for loops that turn clockwise in y-down coordinates.
    static func signedArea(_ points: [IslandPoint]) -> Double {
        var sum = 0.0
        for index in points.indices {
            let a = points[index], b = points[(index + 1) % points.count]
            sum += a.x * b.y - b.x * a.y
        }
        return sum
    }
}
