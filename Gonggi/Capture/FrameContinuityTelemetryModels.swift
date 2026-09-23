import Foundation
import simd

/// Observe-only feature continuity telemetry for TestFlight 2.0(65).
/// Does **not** feed CaptureBridgeSession decisions or thresholds.
enum FrameContinuityTelemetryConfig {
    static let schemaVersion = 1
    /// Shipped dual-anchor policy id (default capture path).
    static let policyVersion = "capture_bridge_dual_anchor_v1"
    /// Active id written into telemetry — switches only when pending-angular-rescue candidate is ON.
    static var activePolicyVersion: String {
        PendingAngularRescuePolicy.isEnabled
            ? PendingAngularRescuePolicy.policyVersion
            : policyVersion
    }
    /// Fixed grid for occupancy histogram (recorded in schema).
    static let gridRows = 3
    static let gridCols = 3
    /// Cap retained identifier sets (comparison only).
    static let maxRetainedIdentifiers = 4_096
    /// Soft cap on downsampled *stable* records retained in memory / package JSON.
    /// Transition / anchor-update records are retained permanently (separate buffer).
    static let maxInMemoryRecords = 2_500
    /// Keep at most this many permanent transition records (accept/bridge/reacquire/reason/anchor).
    static let maxPermanentTransitionRecords = 4_000
    /// Downsample every N-th stable record when over soft cap.
    static let stableDownsampleStride = 8
    /// Measured via `JSONEncoder` with `[.prettyPrinted, .sortedKeys]` (package root encoding).
    /// Compact/JSONL is much smaller; do not use for archive size planning alone.
    /// Updated from synthetic XCTest measurement — not a hard cap.
    static let approximateBytesPerPrettyPrintedRecord = 1_750
    static let fileName = "frame_continuity_telemetry.json"
    static let debugJSONLFileName = "frame_continuity_telemetry.jsonl"
}

enum FeatureTelemetryUnavailableReason: String, Codable, Equatable, Sendable {
    case none
    case pointCloudNil
    case identifiersUnsupported
    case projectionFailed
    case encodingFailed
    case samplingSkipped
}

struct FeatureGridOccupancy: Codable, Equatable, Sendable {
    var rows: Int
    var cols: Int
    /// Row-major cell counts (length = rows*cols).
    var cellCounts: [Int]
    var occupiedCellCount: Int
    var totalInBoundsPoints: Int
    /// Max cell share of in-bounds points (0…1); concentration signal.
    var maxCellFraction: Double
}

struct PersistentFeatureStats: Codable, Equatable, Sendable {
    var previousFramePersistentCount: Int?
    var previousFramePersistentRatio: Double?
    var continuityAnchorPersistentCount: Int?
    var continuityAnchorPersistentRatio: Double?
    var unavailableReason: FeatureTelemetryUnavailableReason
}

struct ARKitFeatureSummary: Codable, Equatable, Sendable {
    var rawFeaturePointCount: Int?
    var grid: FeatureGridOccupancy?
    var persistent: PersistentFeatureStats
    var trackingState: String
    var trackingLimitationReason: String?
    var unavailableReason: FeatureTelemetryUnavailableReason
}

struct DualAnchorTelemetrySnapshot: Codable, Equatable, Sendable {
    var continuityTranslationM: Float?
    var continuityYawDeg: Double?
    var continuityForwardAngleDeg: Double?
    var reconstructionCumulativeTranslationM: Float?
    var frustumOverlap: Double?
    var reconstructionCoverageEstimate: Double?
    var bridgeMode: String?
    var verdict: String?
    var reason: String?
    var acceptKind: String?
}

struct FrameContinuityTelemetryRecord: Codable, Equatable, Sendable {
    var schemaVersion: Int
    var policyVersion: String
    var candidateSequence: Int
    var arTimestampSeconds: Double
    /// ARFrame.timestamp of the evaluated candidate. Also filled for rejected candidates
    /// (not only accepted JPEG rows). Prefer this over assuming image sync to MOV PTS.
    var imageTimestampSeconds: Double?
    var frameId: String?
    /// **Enqueue reservation**, not durable JPEG write.
    /// `true` means the selector accepted and JPEG encode was successfully *enqueued*
    /// (frameId reserved). The file may still fail later on the encode queue.
    /// Durable keyframe for analysis = `jpegEnqueueSucceeded == true` (or `committed`)
    /// AND `frameId != nil` AND `durableJPEGPresent == true` (package finalize).
    var committed: Bool
    /// Explicit alias of enqueue success (same value as `committed` when written by collector).
    var jpegEnqueueSucceeded: Bool? = nil
    /// Set at package build time when `frames/{frameId}.jpg` exists on disk; nil in live records.
    var durableJPEGPresent: Bool? = nil
    var features: ARKitFeatureSummary
    var sharpnessScore: Double?
    var sharpnessState: String?
    var brightness: Double?
    var lowTextureScore: Double?
    var overlapScore: Double?
    var dualAnchor: DualAnchorTelemetrySnapshot
}

struct FrameContinuityTelemetryFile: Codable, Equatable, Sendable {
    var schemaVersion: Int
    var policyVersion: String
    var gridRows: Int
    var gridCols: Int
    var recordCount: Int
    var approximateBytesPerRecordEstimate: Int
    var records: [FrameContinuityTelemetryRecord]
}

/// Pure grid projection for tests (no ARFrame retention).
enum FeatureGridProjector {
    static func occupancy(
        worldPoints: [SIMD3<Float>],
        worldToCamera: simd_float4x4,
        fx: Float,
        fy: Float,
        cx: Float,
        cy: Float,
        imageWidth: Float,
        imageHeight: Float,
        rows: Int = FrameContinuityTelemetryConfig.gridRows,
        cols: Int = FrameContinuityTelemetryConfig.gridCols
    ) -> FeatureGridOccupancy? {
        guard imageWidth > 1, imageHeight > 1, rows > 0, cols > 0 else { return nil }
        var cells = Array(repeating: 0, count: rows * cols)
        var inBounds = 0
        for wp in worldPoints {
            let cam = worldToCamera * SIMD4<Float>(wp.x, wp.y, wp.z, 1)
            guard cam.z < -1e-4 else { continue }
            let u = fx * (cam.x / -cam.z) + cx
            let v = fy * (cam.y / -cam.z) + cy
            guard u >= 0, v >= 0, u < imageWidth, v < imageHeight else { continue }
            inBounds += 1
            let col = min(cols - 1, max(0, Int((u / imageWidth) * Float(cols))))
            let row = min(rows - 1, max(0, Int((v / imageHeight) * Float(rows))))
            cells[row * cols + col] += 1
        }
        let occupied = cells.reduce(0) { $0 + ($1 > 0 ? 1 : 0) }
        let maxCell = cells.max() ?? 0
        let maxFrac = inBounds == 0 ? 0.0 : Double(maxCell) / Double(inBounds)
        return FeatureGridOccupancy(
            rows: rows,
            cols: cols,
            cellCounts: cells,
            occupiedCellCount: occupied,
            totalInBoundsPoints: inBounds,
            maxCellFraction: maxFrac
        )
    }
}
