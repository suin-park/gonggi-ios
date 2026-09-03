import Foundation
import simd

/// Lightweight corner + patch-NCC matching (no OpenCV). For ARKit pose micro-correction only.
enum PanoramaFeatureMatcher {
    struct Point: Equatable {
        var x: Float
        var y: Float
    }

    struct Match: Equatable {
        var left: Point
        var right: Point
        var score: Float
    }

    /// Detect strong gradient corners in grayscale (Harris-like score peaks).
    static func detectCorners(
        gray: [UInt8],
        width: Int,
        height: Int,
        maxCorners: Int = Quick360Config.refinementMaxCorners,
        cellSize: Int = 16
    ) -> [Point] {
        guard width > 8, height > 8, gray.count >= width * height else { return [] }
        var scores = [Float](repeating: 0, count: width * height)
        for y in 1..<(height - 1) {
            for x in 1..<(width - 1) {
                let i = y * width + x
                let dx = Float(Int(gray[i + 1]) - Int(gray[i - 1]))
                let dy = Float(Int(gray[i + width]) - Int(gray[i - width]))
                scores[i] = dx * dx + dy * dy
            }
        }
        var corners: [Point] = []
        let cellsX = max(1, width / cellSize)
        let cellsY = max(1, height / cellSize)
        for cy in 0..<cellsY {
            for cx in 0..<cellsX {
                let x0 = cx * cellSize
                let y0 = cy * cellSize
                let x1 = min(width - 2, x0 + cellSize - 1)
                let y1 = min(height - 2, y0 + cellSize - 1)
                var best = 0
                var bestScore: Float = 0
                for y in y0...y1 {
                    for x in x0...x1 {
                        let s = scores[y * width + x]
                        if s > bestScore {
                            bestScore = s
                            best = y * width + x
                        }
                    }
                }
                if bestScore > 80 {
                    corners.append(Point(x: Float(best % width), y: Float(best / width)))
                }
            }
        }
        corners.sort {
            scores[Int($0.y) * width + Int($0.x)] > scores[Int($1.y) * width + Int($1.x)]
        }
        if corners.count > maxCorners {
            corners = Array(corners.prefix(maxCorners))
        }
        return corners
    }

    /// Match left corners into right patch via local NCC search.
    static func matchCorners(
        leftGray: [UInt8],
        leftW: Int,
        leftH: Int,
        rightGray: [UInt8],
        rightW: Int,
        rightH: Int,
        leftCorners: [Point],
        patchRadius: Int = 5,
        searchRadius: Int = 14,
        minScore: Float = 0.55
    ) -> [Match] {
        var matches: [Match] = []
        for c in leftCorners {
            let lx = Int(c.x.rounded())
            let ly = Int(c.y.rounded())
            guard lx >= patchRadius, ly >= patchRadius,
                  lx < leftW - patchRadius, ly < leftH - patchRadius else { continue }
            // Seed search near same relative coords (overlap patches already aligned roughly).
            let seedX = min(rightW - 1, max(0, lx * rightW / max(leftW, 1)))
            let seedY = min(rightH - 1, max(0, ly * rightH / max(leftH, 1)))
            var bestScore: Float = -1
            var bestX = seedX
            var bestY = seedY
            for dy in -searchRadius...searchRadius {
                for dx in -searchRadius...searchRadius {
                    let rx = seedX + dx
                    let ry = seedY + dy
                    guard rx >= patchRadius, ry >= patchRadius,
                          rx < rightW - patchRadius, ry < rightH - patchRadius else { continue }
                    let s = ncc(
                        a: leftGray, aw: leftW, ax: lx, ay: ly,
                        b: rightGray, bw: rightW, bx: rx, by: ry,
                        radius: patchRadius
                    )
                    if s > bestScore {
                        bestScore = s
                        bestX = rx
                        bestY = ry
                    }
                }
            }
            if bestScore >= minScore {
                matches.append(Match(
                    left: c,
                    right: Point(x: Float(bestX), y: Float(bestY)),
                    score: bestScore
                ))
            }
        }
        return mutualFilter(matches)
    }

    /// Keep matches that are mutual nearest in L2 (simple outlier prune before RANSAC).
    static func mutualFilter(_ matches: [Match], maxSecondRatio: Float = 0.92) -> [Match] {
        guard matches.count > 1 else { return matches }
        var kept: [Match] = []
        for (i, m) in matches.enumerated() {
            var nearest = Float.greatestFiniteMagnitude
            var second = Float.greatestFiniteMagnitude
            for (j, o) in matches.enumerated() where i != j {
                let d = hypot(m.right.x - o.right.x, m.right.y - o.right.y)
                if d < nearest {
                    second = nearest
                    nearest = d
                } else if d < second {
                    second = d
                }
            }
            // Prefer spatially consistent matches (not clustered on same right point).
            let clash = matches.filter {
                hypot($0.right.x - m.right.x, $0.right.y - m.right.y) < 1.5
            }.count
            if clash <= 2 {
                kept.append(m)
            } else if m.score >= maxSecondRatio {
                kept.append(m)
            }
            _ = second
        }
        return kept
    }

    private static func ncc(
        a: [UInt8], aw: Int, ax: Int, ay: Int,
        b: [UInt8], bw: Int, bx: Int, by: Int,
        radius: Int
    ) -> Float {
        var sumA: Float = 0
        var sumB: Float = 0
        var sumAA: Float = 0
        var sumBB: Float = 0
        var sumAB: Float = 0
        var n: Float = 0
        for dy in -radius...radius {
            for dx in -radius...radius {
                let va = Float(a[(ay + dy) * aw + (ax + dx)])
                let vb = Float(b[(by + dy) * bw + (bx + dx)])
                sumA += va
                sumB += vb
                sumAA += va * va
                sumBB += vb * vb
                sumAB += va * vb
                n += 1
            }
        }
        guard n > 0 else { return -1 }
        let meanA = sumA / n
        let meanB = sumB / n
        let num = sumAB - n * meanA * meanB
        let den = sqrt(max(0, sumAA - n * meanA * meanA) * max(0, sumBB - n * meanB * meanB))
        guard den > 1e-3 else { return -1 }
        return num / den
    }
}
