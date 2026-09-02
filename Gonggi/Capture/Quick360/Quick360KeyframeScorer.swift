import Foundation
import simd

/// Quality scoring for keyframe selection from continuous frame stream.
enum Quick360KeyframeScorer {
    struct Scores: Equatable {
        let orientation: Float
        let translation: Float
        let sharpness: Float
        let exposure: Float
        let dynamicPenalty: Float
        let combined: Float
    }

    static func score(
        candidate: Quick360FrameCandidate,
        target: Quick360SphericalTarget,
        dynamicRejectThreshold: Float = 0.45
    ) -> Scores {
        let targetYawRad = target.yawDeg * .pi / 180
        let targetPitchRad = target.pitchDeg * .pi / 180
        let angularDist = SphericalMath.angularDistanceRad(
            yawA: candidate.yawRad, pitchA: candidate.pitchRad,
            yawB: targetYawRad, pitchB: targetPitchRad
        )
        let maxAngle = Quick360Config.targetAngularToleranceDeg * .pi / 180
        let orientation = simd_clamp(1 - angularDist / max(maxAngle, 0.01), 0, 1)

        let translation = simd_clamp(
            1 - candidate.translationM / Quick360Config.translationExcessiveM,
            0, 1
        )

        let sharpness = simd_clamp(candidate.sharpness, 0, 1)
        let exposure = simd_clamp(candidate.exposure, 0, 1)
        let dynamicPenalty = simd_clamp(candidate.dynamicRatio, 0, 1)

        var combined =
            Quick360Config.weightOrientation * orientation +
            Quick360Config.weightTranslation * translation +
            Quick360Config.weightSharpness * sharpness +
            Quick360Config.weightExposure * exposure
        combined *= (1 - 0.5 * dynamicPenalty)

        if dynamicPenalty >= dynamicRejectThreshold {
            combined *= 0.25
        }

        return Scores(
            orientation: orientation,
            translation: translation,
            sharpness: sharpness,
            exposure: exposure,
            dynamicPenalty: dynamicPenalty,
            combined: combined
        )
    }

    static func selectBest(
        candidates: [Quick360FrameCandidate],
        target: Quick360SphericalTarget
    ) -> (candidate: Quick360FrameCandidate, scores: Scores)? {
        guard !candidates.isEmpty else { return nil }
        var best: (Quick360FrameCandidate, Scores)?
        for c in candidates {
            let s = score(candidate: c, target: target)
            if best == nil || s.combined > best!.1.combined {
                best = (c, s)
            }
        }
        return best
    }

    static func isDynamicReject(scores: Scores, threshold: Float = 0.45) -> Bool {
        scores.dynamicPenalty >= threshold && scores.combined < 0.35
    }
}
