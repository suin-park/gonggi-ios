import Foundation

/// Indoor capture → SfM continuity policy.
///
/// Thresholds are **initial provisional values** (not production-calibrated).
/// They do **not** guarantee reconstructable optical overlap, COLMAP success, or
/// that capture failure modes are fully solved.
enum CaptureBridgeConfig {
    // MARK: Angular continuity (anchor → candidate)

    /// Soft max yaw between consecutive *accepted* continuity anchors (degrees). Provisional.
    static var maxYawDeltaDeg: Double = 12
    /// Soft max forward-vector angle (see FrustumOverlapProxy). Provisional.
    static var maxForwardAngleDeg: Double = 15
    /// While bridging, each continuity observation may close at most this much yaw.
    /// Aligned with `maxYawDeltaDeg` so soft-band exit is not immediately `bridge_step_too_large`.
    /// Must stay well below unsupported-jump (do **not** raise past ~20° casually).
    static var bridgeStepMaxYawDeg: Double = 12
    /// Minimum yaw (or forward) change to treat as a real continuity bridge step (not jitter).
    static var minBridgeAngularDeg: Double = 1.5
    /// Soft-band (idle) and progressive bridge JPEG save floor — higher than
    /// `minBridgeAngularDeg` so calm / progressive turns do not enqueue a bridge every
    /// eval tick. Must stay ≤ `bridgeStepMaxYawDeg` (12°). Soft-exit still blocks >22°.
    static var minBridgeSaveAngularDeg: Double = 8.0
    /// Below this yaw+tiny translation → pose jitter reject (no coverage advance).
    static var poseJitterYawDeg: Double = 0.75
    static var poseJitterTranslationM: Float = 0.012

    /// Reconstruction keyframe min spacing (also `SpatialCaptureConfig.minIntervalSec`).
    static var minReconstructionIntervalSec: Double = 0.30
    /// Continuity bridge observation / progressive step evaluation spacing (ARFrame cadence).
    /// Shorter than recon interval so continuous turns can land safe intermediate steps
    /// before yaw vs a stale continuityAnchor exceeds `bridgeStepMaxYawDeg`, but long enough
    /// that bridge+recon share of `candidateSafetyCap` (520) is not exhausted mid-capture.
    static var minBridgeObservationIntervalSec: Double = 0.20
    /// Single-frame angular jump vs continuityAnchor → hard REACQUIRE (TF62 23–28° class).
    static var unsupportedAngularJumpDeg: Double = 22
    /// When previous-frame feature persistence is measurable and below this, do not save bridge JPEG
    /// / advance continuityAnchor (`nil` / identifiers-unavailable does not hard-block).
    static var minBridgeFeaturePersistentRatio: Double = 0.05
    /// Show REACQUIRE continuity-anchor thumbnail after this duration in reacquiring mode.
    static var reacquireThumbnailMinDurationSec: Double = 0.5

    // MARK: Reconstruction keyframe translation (vs reconstructionAnchor)

    /// Minimum **cumulative** translation from last reconstructionAnchor (meters). Provisional.
    /// Continuity bridge observations do not reset this baseline.
    static var minReconstructionTranslationM: Float = 0.025
    /// Soft upper translation for a single continuity step (vs continuityAnchor).
    static var maxStepTranslationM: Float = 0.85

    /// Note: `quality.parallaxGrade` / TranslationBaselineAnalyzer is a pose heuristic vs last
    /// reconstruction keyframe when wired correctly — **not** depth-aware parallax and **not**
    /// a hard gate for reconstructionKeyframe promotion (diagnostic / soft risk only).

    // MARK: Frustum overlap proxy (pose-only — not feature/optical/COLMAP)

    static var minFrustumOverlapAccept: Double = 0.42
    static var minFrustumOverlapBridge: Double = 0.32
    static var frustumOverlapLost: Double = 0.18
    static var assumedSceneDepthM: Float = 2.4
    static var horizontalFovDeg: Float = 65
    static var verticalFovDeg: Float = 50

    // Compatibility aliases (prefer frustum* names)
    static var minOpticalOverlapAccept: Double {
        get { minFrustumOverlapAccept }
        set { minFrustumOverlapAccept = newValue }
    }
    static var minOpticalOverlapBridge: Double {
        get { minFrustumOverlapBridge }
        set { minFrustumOverlapBridge = newValue }
    }
    static var opticalOverlapLost: Double {
        get { frustumOverlapLost }
        set { frustumOverlapLost = newValue }
    }

    // MARK: Compound risk (rotation ∩ dark ∩ low-texture ∩ low frustum)

    static var darkExposureMax: Double = 0.42
    static var lowTextureRiskMin: Double = 0.55
    static var compoundLargeRotationDeg: Double = 12

    // MARK: Reacquisition

    static var reacquireStarvationSec: Double = 2.5
    static var reacquireMinFrustumOverlap: Double = 0.38
    /// Max long edge for in-memory REACQUIRE reference thumbnail (no durable high-res duplicate).
    static var reacquireThumbnailMaxEdgePx: CGFloat = 160
    static var reacquireMinOpticalOverlap: Double {
        get { reacquireMinFrustumOverlap }
        set { reacquireMinFrustumOverlap = newValue }
    }

    // MARK: End-of-capture continuity

    static var terminalContinuityWindow: Int = 3
    static var minTerminalNeighborLinks: Int = 2
    static var maxTerminalYawJumpDeg: Double = 12
    /// Floors for `reconstructionCoverageEstimate` (proxy, not SfM success). Provisional.
    static var reconstructionCoverageReady: Double = 0.55
    static var reconstructionCoverageNearly: Double = 0.40

    static var liveCoverageSoftWeight: Double = 0.35

    // Deprecated aliases
    static var minBridgeTranslationM: Float = 0
    static var minAcceptTranslationM: Float {
        get { minReconstructionTranslationM }
        set { minReconstructionTranslationM = newValue }
    }
}
