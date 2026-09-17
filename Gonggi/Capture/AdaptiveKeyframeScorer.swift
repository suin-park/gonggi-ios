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
        /// True while preserving doorway pre/mid/post chain.
        var inTransitionChain: Bool
    }

    struct ScoreBreakdown: Equatable {
        var total: Double
        var newCoverage: Double
        var spatialBaseline: Double
        var viewNovelty: Double
        var imageQuality: Double
        var transition: Double
        var continuityTime: Double
        var continuityDistance: Double
        var continuityTransitionChain: Double
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

        let gapRef = context.inTransitionChain ? cfg.transitionMaxGapSec : cfg.normalMaxGapSec
        let continuityTime = min(1, max(0, context.secondsSinceLastAccept) / max(0.001, gapRef))
            * cfg.continuityTimeWeight
        let continuityDistance = min(
            1,
            Double(context.translationFromNearestAcceptedM) / Double(max(0.01, cfg.distanceStarvationM))
        ) * cfg.continuityDistanceWeight
        let continuityTransitionChain = context.inTransitionChain
            ? cfg.continuityTransitionChainWeight
            : 0

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
        if context.inTransitionChain {
            redundancy *= cfg.transitionRedundancyScale
        }

        let total = newCoverage + baseline + viewNovelty + quality + transition
            + continuityTime + continuityDistance + continuityTransitionChain
            - redundancy

        let reason: String
        if context.inTransitionChain, context.transitionScore >= cfg.transitionPriorityThreshold * 0.6 {
            reason = "transition_chain"
        } else if context.transitionScore >= cfg.transitionPriorityThreshold {
            reason = "transition_priority"
        } else if context.newCoverageRatio >= cfg.highNewCoverageThreshold {
            reason = "new_coverage"
        } else if redundancy > (newCoverage + viewNovelty + continuityTime) {
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
            continuityTime: continuityTime,
            continuityDistance: continuityDistance,
            continuityTransitionChain: continuityTransitionChain,
            redundancyPenalty: redundancy,
            reason: reason
        )
    }

    static func shouldAccept(
        breakdown: ScoreBreakdown,
        keyframeCount: Int,
        safetyCap: Int,
        acceptThreshold: Double,
        context: Context,
        config: SpatialCaptureAdaptiveConfig = .current
    ) -> (accept: Bool, reason: String) {
        if keyframeCount >= safetyCap {
            return (false, "safety_cap")
        }
        if breakdown.total >= acceptThreshold {
            return (true, breakdown.reason)
        }
        // Transition frames: slightly lower threshold for doorway continuity.
        if breakdown.transition > 0, breakdown.total >= acceptThreshold * 0.72 {
            return (true, "transition_relaxed")
        }

        // Continuity starvation — only reached after hard quality gates in KeyframeSelector3DGS.
        let gapLimit = context.inTransitionChain ? config.transitionMaxGapSec : config.normalMaxGapSec
        if context.secondsSinceLastAccept >= gapLimit {
            return (true, context.inTransitionChain ? "continuity_time_transition" : "continuity_time_starvation")
        }
        if context.translationFromNearestAcceptedM >= config.distanceStarvationM {
            return (true, "continuity_distance_starvation")
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
    var normalMaxGapSec: Double
    var transitionMaxGapSec: Double
    var distanceStarvationM: Float
    var continuityTimeWeight: Double
    var continuityDistanceWeight: Double
    var continuityTransitionChainWeight: Double
    var transitionRedundancyScale: Double
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
            normalMaxGapSec: SpatialCaptureConfig.normalMaxGapSec,
            transitionMaxGapSec: SpatialCaptureConfig.transitionMaxGapSec,
            distanceStarvationM: SpatialCaptureConfig.distanceStarvationM,
            continuityTimeWeight: SpatialCaptureConfig.continuityTimeWeight,
            continuityDistanceWeight: SpatialCaptureConfig.continuityDistanceWeight,
            continuityTransitionChainWeight: SpatialCaptureConfig.continuityTransitionChainWeight,
            transitionRedundancyScale: SpatialCaptureConfig.transitionRedundancyScale,
            serverTargetSmallMin: SpatialCaptureConfig.serverTargetSmallMin,
            serverTargetSmallMax: SpatialCaptureConfig.serverTargetSmallMax,
            serverTargetNormalMin: SpatialCaptureConfig.serverTargetNormalMin,
            serverTargetNormalMax: SpatialCaptureConfig.serverTargetNormalMax,
            serverTargetMultiMin: SpatialCaptureConfig.serverTargetMultiMin,
            serverTargetMultiMax: SpatialCaptureConfig.serverTargetMultiMax
        )
    }
}
