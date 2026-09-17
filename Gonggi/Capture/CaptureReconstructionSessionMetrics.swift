import Foundation
import simd

/// Session-level reconstruction-readiness metrics + sector/ring coverage.
/// Wired into `CaptureCompletionGate` via `CaptureReconstructionReadyConfig` (tunable).
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
    private(set) var firstSoftCompleteAtSec: Double?
    /// Hit counts keyed by "ring|sector".
    private var sectorHits: [String: Int] = [:]
    private(set) var lastRing: CaptureElevationRing?
    private(set) var lastSector: CaptureYawSector?

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
        firstSoftCompleteAtSec = nil
        sectorHits = [:]
        lastRing = nil
        lastSector = nil
    }

    mutating func ingest(
        transform: simd_float4x4,
        elapsedSec: Double,
        completionState: CaptureCompletionState
    ) {
        ingestPose(transform: transform)
        markCompletionTiming(elapsedSec: elapsedSec, completionState: completionState)
    }

    mutating func ingestPose(transform: simd_float4x4) {
        let bucket = CaptureMath.viewBucket(for: transform, buckets: Self.yawBucketCount)
        yawBuckets.insert(bucket)

        let yp = CaptureSectorRingClassifier.yawPitch(from: transform)
        yawRadiansSamples.append(yp.yaw)

        let ring = CaptureSectorRingClassifier.ring(forPitchRadians: yp.pitch)
        let sectors = CaptureSectorRingClassifier.sectorsWithOverlap(forYawRadians: yp.yaw)
        lastRing = ring
        lastSector = sectors.first
        for sector in sectors {
            let key = Self.cellKey(ring: ring, sector: sector)
            sectorHits[key, default: 0] += 1
        }

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
    }

    mutating func markCompletionTiming(elapsedSec: Double, completionState: CaptureCompletionState) {
        if firstSoftCompleteAtSec == nil, completionState == .nearlyReady || completionState == .ready {
            firstSoftCompleteAtSec = elapsedSec
        }
        if firstReadyAtSec == nil, completionState == .ready {
            firstReadyAtSec = elapsedSec
        }
    }

    func sectorRingProgress() -> CaptureSectorRingProgress {
        var cells: [CaptureSectorCellProgress] = []
        var mid = 0, up = 0, low = 0
        for ring in CaptureElevationRing.allCases {
            for sector in CaptureYawSector.allCases {
                let hits = sectorHits[Self.cellKey(ring: ring, sector: sector)] ?? 0
                let state: CaptureSectorFillState
                if hits >= CaptureSectorRingConfig.hitsForSufficient {
                    state = .sufficient
                    switch ring {
                    case .middle: mid += 1
                    case .upper: up += 1
                    case .lower: low += 1
                    }
                } else if hits >= CaptureSectorRingConfig.hitsForCapturing {
                    state = .capturing
                } else if hits > 0 {
                    state = .insufficient
                } else {
                    state = .empty
                }
                cells.append(
                    CaptureSectorCellProgress(ring: ring, sector: sector, hitCount: hits, state: state)
                )
            }
        }
        let total = mid + up + low
        let fill = Double(total) / Double(CaptureElevationRing.allCases.count * CaptureYawSector.allCases.count)
        let stage = Self.stage(
            middle: mid,
            upper: up,
            lower: low,
            reconstructionReady: false
        )
        return CaptureSectorRingProgress(
            cells: cells,
            middleSufficientCount: mid,
            upperSufficientCount: up,
            lowerSufficientCount: low,
            totalSufficientCount: total,
            fillRatio: fill,
            stage: stage,
            currentRing: lastRing,
            currentSector: lastSector
        )
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
        var sector = sectorRingProgress()
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
            completionTimeSec: firstReadyAtSec,
            softCompletionTimeSec: firstSoftCompleteAtSec,
            middleRingSufficientSectors: sector.middleSufficientCount,
            upperRingSufficientSectors: sector.upperSufficientCount,
            lowerRingSufficientSectors: sector.lowerSufficientCount,
            sectorRingFillRatio: sector.fillRatio,
            guidanceStage: sector.stage.rawValue
        )
    }

    static func stage(
        middle: Int,
        upper: Int,
        lower: Int,
        reconstructionReady: Bool,
        softComplete: Bool = false
    ) -> CaptureGuidanceStage {
        if reconstructionReady { return .reconstructionReady }
        if middle < CaptureSectorRingConfig.middleSectorsRequired {
            return .eyeLevelSweep
        }
        if upper < CaptureSectorRingConfig.upperSectorsRequired {
            return .upperSweep
        }
        if lower < CaptureSectorRingConfig.lowerSectorsRequired {
            return .lowerSweep
        }
        if softComplete { return .softComplete }
        return .fillGaps
    }

    private static func cellKey(ring: CaptureElevationRing, sector: CaptureYawSector) -> String {
        "\(ring.rawValue)|\(sector.rawValue)"
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
        var maxGapBuckets = 0
        var gapAfterIndex = 0
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
    var sessionYawMinDeg: Double
    var sessionYawMaxDeg: Double
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
    var softCompletionTimeSec: Double?
    var middleRingSufficientSectors: Int
    var upperRingSufficientSectors: Int
    var lowerRingSufficientSectors: Int
    var sectorRingFillRatio: Double
    var guidanceStage: String

    enum CodingKeys: String, CodingKey {
        case sessionYawBucketCount, sessionYawCoverageRatio
        case sessionYawMinDeg, sessionYawMaxDeg, sessionYawSpanDeg
        case visitedCellCount, qualityCellCount, acceptableCellCount, goodCellCount
        case insufficientCellCount, unseenCellCount
        case xzExtentWidthM, xzExtentDepthM, xzBoundingAreaM2
        case totalTravelDistanceM, maxDistanceFromStartM
        case sessionViewDirectionBucketCount, sessionViewDirectionCoverageRatio
        case sessionMeanAngleDiversity, completionTimeSec
        case softCompletionTimeSec
        case middleRingSufficientSectors, upperRingSufficientSectors, lowerRingSufficientSectors
        case sectorRingFillRatio, guidanceStage
    }

    init(
        sessionYawBucketCount: Int,
        sessionYawCoverageRatio: Double,
        sessionYawMinDeg: Double,
        sessionYawMaxDeg: Double,
        sessionYawSpanDeg: Double,
        visitedCellCount: Int,
        qualityCellCount: Int,
        acceptableCellCount: Int,
        goodCellCount: Int,
        insufficientCellCount: Int,
        unseenCellCount: Int,
        xzExtentWidthM: Double,
        xzExtentDepthM: Double,
        xzBoundingAreaM2: Double,
        totalTravelDistanceM: Double,
        maxDistanceFromStartM: Double,
        sessionViewDirectionBucketCount: Int,
        sessionViewDirectionCoverageRatio: Double,
        sessionMeanAngleDiversity: Double,
        completionTimeSec: Double?,
        softCompletionTimeSec: Double? = nil,
        middleRingSufficientSectors: Int = 0,
        upperRingSufficientSectors: Int = 0,
        lowerRingSufficientSectors: Int = 0,
        sectorRingFillRatio: Double = 0,
        guidanceStage: String = CaptureGuidanceStage.eyeLevelSweep.rawValue
    ) {
        self.sessionYawBucketCount = sessionYawBucketCount
        self.sessionYawCoverageRatio = sessionYawCoverageRatio
        self.sessionYawMinDeg = sessionYawMinDeg
        self.sessionYawMaxDeg = sessionYawMaxDeg
        self.sessionYawSpanDeg = sessionYawSpanDeg
        self.visitedCellCount = visitedCellCount
        self.qualityCellCount = qualityCellCount
        self.acceptableCellCount = acceptableCellCount
        self.goodCellCount = goodCellCount
        self.insufficientCellCount = insufficientCellCount
        self.unseenCellCount = unseenCellCount
        self.xzExtentWidthM = xzExtentWidthM
        self.xzExtentDepthM = xzExtentDepthM
        self.xzBoundingAreaM2 = xzBoundingAreaM2
        self.totalTravelDistanceM = totalTravelDistanceM
        self.maxDistanceFromStartM = maxDistanceFromStartM
        self.sessionViewDirectionBucketCount = sessionViewDirectionBucketCount
        self.sessionViewDirectionCoverageRatio = sessionViewDirectionCoverageRatio
        self.sessionMeanAngleDiversity = sessionMeanAngleDiversity
        self.completionTimeSec = completionTimeSec
        self.softCompletionTimeSec = softCompletionTimeSec
        self.middleRingSufficientSectors = middleRingSufficientSectors
        self.upperRingSufficientSectors = upperRingSufficientSectors
        self.lowerRingSufficientSectors = lowerRingSufficientSectors
        self.sectorRingFillRatio = sectorRingFillRatio
        self.guidanceStage = guidanceStage
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        sessionYawBucketCount = try c.decode(Int.self, forKey: .sessionYawBucketCount)
        sessionYawCoverageRatio = try c.decode(Double.self, forKey: .sessionYawCoverageRatio)
        sessionYawMinDeg = try c.decode(Double.self, forKey: .sessionYawMinDeg)
        sessionYawMaxDeg = try c.decode(Double.self, forKey: .sessionYawMaxDeg)
        sessionYawSpanDeg = try c.decode(Double.self, forKey: .sessionYawSpanDeg)
        visitedCellCount = try c.decode(Int.self, forKey: .visitedCellCount)
        qualityCellCount = try c.decode(Int.self, forKey: .qualityCellCount)
        acceptableCellCount = try c.decode(Int.self, forKey: .acceptableCellCount)
        goodCellCount = try c.decode(Int.self, forKey: .goodCellCount)
        insufficientCellCount = try c.decode(Int.self, forKey: .insufficientCellCount)
        unseenCellCount = try c.decode(Int.self, forKey: .unseenCellCount)
        xzExtentWidthM = try c.decode(Double.self, forKey: .xzExtentWidthM)
        xzExtentDepthM = try c.decode(Double.self, forKey: .xzExtentDepthM)
        xzBoundingAreaM2 = try c.decode(Double.self, forKey: .xzBoundingAreaM2)
        totalTravelDistanceM = try c.decode(Double.self, forKey: .totalTravelDistanceM)
        maxDistanceFromStartM = try c.decode(Double.self, forKey: .maxDistanceFromStartM)
        sessionViewDirectionBucketCount = try c.decode(Int.self, forKey: .sessionViewDirectionBucketCount)
        sessionViewDirectionCoverageRatio = try c.decode(Double.self, forKey: .sessionViewDirectionCoverageRatio)
        sessionMeanAngleDiversity = try c.decode(Double.self, forKey: .sessionMeanAngleDiversity)
        completionTimeSec = try c.decodeIfPresent(Double.self, forKey: .completionTimeSec)
        softCompletionTimeSec = try c.decodeIfPresent(Double.self, forKey: .softCompletionTimeSec)
        middleRingSufficientSectors = try c.decodeIfPresent(Int.self, forKey: .middleRingSufficientSectors) ?? 0
        upperRingSufficientSectors = try c.decodeIfPresent(Int.self, forKey: .upperRingSufficientSectors) ?? 0
        lowerRingSufficientSectors = try c.decodeIfPresent(Int.self, forKey: .lowerRingSufficientSectors) ?? 0
        sectorRingFillRatio = try c.decodeIfPresent(Double.self, forKey: .sectorRingFillRatio) ?? 0
        guidanceStage = try c.decodeIfPresent(String.self, forKey: .guidanceStage)
            ?? CaptureGuidanceStage.eyeLevelSweep.rawValue
    }

    /// Sector/ring grid requirements for reconstructionReady.
    var sectorRingSatisfied: Bool {
        middleRingSufficientSectors >= CaptureSectorRingConfig.middleSectorsRequired
            && upperRingSufficientSectors >= CaptureSectorRingConfig.upperSectorsRequired
            && lowerRingSufficientSectors >= CaptureSectorRingConfig.lowerSectorsRequired
    }
}
