import Foundation

/// Is the whole product inside the photo, judged from the product's own pixels (not from the user's box)?
///
/// Input is a per-pixel instance label map (0 = background, 1... = foreground instances, e.g. from Vision's
/// foreground instance mask), an optional luma plane of the same size, the projected box (hull) and the projected
/// bottom face of the box. This file is deliberately free of Vision / ARKit / app types: the same source is compiled
/// into the offline validation tool and into the app, so the validated rule is the shipped rule.
///
/// Nothing here shrinks or changes the box: the box and `object.json` stay as the user set them. The result only says
/// whether THIS photo may be saved although part of the (generous) box is outside it.
///
/// Rule version 1. Thresholds are fixed in `ObjectEvidenceRuleConfig.v1` before any validation result is looked at
/// (docs/OBJECT_VISION_VALIDATION_CRITERIA.md); they are not tuned afterwards.
struct ObjectNormalizedRect: Equatable {
    var minX: Double
    var minY: Double
    var maxX: Double
    var maxY: Double

    var width: Double { maxX - minX }
    var height: Double { maxY - minY }
    var centerX: Double { (minX + maxX) / 2 }
    var centerY: Double { (minY + maxY) / 2 }
    var area: Double { max(0, width) * max(0, height) }

    func iou(_ other: ObjectNormalizedRect) -> Double {
        let ix = max(0, min(maxX, other.maxX) - max(minX, other.minX))
        let iy = max(0, min(maxY, other.maxY) - max(minY, other.minY))
        let inter = ix * iy
        let union = area + other.area - inter
        return union > 0 ? inter / union : 0
    }
}

enum ObjectEvidenceUnknownReason: String, Equatable {
    /// The analysis did not run or failed (Vision error, bad input, thermal state, timeout).
    case failed
    case noCandidateInBox
    /// More than one foreground object competes inside the box.
    case multipleCandidates
    /// The chosen object extends far outside the box (floor, table, wall picked instead of the product).
    case maskLeavesBox
    /// The chosen object is not inside the projected box.
    case notInsideBox
    /// The box's bottom face is not (enough) in the photo to check the object stands on it.
    case baseNotVisible
    /// The object does not cover the box's footprint (a fragment or something else in the box).
    case baseNotTouched
    case sizeOutOfRange
    case tooCloseToEdge
    /// The strip along a clipped photo edge looks like the product, not like the background: the product may go on.
    case productMayContinue
}

enum ObjectProductEvidence: Equatable {
    /// Positive evidence that the whole product is inside the photo, with its extent (normalised 0...1).
    case productInFrame(ObjectNormalizedRect)
    /// The product reaches the photo edge.
    case productCutOff
    /// No usable evidence. The caller must fall back to the box rule.
    case unknown(ObjectEvidenceUnknownReason)
}

struct ObjectEvidenceRuleConfig: Equatable {
    /// Width of the band along each photo edge that counts as "touching the edge" (share of the short side).
    var edgeBandFraction = 0.01
    /// The product must stay at least this far from every edge (share of the short side).
    var safeMarginFraction = 0.03
    /// The projected box (hull) is enlarged by this factor about its centre before "inside the box" tests.
    var hullScale = 1.08
    /// Foreground instances with fewer pixels than this share of the photo inside the box are ignored.
    var minCandidateAreaFraction = 0.01
    /// A second candidate above this share of the main candidate's in-box area makes the scene ambiguous.
    var dominantAreaRatio = 0.25
    /// At most this share of the chosen object's pixels may lie outside the (enlarged) box.
    var maxMaskOutsideHull = 0.35
    /// Product long side / photo short side.
    var minLongSide = 0.25
    var maxLongSide = 0.85
    /// The object's box in the photo must lie within the hull's bounds enlarged by this share of the hull size.
    var boxBoundsSlack = 0.10
    /// The bottom face of the box (enlarged by `baseScale`) must be at least this visible in the photo ...
    var baseMinVisible = 0.80
    var baseScale = 1.15
    /// ... and the object must cover at least this share of its visible part.
    var baseMinCoverage = 0.10
    /// Strip along a clipped photo edge (share of the short side) used for the "does the product go on" check.
    var stripFraction = 0.03
    /// If the strip is closer to the product's brightness than this share of its distance to the background's, the
    /// product may continue beyond the edge.
    var continuityRatio = 0.6
    /// Strip and background must differ by at least this many luma levels for the check to say anything.
    var continuityMinContrast = 3.0
    /// Strip / background samples needed for the check.
    var continuityMinSamples = 50

    static let v1 = ObjectEvidenceRuleConfig()
}

enum ObjectProductEvidenceRule {
    struct Input {
        /// width * height instance labels, row-major, 0 = background.
        var labels: [UInt8]
        /// width * height luma, same layout as `labels`; nil when unavailable.
        var luma: [UInt8]?
        var width: Int
        var height: Int
        /// Convex hull of the 8 projected box corners, normalised (0...1 of the analysed image; may lie outside).
        var hull: [CGPoint]
        /// The 4 projected bottom corners of the box in polygon order, normalised.
        var baseFace: [CGPoint]
    }

    private struct InstanceStats {
        var area = 0
        var inHull = 0
        var minX = Int.max
        var minY = Int.max
        var maxX = -1
        var maxY = -1
        var touchesEdge = false
    }

    static func evaluate(_ input: Input, config: ObjectEvidenceRuleConfig = .v1) -> ObjectProductEvidence {
        let w = input.width
        let h = input.height
        guard w > 0, h > 0, input.labels.count == w * h, input.hull.count >= 3 else { return .unknown(.failed) }
        let wd = Double(w)
        let hd = Double(h)
        let shortSide = min(wd, hd)
        let hullPx = pixelPolygon(scaled(input.hull, by: config.hullScale), width: wd, height: hd)
        let band = max(1, Int((config.edgeBandFraction * shortSide).rounded()))

        // Pass 1: per-instance statistics.
        var stats: [Int: InstanceStats] = [:]
        for y in 0..<h {
            let row = y * w
            for x in 0..<w {
                let id = Int(input.labels[row + x])
                if id == 0 { continue }
                var s = stats[id] ?? InstanceStats()
                s.area += 1
                if contains(hullPx, x: Double(x) + 0.5, y: Double(y) + 0.5) { s.inHull += 1 }
                if x < s.minX { s.minX = x }
                if x > s.maxX { s.maxX = x }
                if y < s.minY { s.minY = y }
                if y > s.maxY { s.maxY = y }
                if x < band || y < band || x >= w - band || y >= h - band { s.touchesEdge = true }
                stats[id] = s
            }
        }
        let minArea = Int((config.minCandidateAreaFraction * wd * hd).rounded())
        let candidates = stats.filter { $0.value.inHull >= max(1, minArea) }
            .sorted { $0.value.inHull > $1.value.inHull }
        guard let main = candidates.first else { return .unknown(.noCandidateInBox) }
        if candidates.count >= 2,
           Double(candidates[1].value.inHull) >= config.dominantAreaRatio * Double(main.value.inHull) {
            return .unknown(.multipleCandidates)
        }
        let m = main.value
        let outsideShare = 1.0 - Double(m.inHull) / Double(max(1, m.area))
        if outsideShare > config.maxMaskOutsideHull { return .unknown(.maskLeavesBox) }
        if m.touchesEdge { return .productCutOff }

        let rect = ObjectNormalizedRect(
            minX: Double(m.minX) / wd, minY: Double(m.minY) / hd,
            maxX: Double(m.maxX + 1) / wd, maxY: Double(m.maxY + 1) / hd
        )
        let marginPx = min(Double(m.minX), Double(m.minY), Double(w - 1 - m.maxX), Double(h - 1 - m.maxY))
        if marginPx / shortSide < config.safeMarginFraction { return .unknown(.tooCloseToEdge) }

        let hullXs = input.hull.map { Double($0.x) }
        let hullYs = input.hull.map { Double($0.y) }
        let hullMinX = hullXs.min() ?? 0, hullMaxX = hullXs.max() ?? 1
        let hullMinY = hullYs.min() ?? 0, hullMaxY = hullYs.max() ?? 1
        let slackX = config.boxBoundsSlack * (hullMaxX - hullMinX)
        let slackY = config.boxBoundsSlack * (hullMaxY - hullMinY)
        if rect.minX < hullMinX - slackX || rect.maxX > hullMaxX + slackX
            || rect.minY < hullMinY - slackY || rect.maxY > hullMaxY + slackY {
            return .unknown(.notInsideBox)
        }
        let longSide = max(rect.width * wd, rect.height * hd) / shortSide
        if longSide < config.minLongSide || longSide > config.maxLongSide { return .unknown(.sizeOutOfRange) }

        // The object must stand on the box's bottom face.
        if input.baseFace.count < 3 { return .unknown(.baseNotVisible) }
        let basePx = pixelPolygon(scaled(input.baseFace, by: config.baseScale), width: wd, height: hd)
        let baseArea = polygonArea(basePx)
        if baseArea < 16 { return .unknown(.baseNotVisible) }
        let bxs = basePx.map { $0.x }
        let bys = basePx.map { $0.y }
        let x0 = max(0, Int((bxs.min() ?? 0).rounded(.down)))
        let x1 = min(w - 1, Int((bxs.max() ?? 0).rounded(.up)))
        let y0 = max(0, Int((bys.min() ?? 0).rounded(.down)))
        let y1 = min(h - 1, Int((bys.max() ?? 0).rounded(.up)))
        var baseVisible = 0
        var baseCovered = 0
        if x0 <= x1, y0 <= y1 {
            for y in y0...y1 {
                for x in x0...x1 where contains(basePx, x: Double(x) + 0.5, y: Double(y) + 0.5) {
                    baseVisible += 1
                    if Int(input.labels[y * w + x]) == main.key { baseCovered += 1 }
                }
            }
        }
        if Double(baseVisible) / baseArea < config.baseMinVisible { return .unknown(.baseNotVisible) }
        if Double(baseCovered) / Double(max(1, baseVisible)) < config.baseMinCoverage { return .unknown(.baseNotTouched) }

        // If the box is clipped by a photo edge, check the product does not simply go on beyond that edge.
        let clipped = [hullMinX < 0, hullMaxX > 1, hullMinY < 0, hullMaxY > 1] // left, right, top, bottom
        if clipped.contains(true) {
            guard let luma = input.luma, luma.count == w * h else { return .unknown(.failed) }
            let stripPx = max(2, Int((config.stripFraction * shortSide).rounded()))
            var sumP = 0.0
            var countP = 0
            var sumS = [Double](repeating: 0, count: 4)
            var countS = [Int](repeating: 0, count: 4)
            var sumB = [Double](repeating: 0, count: 4)
            var countB = [Int](repeating: 0, count: 4)
            for y in 0..<h {
                for x in 0..<w {
                    let idx = y * w + x
                    let id = Int(input.labels[idx])
                    let l = Double(luma[idx])
                    if id == main.key {
                        sumP += l
                        countP += 1
                        continue
                    }
                    let dist = [x, w - 1 - x, y, h - 1 - y]
                    var near = false
                    for e in 0..<4 where clipped[e] && dist[e] < stripPx { near = true }
                    var far = false
                    if id == 0 {
                        for e in 0..<4 where clipped[e] && dist[e] > 2 * stripPx { far = true }
                    }
                    if !near && !far { continue }
                    guard contains(hullPx, x: Double(x) + 0.5, y: Double(y) + 0.5) else { continue }
                    for e in 0..<4 where clipped[e] {
                        if dist[e] < stripPx {
                            sumS[e] += l
                            countS[e] += 1
                        } else if id == 0 && dist[e] > 2 * stripPx {
                            sumB[e] += l
                            countB[e] += 1
                        }
                    }
                }
            }
            if countP > 0 {
                let meanP = sumP / Double(countP)
                for e in 0..<4 where clipped[e]
                    && countS[e] >= config.continuityMinSamples && countB[e] >= config.continuityMinSamples {
                    let meanS = sumS[e] / Double(countS[e])
                    let meanB = sumB[e] / Double(countB[e])
                    let toBackground = abs(meanS - meanB)
                    if toBackground < config.continuityMinContrast { continue }
                    if abs(meanS - meanP) < config.continuityRatio * toBackground {
                        return .unknown(.productMayContinue)
                    }
                }
            }
        }
        return .productInFrame(rect)
    }

    // MARK: - Geometry

    private static func scaled(_ pts: [CGPoint], by factor: Double) -> [CGPoint] {
        guard !pts.isEmpty else { return pts }
        let cx = pts.reduce(0.0) { $0 + Double($1.x) } / Double(pts.count)
        let cy = pts.reduce(0.0) { $0 + Double($1.y) } / Double(pts.count)
        return pts.map { CGPoint(x: cx + (Double($0.x) - cx) * factor, y: cy + (Double($0.y) - cy) * factor) }
    }

    private static func pixelPolygon(_ pts: [CGPoint], width: Double, height: Double) -> [(x: Double, y: Double)] {
        pts.map { (x: Double($0.x) * width, y: Double($0.y) * height) }
    }

    private static func polygonArea(_ poly: [(x: Double, y: Double)]) -> Double {
        var a = 0.0
        for i in poly.indices {
            let p = poly[i]
            let q = poly[(i + 1) % poly.count]
            a += p.x * q.y - q.x * p.y
        }
        return abs(a) / 2
    }

    /// Even-odd point-in-polygon test.
    private static func contains(_ poly: [(x: Double, y: Double)], x: Double, y: Double) -> Bool {
        var inside = false
        var j = poly.count - 1
        for i in poly.indices {
            let a = poly[i]
            let b = poly[j]
            if (a.y > y) != (b.y > y) {
                let crossX = (b.x - a.x) * (y - a.y) / (b.y - a.y) + a.x
                if x < crossX { inside.toggle() }
            }
            j = i
        }
        return inside
    }
}
