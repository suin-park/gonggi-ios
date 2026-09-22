import Foundation
import simd

/// Separates UI "I looked here" coverage from a **continuity-qualified coverage estimate**.
///
/// `reconstructionCoverageEstimate` is a proxy from committed reconstruction keyframes only.
/// It does **not** mean COLMAP/SfM succeeded or that the scene is reconstructable.
struct ReconstructionCoverageModel: Equatable {
    private(set) var liveCoverage: Double = 0
    /// Proxy estimate (0…1). Alias: `reconstructionCoverage` for API compatibility.
    private(set) var reconstructionCoverageEstimate: Double = 0
    private(set) var committedKeyframeCount: Int = 0
    private(set) var bridgeObservationCount: Int = 0
    private(set) var rejectedForContinuityCount: Int = 0
    private var reconYawBuckets: Set<Int> = []
    private var reconCells: Set<String> = []
    private var continuousChainLength: Int = 0

    /// Compatibility name — prefer `reconstructionCoverageEstimate`.
    var reconstructionCoverage: Double { reconstructionCoverageEstimate }
    /// Compatibility — bridge observations no longer inflate this count as keyframes.
    var bridgeKeyframeCount: Int { bridgeObservationCount }

    mutating func reset() {
        liveCoverage = 0
        reconstructionCoverageEstimate = 0
        committedKeyframeCount = 0
        bridgeObservationCount = 0
        rejectedForContinuityCount = 0
        reconYawBuckets = []
        reconCells = []
        continuousChainLength = 0
    }

    mutating func updateLive(from coverage: CoverageModelV1) {
        liveCoverage = coverage.qualityCoverage
        recompute()
    }

    /// Continuity bridge observation: stored for SfM linking, does **not** raise estimate.
    mutating func noteContinuityBridgeObservation() {
        bridgeObservationCount += 1
        // Do not extend recon chain / cells / yaw buckets.
        recompute()
    }

    /// Reconstruction keyframe that passed continuity + translation/parallax floors.
    mutating func commitReconstructionKeyframe(
        transform: simd_float4x4,
        countsForReconstruction: Bool,
        wasBridgeStep: Bool,
        opticalOK: Bool,
        parallaxOK: Bool
    ) {
        // wasBridgeStep kept for API compat; bridge-only accepts should call noteContinuityBridgeObservation.
        _ = wasBridgeStep
        guard countsForReconstruction, opticalOK else {
            rejectedForContinuityCount += 1
            continuousChainLength = 0
            recompute()
            return
        }
        committedKeyframeCount += 1
        continuousChainLength += 1
        reconYawBuckets.insert(CaptureMath.viewBucket(for: transform))
        let pos = simd_float3(transform.columns.3.x, transform.columns.3.y, transform.columns.3.z)
        reconCells.insert(CaptureMath.gridCellId(position: pos))
        if !parallaxOK {
            // Soft damp only — frame-local parallax must not erase chain progress alone.
            continuousChainLength = max(1, continuousChainLength)
        }
        recompute()
    }

    mutating func noteContinuityReject() {
        rejectedForContinuityCount += 1
        continuousChainLength = 0
        recompute()
    }

    var continuousChainOK: Bool {
        continuousChainLength >= CaptureBridgeConfig.minTerminalNeighborLinks
    }

    private mutating func recompute() {
        let yawFill = min(1, Double(reconYawBuckets.count) / Double(CaptureReconstructionReadyConfig.minYawBucketCount))
        let cellFill = min(1, Double(reconCells.count) / Double(CaptureReconstructionReadyConfig.minVisitedCellCount))
        let chain = min(1, Double(continuousChainLength) / Double(max(3, CaptureBridgeConfig.terminalContinuityWindow)))
        let committed = min(1, Double(committedKeyframeCount) / Double(CaptureCompletionConfig.minimumKeyframes))
        reconstructionCoverageEstimate = min(
            1,
            0.34 * yawFill + 0.28 * cellFill + 0.22 * chain + 0.16 * committed
        )
    }
}
