import Foundation

// A diagnostics bundle describes ONE recording pass or ONE search session precisely enough to re-run the tracking and
// grouping stages offline and to see at which stage a physical product was split. It is created only when the person
// exports it. Pure Swift (Linux-testable); image files are referenced by name and live next to session.json.
//
// Coordinate conventions (also written into every bundle):
//  - `frames[].imageFile` is the camera frame in SENSOR orientation (landscape, not rotated), scaled by `imageScale`.
//  - Region rectangles are in FULL sensor pixels (u right, v down, origin top-left of the sensor buffer).
//  - Product crops (`crops/…`) and OCR crops are UPRIGHT (the sensor rotated 90 degrees clockwise: portrait).
//  - `camera.cameraToWorld` is a column-major 4x4 camera-to-world matrix (ARKit: +Y up, camera looks down -Z).
//  - Plane: `origin`, `uAxis` (along the shelf, left to right as a customer sees it), `normal` (towards the customer);
//    v is world up. Shelf coordinates u, v are metres from `origin`.

struct StoreDiagRegion: Codable, Equatable, Sendable {
    var index: Int
    /// "rectangle" or "instance" (the detector that proposed it).
    var source: String
    var score: Float
    var minU: Float
    var minV: Float
    var maxU: Float
    var maxV: Float
    /// A shelf position could be estimated (distance evidence existed).
    var placed: Bool
    var u: Float?
    var v: Float?
    var distance: Float?
    var cosIncidence: Float?
    var widthM: Float?
    var heightM: Float?
    var aspect: Float?
    var lumaStd: Float?
    var clipped: Bool?
    /// "accept" or the rejection reason of the structural filter ("tooSmallPhysically", "flatTexture", ...).
    var verdict: String?
    /// "kept", "container", "part", "notProduct" (filtered), "unplaced" or "notFeatured".
    var arbiter: String
    /// Observation created from this region (the crop reference), if any.
    var observationRef: String?
}

struct StoreDiagFrame: Codable, Equatable, Sendable {
    var index: Int
    var time: Double
    var imageFile: String?
    /// Exported image pixels per sensor pixel (<= 1).
    var imageScale: Float
    var sensorWidth: Int
    var sensorHeight: Int
    var camera: StoreCameraModel
    var regions: [StoreDiagRegion]
}

struct StoreDiagObservation: Codable, Equatable, Sendable {
    var ref: String
    var frameIndex: Int
    var regionIndex: Int
    var time: Double
    var u: Float
    var v: Float
    var world: Vec3
    var uncertaintyM: Float
    var widthM: Float
    var heightM: Float
    var sharpness: Float
    var completeness: Float
    var viewTanU: Float?
    var viewTanV: Float?
    var rayPerDepth: Vec3?
    var embedding: StoreVector
    var color: [Float]
    var texts: [ShelfTextLine]
    var barcodes: [String]
    var cropFile: String?
    var ocrImageFile: String?
}

struct StoreDiagCandidate: Codable, Equatable, Sendable {
    var index: Int
    var u: Float
    var v: Float
    var widthM: Float
    var heightM: Float
    var uncertaintyM: Float
    var depthBehindPlaneM: Float?
    var observationRefs: [String]
    var clusterIds: [Int]
    var name: ShelfExtractedName?
    var productId: String?
    var cropRefs: [String]
    var needsReview: Bool
    var reviewReasons: [String]
}

struct StoreDiagProduct: Codable, Equatable, Sendable {
    var id: String
    var name: String
    var nameSource: String?
    var needsReview: Bool
    var reviewReasons: [String]
    var candidateIndices: [Int]
    var placementIds: [String]
    var imageFileNames: [String]
}

struct StoreDiagSettings: Codable, Equatable, Sendable {
    var sameAppearanceMax: Float
    var posRadiusFloor: Float
    var posRadiusFactor: Float
    var maxDepthBehindPlaneM: Float
    var minTangentSpread: Float
    var minObservations: Int
    var minSharpness: Float
    var groupSameMax: Float
    var groupSimilarMax: Float
    var minWidthM: Float
    var maxWidthM: Float
    var minHeightM: Float
    var maxHeightM: Float
    var maxAspect: Float
    var minLumaStd: Float
}

struct StoreDiagSearchEvent: Codable, Equatable, Sendable {
    /// Seconds since the search started.
    var t: Double
    /// "start", "aligned", "firstProduct", "candidates", "unregistered", "locked", "guidance", "released", "cleared".
    var kind: String
    var productId: String?
    var detail: String?
}

struct StoreDiagSearchFrame: Codable, Equatable, Sendable {
    var frameIndex: Int
    var t: Double
    /// Top ranked products by image distance (all ranked, best first, at most 5).
    var ranking: [ShelfMatchCandidate]
    var outcome: String
    var readLines: [String]
    var analysisSeconds: Double
    var chosenRegionIndex: Int?
    /// Upright crop that was compared with the gallery ("crops/s0007.jpg").
    var cropFile: String?
}

struct StoreDiagBundle: Codable, Equatable, Sendable {
    static let currentSchema = 1

    var schema = StoreDiagBundle.currentSchema
    /// "record" or "search".
    var kind: String
    var createdAt: Date
    var appVersion: String
    var appBuild: String
    var device: String
    var osVersion: String
    var storeId: String
    var ocrSummary: String
    var conventions: [String] = []
    var plane: ShelfPlane?
    var settings: StoreDiagSettings?
    var counters: StoreRecordingDiagnostics?
    var frames: [StoreDiagFrame] = []
    var observations: [StoreDiagObservation] = []
    var associations: [ShelfAssociationTrace] = []
    var merges: [ShelfClusterMerge] = []
    var candidates: [StoreDiagCandidate] = []
    var products: [StoreDiagProduct] = []
    /// Names typed or confirmed by the person during review (product id -> name), so replays keep them.
    var reviewedNames: [String: String] = [:]
    var searchFrames: [StoreDiagSearchFrame] = []
    var searchEvents: [StoreDiagSearchEvent] = []

    static let defaultConventions = [
        "frames[].imageFile: sensor orientation (landscape, not rotated), scaled by imageScale",
        "regions rect: full sensor pixels, u right, v down, origin top-left",
        "crops and OCR crops: upright (sensor rotated 90 degrees clockwise)",
        "camera.cameraToWorld: column-major 4x4, ARKit world (+Y up), camera looks down -Z",
        "plane: origin, uAxis (left to right for the customer), normal (towards the customer), v = world up",
    ]
}

/// Offline replay of the tracking, merging and grouping stages from a bundle: rebuilds the observations and runs the
/// CURRENT code, so a change can be compared against what the device decided at recording time.
enum StoreDiagReplay {
    struct Outcome: Equatable, Sendable {
        var candidates: [ShelfCandidate]
        var result: ShelfAggregationResult
        var groups: [ShelfProductGroup]
        /// Group index of every candidate.
        var groupOfCandidate: [Int]
        var traces: [ShelfAssociationTrace]
    }

    static func observations(_ b: StoreDiagBundle) -> [ShelfObservation] {
        b.observations.sorted { ($0.frameIndex, $0.regionIndex) < ($1.frameIndex, $1.regionIndex) }.map { o in
            var x = ShelfObservation(time: o.time, u: o.u, v: o.v, world: o.world, uncertaintyM: o.uncertaintyM, widthM: o.widthM,
                                     heightM: o.heightM, appearance: ShelfAppearance(embedding: o.embedding.values, color: o.color),
                                     sharpness: o.sharpness, cropRef: o.ref)
            x.frameIndex = o.frameIndex
            x.viewTanU = o.viewTanU
            x.viewTanV = o.viewTanV
            x.rayPerDepth = o.rayPerDepth
            x.completeness = o.completeness
            x.texts = o.texts
            x.barcodes = o.barcodes
            return x
        }
    }

    static func replay(_ b: StoreDiagBundle, config: ShelfAggregationConfig = ShelfAggregationConfig(),
                       thresholds: ShelfProductGrouper.Thresholds = ShelfProductGrouper.Thresholds()) -> Outcome {
        var agg = ShelfObservationAggregator(config: config)
        var traces: [ShelfAssociationTrace] = []
        for o in observations(b) { traces.append(agg.add(o)) }
        let result = agg.finalize()
        let groups = ShelfProductGrouper.group(result.candidates, thresholds: thresholds)
        var groupOf = [Int](repeating: -1, count: result.candidates.count)
        for (gi, g) in groups.enumerated() { for ci in g.candidateIndices { groupOf[ci] = gi } }
        return Outcome(candidates: result.candidates, result: result, groups: groups, groupOfCandidate: groupOf, traces: traces)
    }
}

extension StoreDiagBundle {
    static func settings(aggregation a: ShelfAggregationConfig, filter f: ShelfRegionFilterConfig,
                         grouper t: ShelfProductGrouper.Thresholds) -> StoreDiagSettings {
        StoreDiagSettings(sameAppearanceMax: a.sameAppearanceMax, posRadiusFloor: a.posRadiusFloor, posRadiusFactor: a.posRadiusFactor,
                          maxDepthBehindPlaneM: a.maxDepthBehindPlaneM, minTangentSpread: a.minTangentSpread,
                          minObservations: a.minObservations, minSharpness: a.minSharpness, groupSameMax: t.sameMax,
                          groupSimilarMax: t.similarMax, minWidthM: f.minWidthM, maxWidthM: f.maxWidthM, minHeightM: f.minHeightM,
                          maxHeightM: f.maxHeightM, maxAspect: f.maxAspect, minLumaStd: f.minLumaStd)
    }
}
