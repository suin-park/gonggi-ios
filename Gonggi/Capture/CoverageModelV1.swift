import Foundation
import simd

/// Spatial coverage v1 — coarse 3D grid cells observed from camera poses.
/// Does NOT mark cells good from a single LiDAR/mesh sighting.
struct CoverageCell: Equatable {
    let id: String
    var observationCount: Int = 0
    var uniqueViewBuckets: Set<Int> = []
    var revisitCount: Int = 0
    var lastSeenAt: Date?
    var coverageScore: Double = 0
    var state: CoverageState = .unseen

    var uniqueViewCount: Int { uniqueViewBuckets.count }
    var angleDiversity: Double {
        guard !uniqueViewBuckets.isEmpty else { return 0 }
        return min(1, Double(uniqueViewBuckets.count) / 8.0)
    }
}

struct CoverageModelV1 {
    private(set) var cells: [String: CoverageCell] = [:]
    private var lastCellId: String?
    private let minObservationsForGood = 4
    private let minUniqueViewsForGood = 5
    private let minDiversityForGood = 0.5

    mutating func observe(
        cameraTransform: simd_float4x4,
        motionQuality: Double,
        at date: Date = Date()
    ) {
        let pos = simd_float3(
            cameraTransform.columns.3.x,
            cameraTransform.columns.3.y,
            cameraTransform.columns.3.z
        )
        let cellId = CaptureMath.gridCellId(position: pos)
        let bucket = CaptureMath.viewBucket(for: cameraTransform)

        var cell = cells[cellId] ?? CoverageCell(id: cellId)
        cell.observationCount += 1
        cell.uniqueViewBuckets.insert(bucket)
        if let last = lastCellId, last == cellId, cell.observationCount > 1 {
            cell.revisitCount += 1
        }
        cell.lastSeenAt = date
        cell.coverageScore = score(
            observations: cell.observationCount,
            uniqueViews: cell.uniqueViewBuckets.count,
            diversity: cell.angleDiversity,
            motionQuality: motionQuality
        )
        cell.state = stateFor(cell: cell)
        cells[cellId] = cell
        lastCellId = cellId
    }

    var overallCoverage: Double {
        guard !cells.isEmpty else { return 0 }
        let scores = cells.values.map(\.coverageScore)
        return scores.reduce(0, +) / Double(scores.count)
    }

    var areas: [AreaCoverage] {
        cells.values.sorted { $0.id < $1.id }.map { cell in
            AreaCoverage(
                id: cell.id,
                observationCount: cell.observationCount,
                uniqueViewCount: cell.uniqueViewCount,
                angleDiversity: cell.angleDiversity,
                revisitCount: cell.revisitCount,
                coverageScore: cell.coverageScore,
                viewCount: cell.uniqueViewCount,
                lastSeenAt: cell.lastSeenAt,
                state: cell.state
            )
        }
    }

    var revisitScore: Double {
        guard !cells.isEmpty else { return 0 }
        let revisits = cells.values.map { Double($0.revisitCount) }
        return min(1, revisits.reduce(0, +) / Double(cells.count) / 3.0)
    }

    var angleDiversityScore: Double {
        guard !cells.isEmpty else { return 0 }
        return cells.values.map(\.angleDiversity).reduce(0, +) / Double(cells.count)
    }

    func countsByState() -> (good: Int, acceptable: Int, insufficient: Int, unseen: Int) {
        var g = 0, a = 0, i = 0, u = 0
        for cell in cells.values {
            switch cell.state {
            case .good: g += 1
            case .acceptable: a += 1
            case .insufficient: i += 1
            case .unseen: u += 1
            }
        }
        return (g, a, i, u)
    }

    func state(at worldPosition: simd_float3) -> CoverageState {
        let cellId = CaptureMath.gridCellId(position: worldPosition)
        return cells[cellId]?.state ?? .unseen
    }

    func snapshotCells() -> [String: CoverageCell] {
        cells
    }

    // MARK: - Scoring

    private func score(
        observations: Int,
        uniqueViews: Int,
        diversity: Double,
        motionQuality: Double
    ) -> Double {
        let obsFactor = min(1, Double(observations) / Double(minObservationsForGood + 2))
        let viewFactor = min(1, Double(uniqueViews) / Double(minUniqueViewsForGood))
        let divFactor = min(1, diversity / minDiversityForGood)
        let motionFactor = max(0.3, motionQuality)
        return min(1, (obsFactor * 0.35 + viewFactor * 0.35 + divFactor * 0.2 + motionFactor * 0.1))
    }

    private func stateFor(cell: CoverageCell) -> CoverageState {
        if cell.observationCount < 1 { return .unseen }
        if cell.observationCount < 2 || cell.uniqueViewCount < 2 || cell.angleDiversity < 0.15 {
            return .insufficient
        }
        if cell.coverageScore >= 0.72
            && cell.observationCount >= minObservationsForGood
            && cell.uniqueViewCount >= minUniqueViewsForGood
            && cell.angleDiversity >= minDiversityForGood {
            return .good
        }
        if cell.coverageScore >= 0.38 { return .acceptable }
        return .insufficient
    }
}
