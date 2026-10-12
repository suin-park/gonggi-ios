import Foundation

// Walkable route over the floor plan (X, Z of the gravity-aligned world). The walkable area is what the person actually
// walked while recording (the trail, widened by a corridor radius) minus the footprint of every recorded shelf, so a
// route can never lead across a shelf or through space nobody has walked.

struct FloorPoint: Equatable, Sendable {
    var x: Float
    var z: Float

    init(x: Float, z: Float) {
        self.x = x
        self.z = z
    }

    init(_ p: Vec3) {
        x = p.x
        z = p.z
    }

    func distance(to o: FloorPoint) -> Float {
        let dx = x - o.x, dz = z - o.z
        return (dx * dx + dz * dz).squareRoot()
    }
}

/// An oriented rectangle on the floor: the footprint of a shelf (its front face, `depth` metres behind it).
struct ShelfObstacle: Equatable, Sendable {
    var corners: [FloorPoint]   // 4 corners, in order

    init(corners: [FloorPoint]) {
        self.corners = corners
    }

    /// `uRange`: extent of the shelf along its u axis; `depth`: how far behind the front face it reaches.
    init(plane: ShelfPlane, uRange: ClosedRange<Float>, depth: Float, margin: Float = 0.1) {
        let a = plane.worldPoint(u: uRange.lowerBound - margin, v: 0, offset: margin)
        let b = plane.worldPoint(u: uRange.upperBound + margin, v: 0, offset: margin)
        let c = plane.worldPoint(u: uRange.upperBound + margin, v: 0, offset: -depth - margin)
        let d = plane.worldPoint(u: uRange.lowerBound - margin, v: 0, offset: -depth - margin)
        corners = [FloorPoint(a), FloorPoint(b), FloorPoint(c), FloorPoint(d)]
    }

    func contains(_ p: FloorPoint) -> Bool {
        var sign = 0
        for i in 0..<4 {
            let a = corners[i], b = corners[(i + 1) % 4]
            let cross = (b.x - a.x) * (p.z - a.z) - (b.z - a.z) * (p.x - a.x)
            if abs(cross) < 1e-7 { continue }
            let s = cross > 0 ? 1 : -1
            if sign == 0 { sign = s } else if sign != s { return false }
        }
        return true
    }
}

struct StoreWalkableMap {
    let cell: Float
    let minX: Float
    let minZ: Float
    let cols: Int
    let rows: Int
    private(set) var walkable: [Bool]
    let obstacles: [ShelfObstacle]

    /// nil when there is no trail to build a map from.
    static func build(trail: [FloorPoint], obstacles: [ShelfObstacle], corridorRadius: Float = 0.45,
                      cell: Float = 0.2) -> StoreWalkableMap? {
        guard trail.count >= 2 else { return nil }
        let pad = corridorRadius + 1.0
        let minX = (trail.map(\.x).min() ?? 0) - pad, maxX = (trail.map(\.x).max() ?? 0) + pad
        let minZ = (trail.map(\.z).min() ?? 0) - pad, maxZ = (trail.map(\.z).max() ?? 0) + pad
        let cols = Int(ceil((maxX - minX) / cell)), rows = Int(ceil((maxZ - minZ) / cell))
        guard cols > 0, rows > 0, cols * rows <= 250_000 else { return nil }
        var map = StoreWalkableMap(cell: cell, minX: minX, minZ: minZ, cols: cols, rows: rows,
                                   walkable: [Bool](repeating: false, count: cols * rows), obstacles: obstacles)
        let r = Int(ceil(corridorRadius / cell))
        // Densify the trail so a stretch between two samples leaves no gap. A jump larger than `maxLink` (tracking lost,
        // a restored session, two separate recordings) is a discontinuity: nobody walked it, so it is not connected.
        let maxLink: Float = 1.0
        var dense: [FloorPoint] = []
        for i in 0..<trail.count {
            dense.append(trail[i])
            if i + 1 < trail.count {
                let a = trail[i], b = trail[i + 1]
                let n = Int(a.distance(to: b) / (cell * 0.5))
                if n > 1, a.distance(to: b) <= maxLink {
                    for k in 1..<n {
                        let t = Float(k) / Float(n)
                        dense.append(FloorPoint(x: a.x + (b.x - a.x) * t, z: a.z + (b.z - a.z) * t))
                    }
                }
            }
        }
        for p in dense {
            let ci = Int((p.x - minX) / cell), cj = Int((p.z - minZ) / cell)
            for dj in -r...r {
                for di in -r...r {
                    let i = ci + di, j = cj + dj
                    guard i >= 0, i < cols, j >= 0, j < rows else { continue }
                    let c = map.centre(i, j)
                    if c.distance(to: p) <= corridorRadius { map.walkable[j * cols + i] = true }
                }
            }
        }
        for j in 0..<rows {
            for i in 0..<cols where map.walkable[j * cols + i] {
                let c = map.centre(i, j)
                if obstacles.contains(where: { $0.contains(c) }) { map.walkable[j * cols + i] = false }
            }
        }
        return map
    }

    func centre(_ i: Int, _ j: Int) -> FloorPoint {
        FloorPoint(x: minX + (Float(i) + 0.5) * cell, z: minZ + (Float(j) + 0.5) * cell)
    }

    func index(of p: FloorPoint) -> (i: Int, j: Int)? {
        let i = Int(floor((p.x - minX) / cell)), j = Int(floor((p.z - minZ) / cell))
        guard i >= 0, i < cols, j >= 0, j < rows else { return nil }
        return (i, j)
    }

    func isWalkable(_ i: Int, _ j: Int) -> Bool {
        i >= 0 && i < cols && j >= 0 && j < rows && walkable[j * cols + i]
    }

    /// Nearest walkable cell to `p` within `maxDistance`.
    func snap(_ p: FloorPoint, maxDistance: Float = 1.5) -> (i: Int, j: Int)? {
        let r = Int(ceil(maxDistance / cell))
        let base = index(of: p) ?? (Int(floor((p.x - minX) / cell)), Int(floor((p.z - minZ) / cell)))
        var best: (i: Int, j: Int, d: Float)?
        for dj in -r...r {
            for di in -r...r {
                let i = base.0 + di, j = base.1 + dj
                guard isWalkable(i, j) else { continue }
                let d = centre(i, j).distance(to: p)
                if d <= maxDistance, best == nil || d < best!.d { best = (i, j, d) }
            }
        }
        return best.map { ($0.i, $0.j) }
    }

    private func lineOfSight(_ a: (i: Int, j: Int), _ b: (i: Int, j: Int)) -> Bool {
        let steps = max(abs(b.i - a.i), abs(b.j - a.j)) * 2
        if steps == 0 { return true }
        for s in 0...steps {
            let t = Float(s) / Float(steps)
            let i = Int(round(Float(a.i) + Float(b.i - a.i) * t)), j = Int(round(Float(a.j) + Float(b.j - a.j) * t))
            if !isWalkable(i, j) { return false }
        }
        return true
    }

    /// A route from `from` to `to` over walkable cells, as floor waypoints (start and end snapped to walkable cells).
    /// nil when either end is not near walkable space or no connection exists. The route never crosses an obstacle.
    func route(from: FloorPoint, to: FloorPoint) -> [FloorPoint]? {
        guard let s = snap(from), let g = snap(to) else { return nil }
        let n = cols * rows
        var gScore = [Float](repeating: .infinity, count: n)
        var came = [Int](repeating: -1, count: n)
        var closed = [Bool](repeating: false, count: n)
        func id(_ i: Int, _ j: Int) -> Int { j * cols + i }
        func h(_ i: Int, _ j: Int) -> Float {
            let dx = Float(abs(i - g.i)), dz = Float(abs(j - g.j))
            return (dx * dx + dz * dz).squareRoot()
        }
        // Binary heap of (f, id).
        var heap: [(f: Float, id: Int)] = []
        func push(_ f: Float, _ i: Int) {
            heap.append((f, i))
            var c = heap.count - 1
            while c > 0 {
                let p = (c - 1) / 2
                if heap[p].f <= heap[c].f { break }
                heap.swapAt(p, c)
                c = p
            }
        }
        func pop() -> (f: Float, id: Int)? {
            guard !heap.isEmpty else { return nil }
            let top = heap[0]
            let last = heap.removeLast()
            if !heap.isEmpty {
                heap[0] = last
                var c = 0
                while true {
                    let l = 2 * c + 1, r = l + 1
                    var m = c
                    if l < heap.count, heap[l].f < heap[m].f { m = l }
                    if r < heap.count, heap[r].f < heap[m].f { m = r }
                    if m == c { break }
                    heap.swapAt(m, c)
                    c = m
                }
            }
            return top
        }
        let start = id(s.i, s.j), goal = id(g.i, g.j)
        gScore[start] = 0
        push(h(s.i, s.j), start)
        let steps: [(Int, Int, Float)] = [(1, 0, 1), (-1, 0, 1), (0, 1, 1), (0, -1, 1),
                                          (1, 1, 1.4142), (1, -1, 1.4142), (-1, 1, 1.4142), (-1, -1, 1.4142)]
        var found = false
        while let (_, cur) = pop() {
            if closed[cur] { continue }
            closed[cur] = true
            if cur == goal {
                found = true
                break
            }
            let ci = cur % cols, cj = cur / cols
            for (di, dj, cost) in steps {
                let ni = ci + di, nj = cj + dj
                guard isWalkable(ni, nj) else { continue }
                // No corner cutting through a blocked cell.
                if di != 0, dj != 0, !isWalkable(ci + di, cj) || !isWalkable(ci, cj + dj) { continue }
                let nid = id(ni, nj)
                if closed[nid] { continue }
                let tentative = gScore[cur] + cost
                if tentative < gScore[nid] {
                    gScore[nid] = tentative
                    came[nid] = cur
                    push(tentative + h(ni, nj), nid)
                }
            }
        }
        guard found else { return nil }
        var cells: [(i: Int, j: Int)] = []
        var cur = goal
        while cur != -1 {
            cells.append((cur % cols, cur / cols))
            cur = came[cur]
        }
        cells.reverse()
        // String pulling: keep only the corners that line of sight needs.
        var out: [(i: Int, j: Int)] = [cells[0]]
        var anchor = 0
        var k = 1
        while k < cells.count {
            if !lineOfSight(cells[anchor], cells[k]) {
                out.append(cells[k - 1])
                anchor = k - 1
            }
            k += 1
        }
        if let last = cells.last, out.last! != last { out.append(last) }
        return out.map { centre($0.i, $0.j) }
    }

    /// True when any segment of `path` enters an obstacle (used to refuse a bad route, and by tests).
    func crossesObstacle(_ path: [FloorPoint]) -> Bool {
        guard path.count >= 2 else { return false }
        for i in 0..<(path.count - 1) {
            let a = path[i], b = path[i + 1]
            let steps = max(1, Int(a.distance(to: b) / (cell * 0.25)))
            for s in 0...steps {
                let t = Float(s) / Float(steps)
                let p = FloorPoint(x: a.x + (b.x - a.x) * t, z: a.z + (b.z - a.z) * t)
                if obstacles.contains(where: { $0.contains(p) }) { return true }
            }
        }
        return false
    }
}

/// Records where the person walked: a sample every `minStep` metres (floor position only).
struct StoreTrailRecorder {
    let minStep: Float
    private(set) var samples: [ShelfWalkSample] = []

    init(minStep: Float = 0.2) {
        self.minStep = minStep
    }

    mutating func add(position p: Vec3, time: Double) {
        if let last = samples.last {
            let dx = p.x - last.x, dz = p.z - last.z
            if (dx * dx + dz * dz).squareRoot() < minStep { return }
        }
        samples.append(ShelfWalkSample(x: p.x, y: p.y, z: p.z, time: time))
    }

    /// Estimated floor height: the lowest camera height sampled minus a typical hand-held height is NOT used (it would be
    /// a guess); this returns nil unless detected floor planes were supplied.
    static func floorY(detectedHorizontalPlaneHeights: [Float]) -> Float? {
        detectedHorizontalPlaneHeights.min()
    }
}

enum StoreRouteProgress {
    /// Drops the waypoints already reached (within `reach`) and returns the remaining route.
    static func remaining(_ path: [FloorPoint], position: FloorPoint, reach: Float = 0.5) -> [FloorPoint] {
        guard !path.isEmpty else { return [] }
        var nearest = 0
        var best = Float.infinity
        for (i, p) in path.enumerated() {
            let d = p.distance(to: position)
            if d < best {
                best = d
                nearest = i
            }
        }
        var start = nearest
        if best <= reach, start < path.count - 1 { start += 1 }
        return Array(path[start...])
    }

    static func length(_ path: [FloorPoint]) -> Float {
        guard path.count >= 2 else { return 0 }
        return (0..<(path.count - 1)).reduce(0) { $0 + path[$1].distance(to: path[$1 + 1]) }
    }
}
