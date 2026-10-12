import Foundation

// Automatic registration logic: image quality, duplicate suppression, merging observations of one physical product,
// grouping look-alike products, and applying a recording to the stored shelf data. Pure Swift (Linux-testable).

enum StoreImageStats {
    /// Variance of the 4-neighbour Laplacian over a luma plane (row-major, width*height). Low = blurry.
    static func laplacianVariance(luma: [UInt8], width: Int, height: Int) -> Float {
        guard width >= 3, height >= 3, luma.count >= width * height else { return 0 }
        var sum: Double = 0, sumSq: Double = 0
        var n = 0
        for y in 1..<(height - 1) {
            for x in 1..<(width - 1) {
                let i = y * width + x
                let l = 4 * Int(luma[i]) - Int(luma[i - 1]) - Int(luma[i + 1]) - Int(luma[i - width]) - Int(luma[i + width])
                sum += Double(l)
                sumSq += Double(l * l)
                n += 1
            }
        }
        guard n > 0 else { return 0 }
        let mean = sum / Double(n)
        return Float(max(0, sumSq / Double(n) - mean * mean))
    }

    /// Standard deviation of a luma plane (0...255). A flat white or black strip is near 0; packaging with print is not.
    static func lumaStd(luma: [UInt8]) -> Float {
        guard !luma.isEmpty else { return 0 }
        var sum: Double = 0, sumSq: Double = 0
        for v in luma {
            let d = Double(v)
            sum += d
            sumSq += d * d
        }
        let n = Double(luma.count)
        let mean = sum / n
        return Float(max(0, sumSq / n - mean * mean).squareRoot())
    }

    /// 16-bin descriptor: 12 hue bins weighted by saturation * value (colour), plus 4 brightness bins for grey pixels.
    /// RGBA, 8 bit, row-major. L1-normalised so crops of different size compare.
    static func colorDescriptor(rgba: [UInt8], width: Int, height: Int) -> [Float] {
        var bins = [Float](repeating: 0, count: 16)
        let count = width * height
        guard width > 0, height > 0, rgba.count >= count * 4 else { return bins }
        for p in 0..<count {
            let r = Float(rgba[p * 4]) / 255, g = Float(rgba[p * 4 + 1]) / 255, b = Float(rgba[p * 4 + 2]) / 255
            let mx = max(r, g, b), mn = min(r, g, b)
            let delta = mx - mn
            let sat = mx > 1e-6 ? delta / mx : 0
            if sat < 0.18 || mx < 0.12 {
                let idx = min(3, Int(mx * 4))
                bins[12 + idx] += 1
                continue
            }
            var hue: Float
            if delta < 1e-6 {
                hue = 0
            } else if mx == r {
                hue = (g - b) / delta
                if hue < 0 { hue += 6 }
            } else if mx == g {
                hue = (b - r) / delta + 2
            } else {
                hue = (r - g) / delta + 4
            }
            let idx = min(11, Int(hue / 6 * 12))
            bins[idx] += sat * mx
        }
        let total = bins.reduce(0, +)
        guard total > 1e-9 else { return bins }
        return bins.map { $0 / total }
    }
}

/// Non-maximum suppression over detected regions (higher score wins), also dropping a box that is mostly inside a
/// better one. Returns the indices to keep, best first.
enum StoreRegionNMS {
    static func iou(_ a: StoreImageSpace.PixelRect, _ b: StoreImageSpace.PixelRect) -> Float {
        let iw = max(0, min(a.maxU, b.maxU) - max(a.minU, b.minU))
        let ih = max(0, min(a.maxV, b.maxV) - max(a.minV, b.minV))
        let inter = iw * ih
        let union = a.width * a.height + b.width * b.height - inter
        return union > 0 ? inter / union : 0
    }

    static func containment(inner a: StoreImageSpace.PixelRect, outer b: StoreImageSpace.PixelRect) -> Float {
        let iw = max(0, min(a.maxU, b.maxU) - max(a.minU, b.minU))
        let ih = max(0, min(a.maxV, b.maxV) - max(a.minV, b.minV))
        let area = a.width * a.height
        return area > 0 ? iw * ih / area : 0
    }

    static func suppress(_ items: [(rect: StoreImageSpace.PixelRect, score: Float)], iouThreshold: Float = 0.5,
                         containmentThreshold: Float = 0.85) -> [Int] {
        let order = items.indices.sorted { items[$0].score > items[$1].score }
        var kept: [Int] = []
        for i in order {
            var drop = false
            for k in kept {
                if iou(items[i].rect, items[k].rect) > iouThreshold
                    || containment(inner: items[i].rect, outer: items[k].rect) > containmentThreshold {
                    drop = true
                    break
                }
            }
            if !drop { kept.append(i) }
        }
        return kept
    }
}

// MARK: - Observations -> candidates

/// One detection of a product in one frame, already placed on the shelf plane.
struct ShelfObservation: Equatable, Sendable {
    var time: Double
    var u: Float
    var v: Float
    var world: Vec3
    var uncertaintyM: Float
    var widthM: Float
    var heightM: Float
    var appearance: ShelfAppearance
    var sharpness: Float
    /// Handle of the saved crop (file name); opaque here.
    var cropRef: String
    /// Index of the analysed frame. Two detections of ONE frame are two physical items (never merged); -1 = unknown.
    var frameIndex: Int = -1
    /// Tangent of the viewing angle at the shelf plane (lateral offset of the hit point from the camera / distance of
    /// the camera from the plane). With it the apparent position of an item that stands behind the plane can be
    /// corrected: nil = unknown (no parallax handling).
    var viewTanU: Float?
    var viewTanV: Float?
    /// World displacement for one metre of depth behind the plane along this observation's ray.
    var rayPerDepth: Vec3?
    /// 1 = whole item inside the frame; lower when the box is cut by the image border.
    var completeness: Float = 1
    /// Text read on this item in this frame (may be empty: OCR is budgeted).
    var texts: [ShelfTextLine] = []
    var barcodes: [String] = []

    /// Representative-image quality: sharp AND whole.
    var quality: Float { sharpness * max(0.05, completeness) }
}

enum ShelfRejectReason: String, Codable, Sendable {
    case tooFewObservations
    case blurry
}

struct ShelfRejectedRegion: Equatable, Sendable {
    var u: Float
    var v: Float
    var observationCount: Int
    var reason: ShelfRejectReason
}

struct ShelfCandidate: Equatable, Sendable {
    var u: Float
    var v: Float
    var widthM: Float
    var heightM: Float
    var uncertaintyM: Float
    var observationCount: Int
    var firstTime: Double
    var lastTime: Double
    var medianSharpness: Float
    /// Sharpest first.
    var appearances: [ShelfAppearance]
    /// Best (sharp and whole) first.
    var cropRefs: [String]
    var world: Vec3
    var needsReview: Bool
    var reviewReasons: [String]
    /// Estimated distance of the item behind the shelf-front plane (metres); nil when the views did not allow a fit.
    var depthBehindPlaneM: Float? = nil
    var name: ShelfExtractedName? = nil
    var barcodes: [String] = []
    /// Number of distinct frames this item was seen in.
    var frameCount: Int = 0
}

struct ShelfAggregationConfig: Sendable {
    var posRadiusFloor: Float = 0.05
    var posRadiusFactor: Float = 0.5
    /// Observations at the same place belong to the same product only if their appearance is this close (to ANY of the
    /// cluster's recent or sharpest views, not just one).
    var sameAppearanceMax: Float = 0.20
    var minObservations: Int = 3
    var minSharpness: Float = 25
    var maxObservationsPerCandidate: Int = 60
    var keepAppearances: Int = 5
    /// A median lateral uncertainty above this marks the placement as uncertain (kept, flagged for review).
    var uncertainPositionM: Float = 0.12
    /// How far behind the shelf-front plane an item may stand (a refrigerator is deeper than a shelf).
    var maxDepthBehindPlaneM: Float = 0.6
    /// Views of one item are spread over at least this much tangent range before the depth is fitted.
    var minTangentSpread: Float = 0.12
    /// Dropped from the unsaved-area count when a rejected area lies this close to an accepted product.
    var absorbRadiusM: Float = 0.08
    var mergeClusters = true
}

struct ShelfAggregationResult: Equatable, Sendable {
    var candidates: [ShelfCandidate]
    var rejected: [ShelfRejectedRegion]
    /// Diagnostics: clusters before and after the final merge, areas absorbed into products.
    var clustersBeforeMerge: Int = 0
    var clustersMerged: Int = 0
    var rejectedAbsorbed: Int = 0
}

/// Parallax: an item that stands `d` metres behind the shelf-front plane appears at hit + d * tan(view angle). Two
/// observations are the same place if some depth in [0, maxDepth] makes their corrected positions coincide.
enum ShelfParallax {
    static func minSeparation(_ a: ShelfObservation, _ b: ShelfObservation, maxDepth: Float) -> Float {
        let du = b.u - a.u, dv = b.v - a.v
        guard let tua = a.viewTanU, let tub = b.viewTanU, let tva = a.viewTanV, let tvb = b.viewTanV else {
            return (du * du + dv * dv).squareRoot()
        }
        let gu = tub - tua, gv = tvb - tva
        let g2 = gu * gu + gv * gv
        var d: Float = 0
        if g2 > 1e-9 {
            d = -(du * gu + dv * gv) / g2
            d = min(max(d, 0), maxDepth)
        }
        let x = du + d * gu, y = dv + d * gv
        return (x * x + y * y).squareRoot()
    }

    struct Fit: Equatable, Sendable {
        var u: Float
        var v: Float
        var depth: Float?
        var parallaxUncertainty: Float
    }

    /// Corrected plane position of an item from all its observations (median of the corrected hit points).
    static func fit(_ obs: [ShelfObservation], maxDepth: Float, minSpread: Float, median: ([Float]) -> Float) -> Fit {
        let us = obs.map(\.u), vs = obs.map(\.v)
        let withTan = obs.filter { $0.viewTanU != nil && $0.viewTanV != nil }
        guard withTan.count >= 3 else {
            return Fit(u: median(us), v: median(vs), depth: nil, parallaxUncertainty: 0)
        }
        let n = Float(withTan.count)
        let mu = withTan.map(\.u).reduce(0, +) / n, mv = withTan.map(\.v).reduce(0, +) / n
        let mtu = withTan.map { $0.viewTanU! }.reduce(0, +) / n, mtv = withTan.map { $0.viewTanV! }.reduce(0, +) / n
        var num: Float = 0, den: Float = 0
        for o in withTan {
            let tu = o.viewTanU! - mtu, tv = o.viewTanV! - mtv
            num += (o.u - mu) * tu + (o.v - mv) * tv
            den += tu * tu + tv * tv
        }
        let spread = (den / n).squareRoot()
        let meanTan = max(abs(mtu), abs(mtv))
        guard den > 1e-9, spread >= minSpread else {
            // Depth unknown: the position error it can cause is at most half the allowed depth times the viewing tangent.
            return Fit(u: median(us), v: median(vs), depth: nil, parallaxUncertainty: 0.5 * maxDepth * meanTan)
        }
        let depth = min(max(-num / den, -0.1), maxDepth)
        let cu = withTan.map { $0.u + depth * $0.viewTanU! }
        let cv = withTan.map { $0.v + depth * $0.viewTanV! }
        return Fit(u: median(cu), v: median(cv), depth: depth, parallaxUncertainty: 0.02)
    }
}

/// Merges per-frame detections of the same physical product (duplicate detections across frames, seen from several
/// angles) and keeps apart different products: two detections of one frame are never one item, and views that differ
/// only by parallax of an item standing behind the shelf front are still one item.
struct ShelfObservationAggregator {
    private struct Cluster {
        var observations: [ShelfObservation]
        var overlapConflict = false

        var frames: Set<Int> {
            Set(observations.map(\.frameIndex).filter { $0 >= 0 })
        }
    }

    let config: ShelfAggregationConfig
    private var clusters: [Cluster] = []

    init(config: ShelfAggregationConfig = ShelfAggregationConfig()) {
        self.config = config
    }

    var clusterCount: Int { clusters.count }

    private static func median(_ a: [Float]) -> Float {
        guard !a.isEmpty else { return 0 }
        let s = a.sorted()
        let n = s.count
        return n % 2 == 1 ? s[n / 2] : (s[n / 2 - 1] + s[n / 2]) / 2
    }

    private func radius(widthM: Float, uncertaintyM: Float) -> Float {
        max(config.posRadiusFloor, config.posRadiusFactor * widthM) + 0.5 * uncertaintyM
    }

    /// The views a new observation is compared with: the most recent and the sharpest ones.
    private func references(_ c: Cluster) -> [ShelfObservation] {
        var out = Array(c.observations.suffix(4))
        for s in c.observations.sorted(by: { $0.quality > $1.quality }).prefix(4)
        where !out.contains(where: { $0.cropRef == s.cropRef && $0.time == s.time && $0.u == s.u }) {
            out.append(s)
        }
        return out
    }

    private func appearanceDistance(_ refs: [ShelfObservation], _ obs: ShelfObservation) -> Float? {
        var best: Float?
        for r in refs {
            if let d = r.appearance.distance(to: obs.appearance) { best = min(best ?? d, d) }
        }
        return best
    }

    private static func barcodesConflict(_ a: [String], _ b: [String]) -> Bool {
        !a.isEmpty && !b.isEmpty && Set(a).isDisjoint(with: Set(b))
    }

    /// Index of the cluster `obs` belongs to, and whether a cluster at the same place had a different look.
    private func bestCluster(for obs: ShelfObservation) -> (index: Int?, otherLookHere: Bool) {
        var best: (index: Int, cost: Float)?
        var otherLook = false
        for (i, c) in clusters.enumerated() {
            if obs.frameIndex >= 0, c.frames.contains(obs.frameIndex) { continue }
            let refs = references(c)
            var sep = Float.infinity
            for r in refs { sep = min(sep, ShelfParallax.minSeparation(r, obs, maxDepth: config.maxDepthBehindPlaneM)) }
            let w = Self.median(c.observations.map(\.widthM))
            let r = radius(widthM: w, uncertaintyM: obs.uncertaintyM)
            guard sep <= r else { continue }
            if let d = appearanceDistance(refs, obs), d > config.sameAppearanceMax {
                otherLook = true
                continue
            }
            if Self.barcodesConflict(c.observations.flatMap(\.barcodes), obs.barcodes) {
                otherLook = true
                continue
            }
            let cost = sep / r
            if best == nil || cost < best!.cost { best = (i, cost) }
        }
        return (best?.index, otherLook)
    }

    /// How many text reads the item `obs` would join already has (callers spend OCR where it is still missing).
    func textReads(for obs: ShelfObservation) -> Int {
        guard let i = bestCluster(for: obs).index else { return 0 }
        return clusters[i].observations.filter { !$0.texts.isEmpty }.count
    }

    mutating func add(_ obs: ShelfObservation) {
        let found = bestCluster(for: obs)
        if let i = found.index {
            clusters[i].observations.append(obs)
            if clusters[i].observations.count > config.maxObservationsPerCandidate {
                if let worst = clusters[i].observations.indices.min(by: {
                    clusters[i].observations[$0].quality < clusters[i].observations[$1].quality
                }) {
                    clusters[i].observations.remove(at: worst)
                }
            }
        } else {
            clusters.append(Cluster(observations: [obs], overlapConflict: found.otherLookHere))
        }
    }

    /// Two clusters are one item when they never share a frame, sit at one place (parallax-aware) and look the same.
    private func shouldMerge(_ a: Cluster, _ b: Cluster) -> Bool {
        let fa = a.frames, fb = b.frames
        if !fa.isEmpty, !fb.isEmpty, !fa.isDisjoint(with: fb) { return false }
        let ta = Set(a.observations.map(\.time)), tb = Set(b.observations.map(\.time))
        if fa.isEmpty || fb.isEmpty, !ta.isDisjoint(with: tb) { return false }
        if Self.barcodesConflict(a.observations.flatMap(\.barcodes), b.observations.flatMap(\.barcodes)) { return false }
        let w = max(Self.median(a.observations.map(\.widthM)), Self.median(b.observations.map(\.widthM)))
        let r = radius(widthM: w, uncertaintyM: Self.median(a.observations.map(\.uncertaintyM)))
        let ra = references(a), rb = references(b)
        var sep = Float.infinity
        for x in ra {
            for y in rb { sep = min(sep, ShelfParallax.minSeparation(x, y, maxDepth: config.maxDepthBehindPlaneM)) }
        }
        guard sep <= r else { return false }
        var d = Float.infinity
        for x in ra {
            for y in rb {
                if let v = x.appearance.distance(to: y.appearance) { d = min(d, v) }
            }
        }
        let sameCode = !Set(a.observations.flatMap(\.barcodes)).isDisjoint(with: Set(b.observations.flatMap(\.barcodes)))
        return d <= config.sameAppearanceMax || sameCode
    }

    private func mergedClusters() -> (clusters: [Cluster], merged: Int) {
        var cs = clusters
        guard config.mergeClusters, cs.count > 1 else { return (cs, 0) }
        var merged = 0
        var changed = true
        while changed {
            changed = false
            outer: for i in cs.indices {
                for j in cs.indices where j > i {
                    if shouldMerge(cs[i], cs[j]) {
                        cs[i].observations.append(contentsOf: cs[j].observations)
                        cs[i].overlapConflict = cs[i].overlapConflict || cs[j].overlapConflict
                        cs.remove(at: j)
                        merged += 1
                        changed = true
                        break outer
                    }
                }
            }
        }
        return (cs, merged)
    }

    func finalize() -> ShelfAggregationResult {
        let (cs, merged) = mergedClusters()
        var candidates: [ShelfCandidate] = []
        var weak: [(cluster: Cluster, u: Float, v: Float, reason: ShelfRejectReason)] = []
        for c in cs {
            let obs = c.observations
            let fit = ShelfParallax.fit(obs, maxDepth: config.maxDepthBehindPlaneM, minSpread: config.minTangentSpread,
                                        median: Self.median)
            let u = fit.u, v = fit.v
            if obs.count < config.minObservations {
                weak.append((c, u, v, .tooFewObservations))
                continue
            }
            let sharp = Self.median(obs.map(\.sharpness))
            if sharp < config.minSharpness {
                weak.append((c, u, v, .blurry))
                continue
            }
            let byQuality = obs.sorted { $0.quality > $1.quality }
            let bySharp = obs.sorted { $0.sharpness > $1.sharpness }
            let baseUnc = Self.median(obs.map(\.uncertaintyM))
            let unc = (baseUnc * baseUnc + fit.parallaxUncertainty * fit.parallaxUncertainty).squareRoot()
            var reasons: [String] = []
            if unc > config.uncertainPositionM { reasons.append("위치가 불확실해요") }
            if c.overlapConflict { reasons.append("다른 제품과 겹쳐 보여요") }
            var world = Vec3(Self.median(obs.map { $0.world.x }), Self.median(obs.map { $0.world.y }),
                             Self.median(obs.map { $0.world.z }))
            if let depth = fit.depth, depth > 0.01 {
                let shifted = obs.compactMap { o -> Vec3? in o.rayPerDepth.map { o.world + $0 * depth } }
                if shifted.count >= 3 {
                    world = Vec3(Self.median(shifted.map(\.x)), Self.median(shifted.map(\.y)), Self.median(shifted.map(\.z)))
                }
            }
            let textSets = byQuality.prefix(12).map(\.texts).filter { !$0.isEmpty }
            let name = ShelfProductNameExtractor.extract(observations: Array(textSets))
            var barcodeVotes: [String: Int] = [:]
            for o in obs {
                for b in o.barcodes { barcodeVotes[b, default: 0] += 1 }
            }
            let barcodes = barcodeVotes.filter { $0.value >= 2 || obs.count < 4 }.sorted { $0.value > $1.value }.map(\.key)
            var candidate = ShelfCandidate(
                u: u, v: v,
                widthM: Self.median(obs.map(\.widthM)), heightM: Self.median(obs.map(\.heightM)),
                uncertaintyM: unc, observationCount: obs.count,
                firstTime: obs.map(\.time).min() ?? 0, lastTime: obs.map(\.time).max() ?? 0,
                medianSharpness: sharp,
                appearances: Array(bySharp.prefix(config.keepAppearances).map(\.appearance)),
                cropRefs: Array(byQuality.prefix(3).map(\.cropRef)),
                world: world,
                needsReview: !reasons.isEmpty, reviewReasons: reasons)
            candidate.depthBehindPlaneM = fit.depth
            candidate.name = name
            candidate.barcodes = barcodes
            candidate.frameCount = Set(obs.map { $0.frameIndex >= 0 ? $0.frameIndex : Int($0.time * 1000) }).count
            candidates.append(candidate)
        }
        candidates.sort { ($0.u, $0.v) < ($1.u, $1.v) }

        // Unsaved areas: a weak cluster that belongs to an accepted product is that product's evidence, not a new
        // area; weak clusters on top of each other are one area.
        var rejected: [ShelfRejectedRegion] = []
        var absorbed = 0
        for w in weak {
            let wObs = w.cluster.observations
            var belongs = false
            for cand in candidates {
                let du = cand.u - w.u, dv = cand.v - w.v
                let dist = (du * du + dv * dv).squareRoot()
                guard dist <= max(config.absorbRadiusM, 0.6 * cand.widthM) else { continue }
                var d = Float.infinity
                for a in cand.appearances {
                    for o in wObs {
                        if let x = a.distance(to: o.appearance) { d = min(d, x) }
                    }
                }
                if d <= config.sameAppearanceMax + 0.1 {
                    belongs = true
                    break
                }
            }
            if belongs {
                absorbed += 1
                continue
            }
            if let i = rejected.firstIndex(where: {
                let du = $0.u - w.u, dv = $0.v - w.v
                return (du * du + dv * dv).squareRoot() <= 0.12
            }) {
                rejected[i].observationCount += wObs.count
                if w.reason == .blurry { rejected[i].reason = .blurry }
                continue
            }
            rejected.append(ShelfRejectedRegion(u: w.u, v: w.v, observationCount: wObs.count, reason: w.reason))
        }
        rejected.sort { ($0.u, $0.v) < ($1.u, $1.v) }
        return ShelfAggregationResult(candidates: candidates, rejected: rejected, clustersBeforeMerge: clusters.count,
                                      clustersMerged: merged, rejectedAbsorbed: absorbed)
    }
}

// MARK: - Candidates -> products

struct ShelfProductGroup: Equatable, Sendable {
    /// Indices into the candidate array; the first is the representative.
    var candidateIndices: [Int]
    /// Other groups whose look is close but not the same (probably another flavour / size).
    var similarGroups: [Int]
}

enum ShelfProductGrouper {
    struct Thresholds: Sendable {
        var sameMax: Float = 0.20
        var similarMax: Float = 0.35
        /// Names read with at least this confidence are trusted to tell two products apart.
        var trustedNameConfidence: Float = 0.75
    }

    enum Relation: Equatable, Sendable {
        case same
        case similar
        case different
    }

    static func appearanceDistance(_ a: ShelfCandidate, _ b: ShelfCandidate) -> Float? {
        var best: Float?
        for x in a.appearances {
            for y in b.appearances {
                if let d = x.distance(to: y) { best = min(best ?? d, d) }
            }
        }
        return best
    }

    /// Image distance decides, unless stronger evidence exists: a shared barcode is the same product, different barcodes
    /// are different products; two confidently read, different names are different products (variants of one look).
    static func relation(_ a: ShelfCandidate, _ b: ShelfCandidate, thresholds t: Thresholds = Thresholds()) -> Relation {
        let d = appearanceDistance(a, b)
        if !a.barcodes.isEmpty, !b.barcodes.isEmpty {
            if Set(a.barcodes).isDisjoint(with: Set(b.barcodes)) { return (d ?? 1) <= t.similarMax ? .similar : .different }
            return .same
        }
        if let na = a.name, let nb = b.name, !na.needsConfirmation, !nb.needsConfirmation {
            let ka = ShelfProductNameExtractor.key(na.displayName), kb = ShelfProductNameExtractor.key(nb.displayName)
            if ShelfProductNameExtractor.sameName(ka, kb) {
                if let d, d <= t.similarMax { return .same }
            } else if na.confidence >= t.trustedNameConfidence, nb.confidence >= t.trustedNameConfidence {
                return (d ?? 1) <= t.similarMax ? .similar : .different
            }
        }
        guard let d else { return .different }
        if d <= t.sameMax { return .same }
        if d <= t.similarMax { return .similar }
        return .different
    }

    static func group(_ candidates: [ShelfCandidate], thresholds: Thresholds = Thresholds()) -> [ShelfProductGroup] {
        let order = candidates.indices.sorted { candidates[$0].observationCount > candidates[$1].observationCount }
        var groups: [[Int]] = []
        for i in order {
            var placed = false
            for g in groups.indices {
                if groups[g].contains(where: { relation(candidates[$0], candidates[i], thresholds: thresholds) == .same }) {
                    groups[g].append(i)
                    placed = true
                    break
                }
            }
            if !placed { groups.append([i]) }
        }
        var out = groups.map { ShelfProductGroup(candidateIndices: $0, similarGroups: []) }
        for a in out.indices {
            for b in out.indices where b > a {
                if relation(candidates[out[a].candidateIndices[0]], candidates[out[b].candidateIndices[0]], thresholds: thresholds) == .similar {
                    out[a].similarGroups.append(b)
                    out[b].similarGroups.append(a)
                }
            }
        }
        return out
    }
}

// MARK: - Applying a recording to stored data

struct ShelfRecordingCoverage: Equatable, Sendable {
    var minU: Float
    var maxU: Float
    var minV: Float
    var maxV: Float

    func contains(u: Float, v: Float) -> Bool { u >= minU && u <= maxU && v >= minV && v <= maxV }
}

struct ShelfUpdateSummary: Equatable, Sendable {
    var newProducts = 0
    var updatedPlacements = 0
    var newPlacements = 0
    var markedNotObserved = 0
    var namedAutomatically = 0
    var nameUnread = 0
}

enum ShelfNameSource {
    static let auto = "auto"
    static let manual = "manual"
    static let catalog = "catalog"
}

enum ShelfNameReview {
    static let unread = "이름을 읽지 못했어요. 직접 입력해 주세요"
    static let confirm = "자동으로 읽은 이름이에요. 맞는지 확인해 주세요"
    static let all: Set<String> = [unread, confirm]
}

extension ShelfProduct {
    /// A name the manager (or the catalogue) set: never overwritten by a recording.
    var nameIsProtected: Bool {
        if nameSource == ShelfNameSource.manual || nameSource == ShelfNameSource.catalog { return true }
        return nameSource == nil && !ShelfProductNameExtractor.isPlaceholder(name)
    }
}

enum ShelfDataUpdater {
    struct Naming {
        var newProductId: () -> String
        var newPlacementId: () -> String
        var productName: (Int) -> String
    }

    /// `cropFileNames[i]` are the saved image names of candidate i (best first), `imageNames` provided by the caller.
    static func apply(candidates: [ShelfCandidate], groups: [ShelfProductGroup], cropFileNames: [[String]],
                      shelf: ShelfLayout, coverage: ShelfRecordingCoverage, now: Date,
                      to data: StoreShelfData, naming: Naming,
                      thresholds: ShelfProductGrouper.Thresholds = ShelfProductGrouper.Thresholds())
        -> (data: StoreShelfData, summary: ShelfUpdateSummary) {
        var out = data
        var summary = ShelfUpdateSummary()
        var touchedPlacementIds = Set<String>()
        var groupProductIds = [String](repeating: "", count: groups.count)

        func existingDistance(_ cand: ShelfCandidate, _ p: ShelfProduct) -> Float? {
            var best: Float?
            for a in cand.appearances {
                for (i, e) in p.embeddings.enumerated() {
                    let col = i < p.colorDescriptors.count ? p.colorDescriptors[i].values : []
                    let ap = ShelfAppearance(embedding: e.values, color: col)
                    if let d = a.distance(to: ap) { best = min(best ?? d, d) }
                }
            }
            return best
        }

        /// Distance of a recorded group to a stored product, or nil when they are not the same product.
        func matchDistance(rep: ShelfCandidate, barcodes: [String], name: ShelfExtractedName?, product p: ShelfProduct) -> Float? {
            let d = existingDistance(rep, p)
            if let pb = p.barcodes, !pb.isEmpty, !barcodes.isEmpty {
                return Set(pb).isDisjoint(with: Set(barcodes)) ? nil : 0
            }
            // Only a name that was itself read from the package can contradict a new reading; a name typed by a person
            // says nothing about what is printed on the pack.
            if let ex = name, !ex.needsConfirmation, p.nameSource == ShelfNameSource.auto {
                let pk = ShelfProductNameExtractor.key(p.name)
                let ek = ShelfProductNameExtractor.key(ex.displayName)
                if ShelfProductNameExtractor.sameName(pk, ek) {
                    if let d, d <= thresholds.similarMax { return d }
                } else if ex.confidence >= thresholds.trustedNameConfidence, !pk.isEmpty {
                    return nil
                }
            }
            guard let d, d <= thresholds.sameMax else { return nil }
            return d
        }

        for (gi, group) in groups.enumerated() {
            let rep = candidates[group.candidateIndices[0]]
            let members = group.candidateIndices.map { candidates[$0] }
            let extracted = members.compactMap(\.name).max { $0.confidence < $1.confidence }
            let barcodes = Array(Set(members.flatMap(\.barcodes))).sorted()
            // Product: an existing one that is the same, else a new one.
            var productIndex: Int?
            var bestD = Float.infinity
            for (i, p) in out.products.enumerated() {
                if let d = matchDistance(rep: rep, barcodes: barcodes, name: extracted, product: p), d < bestD {
                    bestD = d
                    productIndex = i
                }
            }
            if productIndex == nil {
                let id = naming.newProductId()
                var reasons: [String] = []
                if members.contains(where: { $0.reviewReasons.contains("다른 제품과 겹쳐 보여요") }) {
                    reasons.append("다른 제품과 겹쳐 보여요")
                }
                let product = ShelfProduct(
                    id: id, name: naming.productName(out.products.count + 1), createdAt: now,
                    imageFileNames: [], embeddings: [], colorDescriptors: [], similarProductIds: [],
                    needsReview: false, reviewReasons: reasons
                )
                out.products.append(product)
                productIndex = out.products.count - 1
                summary.newProducts += 1
            }
            let pi = productIndex!
            let productId = out.products[pi].id
            groupProductIds[gi] = productId

            // Name: a recording fills in or improves an automatic name; a name set by a person is never touched.
            if let ex = extracted, !out.products[pi].nameIsProtected,
               out.products[pi].nameSource != ShelfNameSource.auto || ex.confidence >= (out.products[pi].nameConfidence ?? 0) {
                out.products[pi].name = ex.displayName
                out.products[pi].nameSource = ShelfNameSource.auto
                out.products[pi].nameConfidence = ex.confidence
                out.products[pi].brand = ex.brand
                out.products[pi].variantText = ex.variant
                out.products[pi].volumeText = ex.volume
                var tokens = Set(out.products[pi].ocrTokens ?? [])
                tokens.formUnion(ex.tokens)
                out.products[pi].ocrTokens = Array(tokens.sorted().prefix(24))
                summary.namedAutomatically += 1
            }
            if !barcodes.isEmpty {
                out.products[pi].barcodes = Array(Set((out.products[pi].barcodes ?? []) + barcodes)).sorted()
            }
            out.products[pi].reviewReasons.removeAll { ShelfNameReview.all.contains($0) }
            if !out.products[pi].nameIsProtected {
                if ShelfProductNameExtractor.isPlaceholder(out.products[pi].name) {
                    out.products[pi].reviewReasons.append(ShelfNameReview.unread)
                    summary.nameUnread += 1
                } else if out.products[pi].nameSource == ShelfNameSource.auto {
                    let weak = (out.products[pi].nameConfidence ?? 0) < 0.6 || extracted?.needsConfirmation == true
                    if weak { out.products[pi].reviewReasons.append(ShelfNameReview.confirm) }
                }
            }

            // Appearance data: add the sharpest new ones, bounded.
            for ci in group.candidateIndices {
                for a in candidates[ci].appearances.prefix(2) {
                    out.products[pi].embeddings.append(StoreVector(a.embedding))
                    out.products[pi].colorDescriptors.append(StoreVector(a.color))
                }
                out.products[pi].imageFileNames.append(contentsOf: cropFileNames[ci].prefix(1))
            }
            if out.products[pi].embeddings.count > 10 {
                let drop = out.products[pi].embeddings.count - 10
                out.products[pi].embeddings.removeFirst(drop)
                out.products[pi].colorDescriptors.removeFirst(min(drop, out.products[pi].colorDescriptors.count))
            }
            if out.products[pi].imageFileNames.count > 6 {
                out.products[pi].imageFileNames.removeFirst(out.products[pi].imageFileNames.count - 6)
            }
            // Placements.
            for ci in group.candidateIndices {
                let c = candidates[ci]
                let radius = max(0.06, 0.5 * c.widthM)
                var match: Int?
                var matchD = Float.infinity
                for (i, p) in out.placements.enumerated() where p.shelfId == shelf.id && p.productId == productId {
                    let du = p.u - c.u, dv = p.v - c.v
                    let d = (du * du + dv * dv).squareRoot()
                    if d <= radius, d < matchD {
                        matchD = d
                        match = i
                    }
                }
                if let i = match {
                    let old = out.placements[i]
                    let wOld = Float(old.observationCount), wNew = Float(c.observationCount)
                    let w = wOld + wNew
                    out.placements[i].u = (old.u * wOld + c.u * wNew) / w
                    out.placements[i].v = (old.v * wOld + c.v * wNew) / w
                    out.placements[i].world = Vec3((old.world.x * wOld + c.world.x * wNew) / w,
                                                   (old.world.y * wOld + c.world.y * wNew) / w,
                                                   (old.world.z * wOld + c.world.z * wNew) / w)
                    out.placements[i].observationCount = old.observationCount + c.observationCount
                    out.placements[i].lastObservedAt = now
                    out.placements[i].uncertaintyM = min(old.uncertaintyM, c.uncertaintyM)
                    out.placements[i].status = .present
                    out.placements[i].tier = shelf.tier(forV: out.placements[i].v)
                    touchedPlacementIds.insert(old.id)
                    summary.updatedPlacements += 1
                } else {
                    let id = naming.newPlacementId()
                    out.placements.append(ShelfPlacement(
                        id: id, productId: productId, shelfId: shelf.id, u: c.u, v: c.v, tier: shelf.tier(forV: c.v),
                        world: c.world, widthM: c.widthM, heightM: c.heightM, uncertaintyM: c.uncertaintyM,
                        observationCount: c.observationCount, firstObservedAt: now, lastObservedAt: now,
                        status: .present, needsReview: c.needsReview
                    ))
                    touchedPlacementIds.insert(id)
                    summary.newPlacements += 1
                }
            }
        }
        // Look-alikes among the products created or matched in this recording: flagged for review, never merged.
        for (gi, group) in groups.enumerated() {
            for other in group.similarGroups where other != gi {
                let idA = groupProductIds[gi], idB = groupProductIds[other]
                guard idA != idB, let ia = out.products.firstIndex(where: { $0.id == idA }),
                      let ib = out.products.firstIndex(where: { $0.id == idB }) else { continue }
                if !out.products[ia].similarProductIds.contains(idB) { out.products[ia].similarProductIds.append(idB) }
                if !out.products[ib].similarProductIds.contains(idA) { out.products[ib].similarProductIds.append(idA) }
                let note = "비슷한 포장의 다른 제품이 있어요 (맛·용량 확인)"
                for index in [ia, ib] {
                    // Two products whose names were both read are already told apart by their names.
                    let a = out.products[index]
                    let other = index == ia ? out.products[ib] : out.products[ia]
                    let namedApart = a.nameSource != nil && other.nameSource != nil
                        && !ShelfProductNameExtractor.isPlaceholder(a.name) && !ShelfProductNameExtractor.isPlaceholder(other.name)
                        && ShelfProductNameExtractor.key(a.name) != ShelfProductNameExtractor.key(other.name)
                    if namedApart { continue }
                    if !out.products[index].reviewReasons.contains(note) { out.products[index].reviewReasons.append(note) }
                }
            }
        }
        for i in out.products.indices where groupProductIds.contains(out.products[i].id) {
            out.products[i].needsReview = !out.products[i].reviewReasons.isEmpty
        }
        // Placements in the area this recording covered that were not seen again: kept, marked.
        for i in out.placements.indices where out.placements[i].shelfId == shelf.id && !touchedPlacementIds.contains(out.placements[i].id) {
            if coverage.contains(u: out.placements[i].u, v: out.placements[i].v), out.placements[i].status == .present {
                out.placements[i].status = .notObservedOnRescan
                summary.markedNotObserved += 1
            }
        }
        out.updatedAt = now
        return (out, summary)
    }
}

/// Splits a set of v values (heights) into shelf levels: a gap larger than `minGap` starts a new level.
enum ShelfTierClustering {
    static func boundaries(heights: [Float], minGap: Float = 0.12) -> [Float] {
        let s = heights.sorted()
        guard s.count > 1 else { return [] }
        var out: [Float] = []
        for i in 1..<s.count where s[i] - s[i - 1] > minGap {
            out.append((s[i] + s[i - 1]) / 2)
        }
        return out
    }
}
