import Foundation
import simd

/// 3D spatial / 3DGS keyframe policy — separate from TexturedMesh `KeyframeSelector`.
/// Adaptive scoring prefers new coverage + doorway transitions; suppresses saturated redundancy.
enum KeyframeSelector3DGS {
    struct Config: Equatable {
        var minTranslationM: Float = SpatialCaptureConfig.minTranslationM
        var maxRotationRad: Float = SpatialCaptureConfig.maxRotationRad
        var minIntervalSec: Double = SpatialCaptureConfig.minIntervalSec
        var maxMotionSpeedMps: Double = SpatialCaptureConfig.maxMotionSpeedMps
        var maxAngularVelocityRadPerSec: Double = SpatialCaptureConfig.maxAngularVelocityRadPerSec
        var maxLowTextureScore: Double = SpatialCaptureConfig.maxLowTextureScore
        var hardMaxKeyframes: Int = SpatialCaptureConfig.candidateSafetyCap
        var useAdaptiveScoring: Bool = SpatialCaptureConfig.useAdaptiveKeyframeScoring
    }

    struct Decision: Equatable {
        var accept: Bool
        var reason: String
        var selectionScore: Double?
    }

    static func shouldAccept(
        timestamp: Double,
        transform: simd_float4x4,
        trackingNormal: Bool,
        lastKeyframeTimestamp: Double?,
        lastKeyframeTransform: simd_float4x4?,
        keyframeCount: Int = 0,
        sharpnessState: CaptureSharpnessState? = nil,
        motionSpeed: Double? = nil,
        angularVelocity: Double? = nil,
        lowTextureScore: Double? = nil,
        adaptiveContext: AdaptiveKeyframeScorer.Context? = nil,
        config: Config = Config()
    ) -> Decision {
        guard trackingNormal else {
            return Decision(accept: false, reason: "tracking_not_normal", selectionScore: nil)
        }
        if keyframeCount >= config.hardMaxKeyframes {
            return Decision(accept: false, reason: "safety_cap", selectionScore: nil)
        }
        if sharpnessState == .blurry {
            return Decision(accept: false, reason: "blur", selectionScore: nil)
        }
        if let motionSpeed, motionSpeed > config.maxMotionSpeedMps {
            return Decision(accept: false, reason: "motion_too_fast", selectionScore: nil)
        }
        if let angularVelocity, angularVelocity > config.maxAngularVelocityRadPerSec {
            return Decision(accept: false, reason: "angular_too_fast", selectionScore: nil)
        }
        if let lowTextureScore, lowTextureScore > config.maxLowTextureScore {
            return Decision(accept: false, reason: "low_texture", selectionScore: nil)
        }
        guard let lastT = lastKeyframeTimestamp, let lastX = lastKeyframeTransform else {
            return Decision(accept: true, reason: "first", selectionScore: 2.0)
        }
        if timestamp - lastT < config.minIntervalSec {
            return Decision(accept: false, reason: "min_interval", selectionScore: nil)
        }

        let translation = CaptureMath.translationMeters(from: lastX, to: transform)
        let rotation = CaptureMath.rotationDeltaRadians(from: lastX, to: transform)
        if rotation > config.maxRotationRad {
            return Decision(accept: false, reason: "rotation_excessive", selectionScore: nil)
        }

        if config.useAdaptiveScoring, let adaptiveContext {
            // Continuity starvation runs only after hard quality + min_interval gates above.
            var ctx = adaptiveContext
            // Prefer selector-measured translation from last accept when caller left a stale value.
            if ctx.translationFromNearestAcceptedM <= 0 {
                ctx.translationFromNearestAcceptedM = translation
            }
            if ctx.secondsSinceLastAccept <= 0 {
                ctx.secondsSinceLastAccept = timestamp - lastT
            }
            let breakdown = AdaptiveKeyframeScorer.score(context: ctx)
            let verdict = AdaptiveKeyframeScorer.shouldAccept(
                breakdown: breakdown,
                keyframeCount: keyframeCount,
                safetyCap: config.hardMaxKeyframes,
                acceptThreshold: SpatialCaptureConfig.adaptiveAcceptThreshold,
                context: ctx
            )
            return Decision(
                accept: verdict.accept,
                reason: verdict.reason,
                selectionScore: breakdown.total
            )
        }

        // Legacy binary gate (Baseline A-compatible fallback).
        if translation < config.minTranslationM {
            return Decision(accept: false, reason: "translation_too_small", selectionScore: nil)
        }
        return Decision(accept: true, reason: "translation_ok", selectionScore: Double(translation))
    }
}
