import Foundation
import simd

/// Lightweight cell-path overlap (non-LiDAR).
/// Uses recent coverage-cell path as reference window — not meshAnchorCount.
struct CellOverlapAnalyzer: OverlapMetricProviding {
    private var pathCellIds: [String] = []
    private var referenceCells: Set<String> = []
    private(set) var lastScore: Double = 1
    private(set) var lastState: CaptureOverlapState = .notAvailable

    mutating func reset() {
        pathCellIds = []
        referenceCells = []
        lastScore = 1
        lastState = .notAvailable
    }

    func availability() -> CaptureMetricAvailability { .available }

    func estimateOverlap(
        currentTransform: simd_float4x4,
        referenceTransform: simd_float4x4?
    ) -> Double? {
        _ = currentTransform
        _ = referenceTransform
        return lastState == .notAvailable ? nil : lastScore
    }

    /// Call every guidance tick with current camera cell (+ optional keyframe refresh of reference).
    mutating func ingest(currentCellId: String, isKeyframe: Bool) -> (score: Double, state: CaptureOverlapState) {
        pathCellIds.append(currentCellId)
        if pathCellIds.count > OverlapConfig.pathBufferSize {
            pathCellIds.removeFirst(pathCellIds.count - OverlapConfig.pathBufferSize)
        }

        if isKeyframe || referenceCells.isEmpty {
            let window = pathCellIds.suffix(OverlapConfig.referenceWindowSize)
            referenceCells = Set(window)
        }

        guard !referenceCells.isEmpty else {
            lastScore = 1
            lastState = .good
            return (lastScore, lastState)
        }

        // Current visible proxy: recent short path (maintains connection while moving).
        let currentVisible = Set(pathCellIds.suffix(max(3, OverlapConfig.referenceWindowSize / 3)))
        let intersection = referenceCells.intersection(currentVisible)
        let score = Double(intersection.count) / Double(max(1, referenceCells.count))
        let state: CaptureOverlapState
        if score >= OverlapConfig.goodMin {
            state = .good
        } else if score <= OverlapConfig.lostMax {
            state = .lost
        } else {
            state = .weak
        }
        lastScore = score
        lastState = state
        return (score, state)
    }
}
