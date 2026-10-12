import Foundation

// Image-feature distances and the product search decision. Pure Swift: the embedding itself is produced elsewhere
// (Vision feature print on device); everything here works on plain float vectors so it is tested without a device.
//
// IMPORTANT: every threshold below is an UNCALIBRATED default. They must be measured on real packaging with the real
// embedder (see StoreThresholdCalibrator) before a result is trusted; the app labels results accordingly.

enum StoreVectorMath {
    static func norm(_ a: [Float]) -> Float {
        var s: Float = 0
        for v in a { s += v * v }
        return s.squareRoot()
    }

    static func l2Normalized(_ a: [Float]) -> [Float] {
        let n = norm(a)
        guard n > 1e-12 else { return a }
        return a.map { $0 / n }
    }

    /// 1 - cosine similarity, in [0, 2]. nil for empty / mismatched / zero vectors.
    static func cosineDistance(_ a: [Float], _ b: [Float]) -> Float? {
        guard !a.isEmpty, a.count == b.count else { return nil }
        var dot: Float = 0, na: Float = 0, nb: Float = 0
        for i in 0..<a.count {
            dot += a[i] * b[i]
            na += a[i] * a[i]
            nb += b[i] * b[i]
        }
        guard na > 1e-12, nb > 1e-12 else { return nil }
        return 1 - dot / (na.squareRoot() * nb.squareRoot())
    }

    /// Half the L1 distance of two L1-normalised histograms, in [0, 1].
    static func histogramDistance(_ a: [Float], _ b: [Float]) -> Float? {
        guard !a.isEmpty, a.count == b.count else { return nil }
        var s: Float = 0
        for i in 0..<a.count { s += abs(a[i] - b[i]) }
        return s / 2
    }
}

/// Appearance of one product crop: the feature-print vector plus a small colour histogram (flavour variants are often
/// told apart by colour while a generic image embedding barely changes).
struct ShelfAppearance: Equatable, Sendable {
    var embedding: [Float]
    var color: [Float]

    static let featureWeight: Float = 0.75
    static let colorWeight: Float = 0.25

    /// Combined distance; nil when no usable component exists. Falls back to the component that both sides have.
    func distance(to other: ShelfAppearance) -> Float? {
        let f = StoreVectorMath.cosineDistance(embedding, other.embedding).map { min($0, 1) }
        let c = StoreVectorMath.histogramDistance(color, other.color)
        switch (f, c) {
        case let (f?, c?): return Self.featureWeight * f + Self.colorWeight * c
        case let (f?, nil): return f
        case let (nil, c?): return c
        default: return nil
        }
    }
}

struct ShelfMatchConfig: Equatable, Sendable {
    /// At or below this distance a single clear winner is a match.
    var matchMax: Float = 0.22
    /// Above this the query is treated as an unregistered product.
    var uncertainMax: Float = 0.42
    /// The runner-up (a DIFFERENT product) must be at least this much farther than the winner.
    var minMargin: Float = 0.04
    var maxCandidates: Int = 3
    /// Candidates listed for an uncertain result must be within this of the best.
    var candidateBand: Float = 0.12
    static let uncalibrated = ShelfMatchConfig()
}

struct ShelfMatchCandidate: Codable, Equatable, Sendable {
    var productId: String
    var distance: Float
}

enum ShelfMatchOutcome: Equatable, Sendable {
    case matched(ShelfMatchCandidate)
    case uncertain([ShelfMatchCandidate])
    case unregistered(bestDistance: Float?)
    /// No registered product has a usable appearance: nothing to compare with.
    case noGallery

    /// Stable key for the stabiliser: the decision, ignoring the distance values.
    var key: String {
        switch self {
        case .matched(let c): return "m:" + c.productId
        case .uncertain(let cs): return "u:" + cs.map(\.productId).sorted().joined(separator: ",")
        case .unregistered: return "x"
        case .noGallery: return "g"
        }
    }
}

enum ShelfProductMatcher {
    /// Every product with its best image distance, closest first (diagnostics: shows how far the runner-up was).
    static func ranking(query: ShelfAppearance, gallery: [(productId: String, appearances: [ShelfAppearance])]) -> [ShelfMatchCandidate] {
        var scored: [ShelfMatchCandidate] = []
        for entry in gallery {
            let ds = entry.appearances.compactMap { query.distance(to: $0) }
            if let best = ds.min() { scored.append(ShelfMatchCandidate(productId: entry.productId, distance: best)) }
        }
        return scored.sorted { $0.distance < $1.distance }
    }

    /// `gallery`: per product, all stored appearances. The product distance is the best (smallest) of its appearances.
    static func match(query: ShelfAppearance, gallery: [(productId: String, appearances: [ShelfAppearance])],
                      config: ShelfMatchConfig = .uncalibrated) -> ShelfMatchOutcome {
        var scored: [ShelfMatchCandidate] = []
        for entry in gallery {
            let ds = entry.appearances.compactMap { query.distance(to: $0) }
            if let best = ds.min() { scored.append(ShelfMatchCandidate(productId: entry.productId, distance: best)) }
        }
        guard !scored.isEmpty else { return .noGallery }
        scored.sort { $0.distance < $1.distance }
        let best = scored[0]
        let runnerUp = scored.count > 1 ? scored[1].distance : Float.infinity
        if best.distance <= config.matchMax, runnerUp - best.distance >= config.minMargin {
            return .matched(best)
        }
        if best.distance <= config.uncertainMax {
            let list = scored.filter { $0.distance <= config.uncertainMax && $0.distance <= best.distance + config.candidateBand }
            return .uncertain(Array(list.prefix(config.maxCandidates)))
        }
        return .unregistered(bestDistance: best.distance)
    }
}

/// Requires the same decision in `required` of the last `window` frames before it is shown, so one lucky frame does not
/// flip the result. A different decision resets nothing by itself: it simply needs its own majority.
struct ShelfMatchStabilizer {
    let window: Int
    let required: Int
    private(set) var recent: [ShelfMatchOutcome] = []

    init(window: Int = 5, required: Int = 3) {
        self.window = max(1, window)
        self.required = min(max(1, required), max(1, window))
    }

    mutating func add(_ outcome: ShelfMatchOutcome) {
        recent.append(outcome)
        if recent.count > window { recent.removeFirst(recent.count - window) }
    }

    mutating func reset() { recent = [] }

    /// The decision with at least `required` votes, the most recent such one if several.
    var stable: ShelfMatchOutcome? {
        var counts: [String: Int] = [:]
        for o in recent { counts[o.key, default: 0] += 1 }
        for o in recent.reversed() where (counts[o.key] ?? 0) >= required { return o }
        return nil
    }
}

/// Chooses which placement to guide to when a product stands in several places.
enum ShelfPlacementChooser {
    /// Nearest `present` placement to the camera; if none is present, the nearest of the others (callers show it as
    /// "마지막 확인 위치" with its time, never as current stock).
    static func nearest(_ placements: [ShelfPlacement], to camera: Vec3, transform: Rigid = .identity) -> ShelfPlacement? {
        func d(_ p: ShelfPlacement) -> Float { transform.apply(point: p.world).distance(to: camera) }
        let present = placements.filter { $0.status == .present }
        let pool = present.isEmpty ? placements : present
        return pool.min { d($0) < d($1) }
    }
}

/// Derives thresholds from measured distances. Same-product pairs (different views of one product) and different-product
/// pairs (including look-alike variants) are measured separately; the result is only as good as that data.
enum StoreThresholdCalibrator {
    struct Result: Equatable, Sendable {
        var matchMax: Float
        var uncertainMax: Float
        /// Share of same-product pairs at or below `matchMax` / of different-product pairs above `uncertainMax`.
        var sameRecall: Float
        var differentRejection: Float
        var separable: Bool
    }

    static func calibrate(same: [Float], different: [Float]) -> Result? {
        guard same.count >= 5, different.count >= 5 else { return nil }
        let s = same.sorted(), d = different.sorted()
        func q(_ a: [Float], _ p: Float) -> Float { a[min(a.count - 1, Int(Float(a.count - 1) * p))] }
        let matchMax = q(s, 0.90)             // 90 % of same-product pairs
        let uncertainMax = q(d, 0.05)         // only 5 % of different-product pairs fall below this
        let separable = matchMax < uncertainMax
        let recall = Float(s.filter { $0 <= matchMax }.count) / Float(s.count)
        let rejection = Float(d.filter { $0 > uncertainMax }.count) / Float(d.count)
        return Result(matchMax: matchMax, uncertainMax: max(uncertainMax, matchMax), sameRecall: recall,
                      differentRejection: rejection, separable: separable)
    }
}
