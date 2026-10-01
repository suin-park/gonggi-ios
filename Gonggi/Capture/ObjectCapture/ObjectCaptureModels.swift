import Foundation
import simd

/// Static 3D asset (physical object) capture: the object stays still, the user walks around it.
/// Worker contract: `object.json` next to the Spatial Capture Package files (schema 1, see
/// workers/video-gaussian/docs/PRODUCT_3DGS_OBJECT_CAPTURE.md in the cloud repo).
enum ObjectCaptureConfig {
    static let objectFileName = "object.json"
    static let schemaVersion = 1
    /// Server profile is picked by the server from `captureKind`; kept here only for diagnostics.
    static let serverCaptureKind = "object"

    /// Orbit grid: azimuth bins around the product × elevation bands (degrees above the horizon, from the box centre).
    static let azimuthBinCount = 24
    static let elevationBands: [ClosedRange<Double>] = [5...25, 25...50, 50...80]
    static let elevationBandNames = ["low", "middle", "high"]

    /// Default box before the user adjusts it (meters). Width, height, depth.
    static let defaultSize = SIMD3<Float>(0.35, 0.35, 0.35)
    static let minSide: Float = 0.05
    static let maxSide: Float = 2.5

    /// Framing: the projected box should fill this share of the photo's short side.
    static let framingMinFill: Double = 0.25
    static let framingMaxFill: Double = 0.85
    /// Box corners must stay this far (share of the short side) inside the photo edge.
    static let framingEdgeMargin: Double = 0.02
    /// Box centre must project inside the central area (share of width / height from the middle).
    static let framingCenterWindow: Double = 0.30

    /// Keyframes: the app's safety cap (same as space capture). Not a target — photo count is measured.
    static let safetyCap = 520
    static let minSaveIntervalSec: Double = 0.25
    /// A new photo in an already-saved cell needs at least this much view change from the last saved photo.
    static let minViewChangeDeg: Double = 4.0
    /// Photos per cell after which a cell counts as covered for guidance.
    static let coveredPhotosPerCell = 2

    /// Box policy written to object.json. `loose_v1`: the box is only a rough selection of the object — the worker
    /// widens it for the final crop and prompts the mask model from its core, and capture judges "in frame" on the box
    /// core. A package without the field (older apps) or with `legacy` keeps the previous exact-box behaviour.
    static let boxPolicyLoose = "loose_v1"
    static let boxPolicyLegacy = "legacy"
    /// Core of the box (share of its size about the base centre) that the capture screen judges for "in frame". The
    /// core being in frame is a statement about the box core only — it does not prove the whole object is visible.
    static let coreFramingRatio: Float = 0.8
    /// The loose box (this policy) is an internal-test switch in the sizing panel. It stays OFF by default until the
    /// worker that understands `loose_v1` is live on the product endpoint: an older worker would judge a loose box by the
    /// exact-box rules (e.g. "object truncated" when the box sticks out of the photos). Off = build 88 behaviour exactly.
    static let looseBoxDefaultsKey = "com.whik.gonggi.objectCapture.looseBox"
    static let looseBoxDefaultOn = false

    /// Product-extent evidence (Vision foreground mask): lets a photo be saved when the generous box sticks out of the
    /// photo but the whole product is inside it. Off until the offline validation has passed against the criteria that
    /// were fixed before it ran (docs/OBJECT_VISION_VALIDATION_CRITERIA.md). When off, nothing in capture changes.
    static let productEvidenceEnabled = false
    /// At most one product analysis per this interval, and only one at a time; it never blocks the AR view or saving.
    static let evidenceMinIntervalSec: Double = 0.2
    /// Analysis input: the long edge of the photo copy handed to Vision.
    static let evidenceLongEdgePx = 640
}

/// Oriented product box in the ARKit world (gravity +Y, meters).
struct ObjectCaptureBox: Equatable, Codable {
    /// Centre of the box bottom face, on the support surface.
    var baseCenter: SIMD3<Float>
    /// Width (box x), height (up), depth (box z).
    var size: SIMD3<Float>
    /// Rotation about +Y (radians).
    var yawRadians: Float

    var center: SIMD3<Float> { baseCenter + SIMD3<Float>(0, size.y / 2, 0) }

    /// Columns: box x, up, box z in world coordinates (rotation about +Y, same convention as the worker).
    var axes: simd_float3x3 {
        let c = cos(yawRadians), s = sin(yawRadians)
        return simd_float3x3(columns: (
            SIMD3<Float>(c, 0, -s),
            SIMD3<Float>(0, 1, 0),
            SIMD3<Float>(s, 0, c)
        ))
    }

    var radius: Float { simd_length(size / 2) }

    /// Same base point and turn, every side x `ratio` (the box stays on the support surface).
    func scaled(_ ratio: Float) -> ObjectCaptureBox {
        ObjectCaptureBox(baseCenter: baseCenter, size: size * ratio, yawRadians: yawRadians)
    }

    var corners: [SIMD3<Float>] {
        var out: [SIMD3<Float>] = []
        let h = size / 2
        for sx: Float in [-1, 1] {
            for sy: Float in [-1, 1] {
                for sz: Float in [-1, 1] {
                    out.append(center + axes * SIMD3<Float>(sx * h.x, sy * h.y, sz * h.z))
                }
            }
        }
        return out
    }

    /// Box edges as corner index pairs (for drawing the wireframe).
    static let edgeIndexPairs: [(Int, Int)] = [
        (0, 1), (2, 3), (4, 5), (6, 7), // along z
        (0, 2), (1, 3), (4, 6), (5, 7), // along y
        (0, 4), (1, 5), (2, 6), (3, 7), // along x
    ]

    func clamped() -> ObjectCaptureBox {
        var b = self
        b.size = simd_clamp(size, SIMD3(repeating: ObjectCaptureConfig.minSide), SIMD3(repeating: ObjectCaptureConfig.maxSide))
        return b
    }
}

// MARK: - object.json

struct ObjectCaptureFile: Codable, Equatable {
    struct ObjectSection: Codable, Equatable {
        var baseCenter: [Float]
        var size: [Float]
        var yawRadians: Float
        /// raycast_existing_plane | raycast_estimated_plane
        var centerSource: String
        /// user_adjusted | default
        var sizeSource: String
        /// loose_v1 | legacy (nil in files written by older apps = legacy)
        var boxPolicy: String?
    }

    struct Coverage: Codable, Equatable {
        var azimuthBins: Int
        var elevationBandsDeg: [[Double]]
        /// counts[band][azimuthBin] = saved photos
        var counts: [[Int]]
        var coveredCells: Int
        var totalCells: Int
    }

    struct Frame: Codable, Equatable {
        var frameId: String
        var azimuthDeg: Double
        var elevationDeg: Double
        var distanceM: Double
        var framing: String
        /// What `framing` was judged on: "box" or "core0.80" (nil in older files = box).
        var framingBasis: String?
        /// Projected box centre in sensor pixels at the moment of saving (AR-drift review).
        var boxCenterPx: [Float]?
        /// ARKit tracking reason when not normal, else "normal".
        var trackingReason: String?
        /// ARFrame.worldMappingStatus name.
        var mapping: String?
        /// Raycast support-plane height under the box minus the recorded box base height, metres (nil = no plane hit).
        var baseHeightDeltaM: Float?
    }

    /// Records to tell AR drift from depth ambiguity after the fact (see ObjectARDiagnostics). Not read by the worker.
    struct Diagnostics: Codable, Equatable {
        struct Event: Codable, Equatable {
            var tSec: Double
            var tracking: String
            var mapping: String
        }
        var schema: Int
        var events: [Event]
        var relocalizationCount: Int
        var planeAnchorUpdates: Int
        var limitedFrameShare: Double
        var framesSeen: Int
    }

    struct Device: Codable, Equatable {
        var hasLiDAR: Bool
    }

    var schemaVersion: Int
    var captureKind: String
    var coordinateConvention: String
    var object: ObjectSection
    /// Declared at start (first product-capture scope: matte and rigid only).
    var material: String
    var coverage: Coverage
    var frames: [Frame]
    var device: Device
    var diagnostics: Diagnostics?

    static func make(
        box: ObjectCaptureBox,
        centerSource: String,
        sizeSource: String,
        coverage: ObjectOrbitCoverage,
        frames: [Frame],
        hasLiDAR: Bool,
        boxPolicy: String? = nil,
        diagnostics: Diagnostics? = nil
    ) -> ObjectCaptureFile {
        ObjectCaptureFile(
            schemaVersion: ObjectCaptureConfig.schemaVersion,
            captureKind: ObjectCaptureConfig.serverCaptureKind,
            coordinateConvention: "arkit_world_y_up_meters",
            object: ObjectSection(
                baseCenter: [box.baseCenter.x, box.baseCenter.y, box.baseCenter.z],
                size: [box.size.x, box.size.y, box.size.z],
                yawRadians: box.yawRadians,
                centerSource: centerSource,
                sizeSource: sizeSource,
                boxPolicy: boxPolicy
            ),
            material: "matte_rigid",
            coverage: Coverage(
                azimuthBins: ObjectCaptureConfig.azimuthBinCount,
                elevationBandsDeg: ObjectCaptureConfig.elevationBands.map { [$0.lowerBound, $0.upperBound] },
                counts: coverage.counts,
                coveredCells: coverage.coveredCellCount,
                totalCells: coverage.totalCellCount
            ),
            frames: frames,
            device: Device(hasLiDAR: hasLiDAR),
            diagnostics: diagnostics
        )
    }

    func write(to packageRoot: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(
            to: packageRoot.appendingPathComponent(ObjectCaptureConfig.objectFileName),
            options: [.atomic]
        )
    }
}

/// What can be captured as a 3D asset. Only still objects are supported in this version; people and pets are listed
/// so the entry screen and the stored data can grow without a rename, but nothing starts a capture for them.
enum ObjectCaptureSubject: String, CaseIterable {
    case stillObject = "still_object"
    case person
    case pet

    var isSupported: Bool { self == .stillObject }
    /// The subject's own line on the start screen; unsupported subjects say so plainly.
    var startLine: String {
        switch self {
        case .stillObject: return "움직이지 않는 물체만 만들 수 있어요"
        case .person, .pet: return "사람과 반려동물은 아직 지원하지 않아요"
        }
    }
}

extension SpaceRecord {
    /// Product 3D capture result: filed under 보관함 › 3D 자산, not 공간.
    var isProductResult: Bool { sourceKind == ObjectCapturePackage.librarySourceKind }
}

enum ObjectCapturePackage {
    /// Library `SpaceRecord.sourceKind` of a physical product result (walkable spaces stay "gaussian_spatial").
    static let librarySourceKind = "gaussian_object"

    /// True when the package root carries `object.json` (product capture). Upload and recovery paths use this to
    /// send `captureKind: object`, so an unsent product capture is never retried as a space.
    static func isObjectPackage(root: URL?) -> Bool {
        guard let root else { return false }
        return FileManager.default.fileExists(atPath: root.appendingPathComponent(ObjectCaptureConfig.objectFileName).path)
    }
}
