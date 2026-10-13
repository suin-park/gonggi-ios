import Foundation

// Persisted data of one store: shelves, products, their placements, the walked trail and reference signs.
// All coordinates are in the coordinate frame of the saved ARWorldMap of that store ("saved world"). When a session
// is aligned, `StoreSpaceAlignment` supplies the transform from the saved world to the live session world.

/// A Float32 vector stored as base64 (embeddings are 768 floats; JSON arrays of that size are wasteful).
struct StoreVector: Codable, Equatable, Sendable {
    var base64: String

    init(base64: String) {
        self.base64 = base64
    }

    init(_ values: [Float]) {
        var data = Data(capacity: values.count * 4)
        for v in values {
            var bits = v.bitPattern.littleEndian
            withUnsafeBytes(of: &bits) { data.append(contentsOf: $0) }
        }
        base64 = data.base64EncodedString()
    }

    var values: [Float] {
        guard let data = Data(base64Encoded: base64), data.count % 4 == 0 else { return [] }
        var out = [Float]()
        out.reserveCapacity(data.count / 4)
        data.withUnsafeBytes { raw in
            for i in stride(from: 0, to: data.count, by: 4) {
                let bits = raw.loadUnaligned(fromByteOffset: i, as: UInt32.self)
                out.append(Float(bitPattern: UInt32(littleEndian: bits)))
            }
        }
        return out
    }
}

enum ShelfPlacementStatus: String, Codable, Sendable {
    /// Seen on the most recent recording that covered this area.
    case present
    /// A later recording covered this area and did not see it. Kept (never deleted automatically): it may have moved.
    case notObservedOnRescan
}

struct ShelfLayout: Codable, Equatable, Identifiable, Sendable {
    var id: String
    var name: String
    var plane: ShelfPlane
    /// Heights (v, metres above the baseline) that separate the shelf levels, ascending. n boundaries = n + 1 levels.
    var tierBoundaries: [Float]
    var createdAt: Date
    var updatedAt: Date
    /// A photo of the shelf, shown when the space cannot be restored.
    var photoFileName: String?
    /// How well the position of the shelf in space is known: "confirmed", "needs_confirmation" or "unknown" (nil on
    /// data recorded before shelves were measured automatically: those positions were set by hand).
    var locationStatus: String? = nil
    /// When the shelf was last seen in a capture.
    var lastObservedAt: Date? = nil

    /// A shelf whose position is not known is never a guidance destination.
    var isGuidable: Bool { locationStatus != "unknown" }

    func tier(forV v: Float) -> Int {
        tierBoundaries.filter { $0 <= v }.count
    }

    /// 1-based, counted from the bottom, for display.
    func tierLabel(forV v: Float) -> String { "\(tier(forV: v) + 1)번째 칸" }
}

struct ShelfProduct: Codable, Equatable, Identifiable, Sendable {
    var id: String
    var name: String
    var createdAt: Date
    /// Crops of this product (best first), file names under the store's images folder.
    var imageFileNames: [String]
    var embeddings: [StoreVector]
    var colorDescriptors: [StoreVector]
    /// Products whose look is close but not the same (other flavour / size): confirmed or kept apart in review.
    var similarProductIds: [String]
    var needsReview: Bool
    var reviewReasons: [String]
    /// Where the name came from: "auto" (read from the package), "manual" (typed by a person), "catalog" (verified
    /// catalogue product). nil on data saved before names were read automatically.
    var nameSource: String? = nil
    var nameConfidence: Float? = nil
    var brand: String? = nil
    var variantText: String? = nil
    var volumeText: String? = nil
    /// Normalised text read on the package (name search and text-assisted recognition).
    var ocrTokens: [String]? = nil
    var barcodes: [String]? = nil
}

struct ShelfPlacement: Codable, Equatable, Identifiable, Sendable {
    var id: String
    var productId: String
    var shelfId: String
    var u: Float
    var v: Float
    var tier: Int
    var world: Vec3
    var widthM: Float
    var heightM: Float
    var uncertaintyM: Float
    var observationCount: Int
    var firstObservedAt: Date
    var lastObservedAt: Date
    var status: ShelfPlacementStatus
    var needsReview: Bool
    /// Units visible when it was photographed (not stock). nil: not counted.
    var visibleCount: Int? = nil
    /// "counted", "lower_bound" or "cannot_count".
    var countBasis: String? = nil
}

struct ShelfWalkSample: Codable, Equatable, Sendable {
    var x: Float
    var y: Float
    var z: Float
    var time: Double
}

/// A fixed sign or similar structure photographed as a second way to align the space.
struct ShelfReferenceSign: Codable, Equatable, Identifiable, Sendable {
    var id: String
    var name: String
    var imageFileName: String
    var physicalWidthM: Float
    /// Pose of the sign in the saved world, measured while it was tracked during recording.
    var savedPose: Rigid?
}

struct StoreShelfData: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 1

    var schemaVersion: Int = StoreShelfData.currentSchemaVersion
    var storeId: String
    var shelves: [ShelfLayout] = []
    var products: [ShelfProduct] = []
    var placements: [ShelfPlacement] = []
    var walkTrail: [ShelfWalkSample] = []
    var referenceSigns: [ShelfReferenceSign] = []
    /// Floor height (world Y) used to draw the path; nil when it could not be estimated.
    var floorY: Float?
    var updatedAt: Date = Date()

    static func empty(storeId: String) -> StoreShelfData { StoreShelfData(storeId: storeId) }

    func product(_ id: String) -> ShelfProduct? { products.first { $0.id == id } }
    func shelf(_ id: String) -> ShelfLayout? { shelves.first { $0.id == id } }
    func placements(ofProduct id: String) -> [ShelfPlacement] { placements.filter { $0.productId == id } }
}

extension StoreShelfData {
    /// The same store data expressed in another world frame (saved world -> live world). Plane-relative numbers (u, v,
    /// tier) do not change; every world position, plane, trail sample and sign pose does.
    func transformed(by t: Rigid) -> StoreShelfData {
        var out = self
        out.shelves = shelves.map { shelf in
            var s = shelf
            s.plane = shelf.plane.transformed(by: t)
            return s
        }
        out.placements = placements.map { p in
            var q = p
            q.world = t.apply(point: p.world)
            return q
        }
        out.walkTrail = walkTrail.map { w in
            let p = t.apply(point: Vec3(w.x, w.y, w.z))
            return ShelfWalkSample(x: p.x, y: p.y, z: p.z, time: w.time)
        }
        out.referenceSigns = referenceSigns.map { r in
            var q = r
            if let pose = r.savedPose { q.savedPose = t.multiplied(by: pose) }
            return q
        }
        if let f = floorY { out.floorY = t.apply(point: Vec3(0, f, 0)).y }
        return out
    }
}
