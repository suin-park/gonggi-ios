import Foundation
import simd

/// Session-level reconstruction-readiness *observability* metrics.
/// Not wired into `CaptureCompletionGate` — collect first, then choose thresholds.
struct CaptureReconstructionSessionMetrics: Equatable, Sendable {
    /// 12 buckets ≈ 30° each (matches `CaptureMath.viewBucket`).
    static let yawBucketCount = 12

    private(set) var yawBuckets = Set<Int>()
    private(set) var yawRadiansSamples: [Float] = []
    private var startPosition: SIMD3<Float>?
    private var minX: Float?
    private var maxX: Float?
    private var minZ: Float?
    private var maxZ: Float?
    private(set) var maxDistanceFromStartM: Float = 0
    private(set) var firstReadyAtSec: Double?

    mutating func reset() {
        yawBuckets = []
        yawRadiansSamples = []
        startPosition = nil
        minX = nil
        maxX = nil
        minZ = nil
        maxZ = nil
        maxDistanceFromStartM = 0
        firstReadyAtSec = nil
    }

    mutating func ingest(
        transform: simd_float4x4,
        elapsedSec: Double,
        completionState: CaptureCompletionState
    ) {
        let bucket = CaptureMath.viewBucket(for: transform, buckets: Self.yawBucketCount)
        yawBuckets.insert(bucket)

        let f = CaptureMath.forwardVector(from: transform)
        let yaw = atan2(f.x, f.z) // [-π, π]
        yawRadiansSamples.append(yaw)

        let pos = CaptureFrameContract.translation(from: transform)
        if startPosition == nil {
            startPosition = pos
        }
        if let start = startPosition {
            maxDistanceFromStartM = max(maxDistanceFromStartM, simd_distance(start, pos))
        }
        minX = minX.map { min($0, pos.x) } ?? pos.x
        maxX = maxX.map { max($0, pos.x) } ?? pos.x
        minZ = minZ.map { min($0, pos.z) } ?? pos.z
        maxZ = maxZ.map { max($0, pos.z) } ?? pos.z

        if firstReadyAtSec == nil, completionState == .ready {
            firstReadyAtSec = elapsedSec
        }
    }

    func snapshot(
        coverage: CoverageModelV1,
        totalTravelDistanceM: Double,
        meanCellAngleDiversity: Double
    ) -> CaptureReconstructionMetricsSnapshot {
        let counts = coverage.countsByState()
        let visited = coverage.areas.count
        let quality = counts.good + counts.acceptable
        let yawCount = yawBuckets.count
        let span = Self.circularCoveredSpanDegrees(buckets: yawBuckets, bucketCount: Self.yawBucketCount)
        let xzW = Double((maxX ?? 0) - (minX ?? 0))
        let xzD = Double((maxZ ?? 0) - (minZ ?? 0))
        return CaptureReconstructionMetricsSnapshot(
            sessionYawBucketCount: yawCount,
            sessionYawCoverageRatio: Double(yawCount) / Double(Self.yawBucketCount),
            sessionYawMinDeg: span.arcStartDeg,
            sessionYawMaxDeg: span.arcEndDeg,
            sessionYawSpanDeg: span.spanDeg,
            visitedCellCount: visited,
            qualityCellCount: quality,
            acceptableCellCount: counts.acceptable,
            goodCellCount: counts.good,
            insufficientCellCount: counts.insufficient,
            unseenCellCount: counts.unseen,
            xzExtentWidthM: xzW,
            xzExtentDepthM: xzD,
            xzBoundingAreaM2: max(0, xzW * xzD),
            totalTravelDistanceM: totalTravelDistanceM,
            maxDistanceFromStartM: Double(maxDistanceFromStartM),
            sessionViewDirectionBucketCount: yawCount,
            sessionViewDirectionCoverageRatio: Double(yawCount) / Double(Self.yawBucketCount),
            sessionMeanAngleDiversity: meanCellAngleDiversity,
            completionTimeSec: firstReadyAtSec
        )
    }

    /// Covered arc on the yaw circle = 360° − largest empty gap (wrap-aware).
    static func circularCoveredSpanDegrees(
        buckets: Set<Int>,
        bucketCount: Int
    ) -> (spanDeg: Double, arcStartDeg: Double, arcEndDeg: Double) {
        let degPer = 360.0 / Double(bucketCount)
        guard !buckets.isEmpty else {
            return (0, 0, 0)
        }
        if buckets.count >= bucketCount {
            return (360, 0, 360)
        }
        let sorted = buckets.sorted()
        // Gaps between consecutive covered buckets (circular).
        var maxGapBuckets = 0
        var gapAfterIndex = 0 // index in sorted of bucket before the largest gap
        for i in 0..<sorted.count {
            let a = sorted[i]
            let b = sorted[(i + 1) % sorted.count]
            let gap: Int
            if i + 1 < sorted.count {
                gap = b - a - 1
            } else {
                gap = (b + bucketCount) - a - 1
            }
            if gap > maxGapBuckets {
                maxGapBuckets = gap
                gapAfterIndex = i
            }
        }
        let coveredBuckets = bucketCount - maxGapBuckets
        let spanDeg = Double(coveredBuckets) * degPer
        // Arc is everything except the largest empty gap, starting after the gap.
        let startBucket = sorted[(gapAfterIndex + 1) % sorted.count]
        let endBucket = sorted[gapAfterIndex]
        let arcStart = Double(startBucket) * degPer
        let arcEnd = Double(endBucket + 1) * degPer
        return (spanDeg, arcStart, arcEnd.truncatingRemainder(dividingBy: 360))
    }
}

struct CaptureReconstructionMetricsSnapshot: Codable, Equatable, Sendable {
    var sessionYawBucketCount: Int
    var sessionYawCoverageRatio: Double
    /// Start of covered arc (degrees, 0…360), wrap-aware.
    var sessionYawMinDeg: Double
    /// End of covered arc (degrees, 0…360), wrap-aware.
    var sessionYawMaxDeg: Double
    /// Covered yaw arc in degrees (not raw max−min).
    var sessionYawSpanDeg: Double
    var visitedCellCount: Int
    var qualityCellCount: Int
    var acceptableCellCount: Int
    var goodCellCount: Int
    var insufficientCellCount: Int
    var unseenCellCount: Int
    var xzExtentWidthM: Double
    var xzExtentDepthM: Double
    var xzBoundingAreaM2: Double
    var totalTravelDistanceM: Double
    var maxDistanceFromStartM: Double
    var sessionViewDirectionBucketCount: Int
    var sessionViewDirectionCoverageRatio: Double
    var sessionMeanAngleDiversity: Double
    /// Elapsed seconds when completionState first became `.ready` (nil if never).
    var completionTimeSec: Double?
}
