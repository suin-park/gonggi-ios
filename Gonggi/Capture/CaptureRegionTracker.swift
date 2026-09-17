import Foundation
import simd

/// Rolling local vs global coverage for multi-room Quiet UX.
/// Global = whole session; local = recent camera neighborhood (not whole-home completion).
struct CaptureLocalGlobalCoverage: Equatable, Sendable {
    var localCoverage: Double
    var globalCoverage: Double
    var localCellCount: Int
    var globalCellCount: Int
    var activeRegionId: String?
    var regionCount: Int
    var transitionScore: Double

    static let zero = CaptureLocalGlobalCoverage(
        localCoverage: 0,
        globalCoverage: 0,
        localCellCount: 0,
        globalCellCount: 0,
        activeRegionId: nil,
        regionCount: 0,
        transitionScore: 0
    )
}

/// Clusters trajectory cells into coarse regions + doorway-like transitions.
final class CaptureRegionTracker {
    private var cellVisitCounts: [String: Int] = [:]
    private var recentCellIds: [String] = []
    private var regionCentroids: [(id: String, x: Float, z: Float)] = []
    private var activeRegionId: String?
    private var lastPosition: SIMD3<Float>?
    private var recentSpeeds: [Float] = []
    private(set) var transitionScore: Double = 0
    private(set) var regionCount: Int = 0

    private let localWindow: Int
    private let regionSplitDistanceM: Float
    private let narrowSpeedMaxMps: Float

    init(
        localWindow: Int = SpatialCaptureConfig.localCoverageWindowCells,
        regionSplitDistanceM: Float = SpatialCaptureConfig.regionSplitDistanceM,
        narrowSpeedMaxMps: Float = SpatialCaptureConfig.doorwaySpeedMaxMps
    ) {
        self.localWindow = localWindow
        self.regionSplitDistanceM = regionSplitDistanceM
        self.narrowSpeedMaxMps = narrowSpeedMaxMps
    }

    func reset() {
        cellVisitCounts = [:]
        recentCellIds = []
        regionCentroids = []
        activeRegionId = nil
        lastPosition = nil
        recentSpeeds = []
        transitionScore = 0
        regionCount = 0
    }

    @discardableResult
    func ingest(cellId: String, position: SIMD3<Float>, deltaTimeSec: Float) -> CaptureLocalGlobalCoverage {
        cellVisitCounts[cellId, default: 0] += 1
        recentCellIds.append(cellId)
        if recentCellIds.count > localWindow {
            recentCellIds.removeFirst(recentCellIds.count - localWindow)
        }

        if let last = lastPosition, deltaTimeSec > 0.001 {
            let speed = simd_distance(last, position) / deltaTimeSec
            recentSpeeds.append(speed)
            if recentSpeeds.count > 12 {
                recentSpeeds.removeFirst(recentSpeeds.count - 12)
            }
            let meanSpeed = recentSpeeds.reduce(0, +) / Float(recentSpeeds.count)
            // Doorway heuristic: continued translation but slower + entering low-visit cells.
            let enteringFresh = (cellVisitCounts[cellId] ?? 0) <= 2
            if meanSpeed > 0.05, meanSpeed < narrowSpeedMaxMps, enteringFresh {
                transitionScore = min(1, transitionScore * 0.85 + 0.35)
            } else {
                transitionScore = max(0, transitionScore * 0.92 - 0.02)
            }
        }
        lastPosition = position

        updateRegion(position: position)

        let globalUnique = cellVisitCounts.count
        let localUnique = Set(recentCellIds).count
        // Soft ratios vs configurable denominators (not hard room size).
        let global = min(1, Double(globalUnique) / Double(SpatialCaptureConfig.globalCoverageSoftDenom))
        let local = min(1, Double(localUnique) / Double(max(1, localWindow / 2)))

        return CaptureLocalGlobalCoverage(
            localCoverage: local,
            globalCoverage: global,
            localCellCount: localUnique,
            globalCellCount: globalUnique,
            activeRegionId: activeRegionId,
            regionCount: regionCount,
            transitionScore: transitionScore
        )
    }

    func visitCount(for cellId: String) -> Int {
        cellVisitCounts[cellId] ?? 0
    }

    private func updateRegion(position: SIMD3<Float>) {
        if regionCentroids.isEmpty {
            let id = "region_000"
            regionCentroids.append((id, position.x, position.z))
            activeRegionId = id
            regionCount = 1
            return
        }
        var bestIdx = 0
        var bestDist = Float.greatestFiniteMagnitude
        for (i, c) in regionCentroids.enumerated() {
            let d = hypot(position.x - c.x, position.z - c.z)
            if d < bestDist {
                bestDist = d
                bestIdx = i
            }
        }
        if bestDist > regionSplitDistanceM {
            let id = String(format: "region_%03d", regionCentroids.count)
            regionCentroids.append((id, position.x, position.z))
            activeRegionId = id
            regionCount = regionCentroids.count
        } else {
            // Nudge centroid toward recent position.
            var c = regionCentroids[bestIdx]
            c.x = c.x * 0.92 + position.x * 0.08
            c.z = c.z * 0.92 + position.z * 0.08
            regionCentroids[bestIdx] = c
            activeRegionId = c.id
            regionCount = regionCentroids.count
        }
    }
}
