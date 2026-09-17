import Foundation
import simd

/// Config-driven adaptive keyframe scoring for multi-room Spatial Capture.
/// Weights live in `SpatialCaptureConfig` — no magic numbers at call sites.
enum AdaptiveKeyframeScorer {
    struct Context: Equatable {
        var keyframeCount: Int
        var currentCellId: String
        var cellVisitCount: Int
        /// Fraction of recent path cells that are new (0…1).
        var newCoverageRatio: Double
        var yawNoveltyDeg: Double
        var pitchNoveltyDeg: Double
        var sharpnessScore: Double
        var trackingNormal: Bool
        var overlapState: CaptureOverlapState
        var translationFromNearestAcceptedM: Float
        var secondsSinceLastAccept: Double
        /// Elevated when entering a narrow corridor / doorway-like path.
        var transitionScore: Double
        var localCoverage: Double
        var globalCoverage: Double
    }

    struct ScoreBreakdown: Equatable {
        var total: Double
        var newCoverage: Double
        var spatialBaseline: Double
        var viewNovelty: Double
        var imageQuality: Double
        var transition: Double
        var redundancyPenalty: Double
        var reason: String
    }

    static func score(context: Context, config: SpatialCaptureAdaptiveConfig = .current) -> ScoreBreakdown {
        let cfg = config
        let newCoverage = min(1, context.newCoverageRatio) * cfg.newCoverageWeight
        let baseline = min(1, Double(context.translationFromNearestAcceptedM) / Double(cfg.spatialBaselineRefM))
            * cfg.spatialBaselineWeight
        let yawN = min(1, context.yawNoveltyDeg / cfg.yawNoveltyRefDeg)
        let pitchN = min(1, context.pitchNoveltyDeg / cfg.pitchNoveltyRefDeg)
        let viewNovelty = ((yawN + pitchN) * 0.5) * cfg.viewNoveltyWeight
        let quality = context.trackingNormal
            ? min(1, max(0, context.sharpnessScore)) * cfg.imageQualityWeight
            : 0
        let transition = min(1, max(0, context.transitionScore)) * cfg.transitionImportanceWeight

        var redundancy = 0.0
        if context.cellVisitCount >= cfg.redundantCellVisitThreshold,
           context.newCoverageRatio < cfg.redundantNewCoverageMax
        {
            redundancy += cfg.redundancyPenalty
        }
        if context.localCoverage >= cfg.localSaturatedCoverage,
           context.translationFromNearestAcceptedM < cfg.minTranslationWhenSaturatedM
        {
            redundancy += cfg.saturatedAreaPenalty
        }
        if context.secondsSinceLastAccept < cfg.minIntervalSec {
            redundancy += cfg.timeRedundancyPenalty
        }

        let total = newCoverage + baseline + viewNovelty + quality + transition - redundancy
        let reason: String
        if context.transitionScore >= cfg.transitionPriorityThreshold {
            reason = "transition_priority"
        } else if context.newCoverageRatio >= cfg.highNewCoverageThreshold {
            reason = "new_coverage"
        } else if redundancy > (newCoverage + viewNovelty) {
            reason = "redundant"
        } else {
            reason = "scored"
        }
        return ScoreBreakdown(
            total: total,
            newCoverage: newCoverage,
            spatialBaseline: baseline,
            viewNovelty: viewNovelty,
            imageQuality: quality,
            transition: transition,
            redundancyPenalty: redundancy,
            reason: reason
        )
    }

    static func shouldAccept(
        breakdown: ScoreBreakdown,
        keyframeCount: Int,
        safetyCap: Int,
        acceptThreshold: Double
    ) -> (accept: Bool, reason: String) {
        if keyframeCount >= safetyCap {
            return (false, "safety_cap")
        }
        if breakdown.total >= acceptThreshold {
            return (true, breakdown.reason)
        }
        // Transition frames: lower threshold so doorway continuity is preserved.
        if breakdown.transition > 0, breakdown.total >= acceptThreshold * 0.72 {
            return (true, "transition_relaxed")
        }
        return (false, breakdown.reason == "redundant" ? "redundant" : "score_below_threshold")
    }
}

struct SpatialCaptureAdaptiveConfig: Equatable, Sendable {
    var newCoverageWeight: Double
    var spatialBaselineWeight: Double
    var viewNoveltyWeight: Double
    var imageQualityWeight: Double
    var transitionImportanceWeight: Double
    var redundancyPenalty: Double
    var saturatedAreaPenalty: Double
    var timeRedundancyPenalty: Double
    var spatialBaselineRefM: Float
    var yawNoveltyRefDeg: Double
    var pitchNoveltyRefDeg: Double
    var redundantCellVisitThreshold: Int
    var redundantNewCoverageMax: Double
    var localSaturatedCoverage: Double
    var minTranslationWhenSaturatedM: Float
    var minIntervalSec: Double
    var transitionPriorityThreshold: Double
    var highNewCoverageThreshold: Double
    var acceptThreshold: Double
    var candidateSafetyCap: Int
    /// Soft reconstruction targets (server may further compress).
    var serverTargetSmallMin: Int
    var serverTargetSmallMax: Int
    var serverTargetNormalMin: Int
    var serverTargetNormalMax: Int
    var serverTargetMultiMin: Int
    var serverTargetMultiMax: Int

    static var current: SpatialCaptureAdaptiveConfig {
        SpatialCaptureAdaptiveConfig(
            newCoverageWeight: SpatialCaptureConfig.adaptiveNewCoverageWeight,
            spatialBaselineWeight: SpatialCaptureConfig.adaptiveSpatialBaselineWeight,
            viewNoveltyWeight: SpatialCaptureConfig.adaptiveViewNoveltyWeight,
            imageQualityWeight: SpatialCaptureConfig.adaptiveImageQualityWeight,
            transitionImportanceWeight: SpatialCaptureConfig.adaptiveTransitionWeight,
            redundancyPenalty: SpatialCaptureConfig.adaptiveRedundancyPenalty,
            saturatedAreaPenalty: SpatialCaptureConfig.adaptiveSaturatedAreaPenalty,
            timeRedundancyPenalty: SpatialCaptureConfig.adaptiveTimeRedundancyPenalty,
            spatialBaselineRefM: SpatialCaptureConfig.adaptiveSpatialBaselineRefM,
            yawNoveltyRefDeg: SpatialCaptureConfig.adaptiveYawNoveltyRefDeg,
            pitchNoveltyRefDeg: SpatialCaptureConfig.adaptivePitchNoveltyRefDeg,
            redundantCellVisitThreshold: SpatialCaptureConfig.adaptiveRedundantCellVisitThreshold,
            redundantNewCoverageMax: SpatialCaptureConfig.adaptiveRedundantNewCoverageMax,
            localSaturatedCoverage: SpatialCaptureConfig.adaptiveLocalSaturatedCoverage,
            minTranslationWhenSaturatedM: SpatialCaptureConfig.adaptiveMinTranslationWhenSaturatedM,
            minIntervalSec: SpatialCaptureConfig.minIntervalSec,
            transitionPriorityThreshold: SpatialCaptureConfig.adaptiveTransitionPriorityThreshold,
            highNewCoverageThreshold: SpatialCaptureConfig.adaptiveHighNewCoverageThreshold,
            acceptThreshold: SpatialCaptureConfig.adaptiveAcceptThreshold,
            candidateSafetyCap: SpatialCaptureConfig.candidateSafetyCap,
            serverTargetSmallMin: SpatialCaptureConfig.serverTargetSmallMin,
            serverTargetSmallMax: SpatialCaptureConfig.serverTargetSmallMax,
            serverTargetNormalMin: SpatialCaptureConfig.serverTargetNormalMin,
            serverTargetNormalMax: SpatialCaptureConfig.serverTargetNormalMax,
            serverTargetMultiMin: SpatialCaptureConfig.serverTargetMultiMin,
            serverTargetMultiMax: SpatialCaptureConfig.serverTargetMultiMax
        )
    }
}
