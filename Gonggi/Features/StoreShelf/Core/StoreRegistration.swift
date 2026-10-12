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
    var cropRefs: [String]
    var world: Vec3
    var needsReview: Bool
    var reviewReasons: [String]
}

struct ShelfAggregationConfig: Sendable {
    var posRadiusFloor: Float = 0.05
    var posRadiusFactor: Float = 0.5
    /// Observations at the same place belong to the same product only if their appearance is this close.
    var sameAppearanceMax: Float = 0.20
    var minObservations: Int = 3
    var minSharpness: Float = 25
    var maxObservationsPerCandidate: Int = 60
    var keepAppearances: Int = 5
    /// A median lateral uncertainty above this marks the placement as uncertain (kept, flagged for review).
    var uncertainPositionM: Float = 0.12
}

struct ShelfAggregationResult: Equatable, Sendable {
    var candidates: [ShelfCandidate]
    var rejected: [ShelfRejectedRegion]
}

/// Merges per-frame detections of the same physical product (duplicate detections across frames) and keeps apart
/// different products that sit at nearly the same place in the image (occlusion, overlap).
struct ShelfObservationAggregator {
    private struct Cluster {
        var observations: [ShelfObservation]
        var overlapConflict = false
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

    private func radius(for cluster: Cluster, obs: ShelfObservation) -> Float {
        let w = Self.median(cluster.observations.map(\.widthM))
        return max(config.posRadiusFloor, config.posRadiusFactor * w) + 0.5 * obs.uncertaintyM
    }

    private func representative(_ c: Cluster) -> ShelfAppearance? {
        c.observations.max { $0.sharpness < $1.sharpness }?.appearance
    }

    mutating func add(_ obs: ShelfObservation) {
        var best: (index: Int, cost: Float)?
        var positionHitWithOtherLook = false
        for (i, c) in clusters.enumerated() {
            let du = Self.median(c.observations.map(\.u)) - obs.u
            let dv = Self.median(c.observations.map(\.v)) - obs.v
            let dist = (du * du + dv * dv).squareRoot()
            let r = radius(for: c, obs: obs)
            guard dist <= r else { continue }
            if let rep = representative(c), let d = rep.distance(to: obs.appearance), d > config.sameAppearanceMax {
                positionHitWithOtherLook = true
                continue
            }
            let cost = dist / r
            if best == nil || cost < best!.cost { best = (i, cost) }
        }
        if let best {
            clusters[best.index].observations.append(obs)
            if clusters[best.index].observations.count > config.maxObservationsPerCandidate {
                if let worst = clusters[best.index].observations.indices.min(by: {
                    clusters[best.index].observations[$0].sharpness < clusters[best.index].observations[$1].sharpness
                }) {
                    clusters[best.index].observations.remove(at: worst)
                }
            }
        } else {
            clusters.append(Cluster(observations: [obs], overlapConflict: positionHitWithOtherLook))
        }
    }

    func finalize() -> ShelfAggregationResult {
        var candidates: [ShelfCandidate] = []
        var rejected: [ShelfRejectedRegion] = []
        for c in clusters {
            let obs = c.observations
            let u = Self.median(obs.map(\.u)), v = Self.median(obs.map(\.v))
            if obs.count < config.minObservations {
                rejected.append(ShelfRejectedRegion(u: u, v: v, observationCount: obs.count, reason: .tooFewObservations))
                continue
            }
            let sharp = Self.median(obs.map(\.sharpness))
            if sharp < config.minSharpness {
                rejected.append(ShelfRejectedRegion(u: u, v: v, observationCount: obs.count, reason: .blurry))
                continue
            }
            let bySharp = obs.sorted { $0.sharpness > $1.sharpness }
            let unc = Self.median(obs.map(\.uncertaintyM))
            var reasons: [String] = []
            if unc > config.uncertainPositionM { reasons.append("위치가 불확실해요") }
            if c.overlapConflict { reasons.append("다른 제품과 겹쳐 보여요") }
            let wx = Self.median(obs.map { $0.world.x }), wy = Self.median(obs.map { $0.world.y }), wz = Self.median(obs.map { $0.world.z })
            candidates.append(ShelfCandidate(
                u: u, v: v,
                widthM: Self.median(obs.map(\.widthM)), heightM: Self.median(obs.map(\.heightM)),
                uncertaintyM: unc, observationCount: obs.count,
                firstTime: obs.map(\.time).min() ?? 0, lastTime: obs.map(\.time).max() ?? 0,
                medianSharpness: sharp,
                appearances: Array(bySharp.prefix(config.keepAppearances).map(\.appearance)),
                cropRefs: Array(bySharp.prefix(3).map(\.cropRef)),
                world: Vec3(wx, wy, wz),
                needsReview: !reasons.isEmpty, reviewReasons: reasons
            ))
        }
        candidates.sort { ($0.u, $0.v) < ($1.u, $1.v) }
        rejected.sort { ($0.u, $0.v) < ($1.u, $1.v) }
        return ShelfAggregationResult(candidates: candidates, rejected: rejected)
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

    static func group(_ candidates: [ShelfCandidate], thresholds: Thresholds = Thresholds()) -> [ShelfProductGroup] {
        let order = candidates.indices.sorted { candidates[$0].observationCount > candidates[$1].observationCount }
        var groups: [[Int]] = []
        for i in order {
            var placed = false
            for g in groups.indices {
                let rep = groups[g][0]
                if let d = appearanceDistance(candidates[rep], candidates[i]), d <= thresholds.sameMax {
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
                if let d = appearanceDistance(candidates[out[a].candidateIndices[0]], candidates[out[b].candidateIndices[0]]),
                   d > thresholds.sameMax, d <= thresholds.similarMax {
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

        for (gi, group) in groups.enumerated() {
            let rep = candidates[group.candidateIndices[0]]
            // Product: an existing one that looks the same, else a new one.
            var productIndex: Int?
            var bestD = Float.infinity
            for (i, p) in out.products.enumerated() {
                if let d = existingDistance(rep, p), d <= thresholds.sameMax, d < bestD {
                    bestD = d
                    productIndex = i
                }
            }
            if productIndex == nil {
                let id = naming.newProductId()
                let product = ShelfProduct(
                    id: id, name: naming.productName(out.products.count + 1), createdAt: now,
                    imageFileNames: [], embeddings: [], colorDescriptors: [], similarProductIds: [],
                    needsReview: group.candidateIndices.contains { candidates[$0].needsReview },
                    reviewReasons: []
                )
                out.products.append(product)
                productIndex = out.products.count - 1
                summary.newProducts += 1
            }
            let pi = productIndex!
            let productId = out.products[pi].id
            groupProductIds[gi] = productId
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
                    out.products[index].needsReview = true
                    if !out.products[index].reviewReasons.contains(note) { out.products[index].reviewReasons.append(note) }
                }
            }
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
