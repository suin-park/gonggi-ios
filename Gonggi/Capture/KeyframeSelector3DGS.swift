import Foundation
import simd

/// 3DGS keyframe policy — separate from TexturedMesh `KeyframeSelector`.
/// Does not replace MOV recording; marks samples for optional depth / future thinning.
enum KeyframeSelector3DGS {
    struct Config: Equatable {
        var minTranslationM: Float = 0.15
        var maxRotationRad: Float = 1.2 // ~70° — reject wild spins as keyframes
        var minIntervalSec: Double = 0.35
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
        config: Config = Config()
    ) -> Decision {
        guard trackingNormal else {
            return Decision(accept: false, reason: "tracking_not_normal")
        }
        guard let lastT = lastKeyframeTimestamp, let lastX = lastKeyframeTransform else {
            return Decision(accept: true, reason: "first")
        }
        if timestamp - lastT < config.minIntervalSec {
            return Decision(accept: false, reason: "min_interval")
        }
        let translation = CaptureMath.translationMeters(from: lastX, to: transform)
        if translation < config.minTranslationM {
            return Decision(accept: false, reason: "baseline_too_small")
        }
        let rotation = CaptureMath.rotationDeltaRadians(from: lastX, to: transform)
        if rotation > config.maxRotationRad {
            return Decision(accept: false, reason: "rotation_excessive")
        }
        return Decision(accept: true, reason: "baseline_ok")
    }
}
