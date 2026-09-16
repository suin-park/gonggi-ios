import Foundation
import simd

/// 3D spatial / 3DGS keyframe policy — separate from TexturedMesh `KeyframeSelector`.
/// Prefers translation over in-place spin; optional quality gates reject blurry/fast/low-texture frames.
enum KeyframeSelector3DGS {
    struct Config: Equatable {
        var minTranslationM: Float = SpatialCaptureConfig.minTranslationM
        var maxRotationRad: Float = SpatialCaptureConfig.maxRotationRad
        var minIntervalSec: Double = SpatialCaptureConfig.minIntervalSec
        var maxMotionSpeedMps: Double = SpatialCaptureConfig.maxMotionSpeedMps
        var maxAngularVelocityRadPerSec: Double = SpatialCaptureConfig.maxAngularVelocityRadPerSec
        var maxLowTextureScore: Double = SpatialCaptureConfig.maxLowTextureScore
        var hardMaxKeyframes: Int = SpatialCaptureConfig.hardMaxKeyframes
    }

    struct Decision: Equatable {
        var accept: Bool
        var reason: String
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
        config: Config = Config()
    ) -> Decision {
        guard trackingNormal else {
            return Decision(accept: false, reason: "tracking_not_normal")
        }
        if keyframeCount >= config.hardMaxKeyframes {
            return Decision(accept: false, reason: "max_keyframes")
        }
        if sharpnessState == .blurry {
            return Decision(accept: false, reason: "blur")
        }
        if let motionSpeed, motionSpeed > config.maxMotionSpeedMps {
            return Decision(accept: false, reason: "motion_too_fast")
        }
        if let angularVelocity, angularVelocity > config.maxAngularVelocityRadPerSec {
            return Decision(accept: false, reason: "angular_too_fast")
        }
        if let lowTextureScore, lowTextureScore > config.maxLowTextureScore {
            return Decision(accept: false, reason: "low_texture")
        }
        guard let lastT = lastKeyframeTimestamp, let lastX = lastKeyframeTransform else {
            return Decision(accept: true, reason: "first")
        }
        if timestamp - lastT < config.minIntervalSec {
            return Decision(accept: false, reason: "min_interval")
        }
        let translation = CaptureMath.translationMeters(from: lastX, to: transform)
        if translation < config.minTranslationM {
            return Decision(accept: false, reason: "translation_too_small")
        }
        let rotation = CaptureMath.rotationDeltaRadians(from: lastX, to: transform)
        if rotation > config.maxRotationRad {
            return Decision(accept: false, reason: "rotation_excessive")
        }
        return Decision(accept: true, reason: "translation_ok")
    }
}
