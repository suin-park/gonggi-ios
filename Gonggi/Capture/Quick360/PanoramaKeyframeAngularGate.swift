import Foundation
import simd

/// Angular spacing / quality gate for final-stitch keyframes (separate from live brush).
enum PanoramaKeyframeAngularGate {
    struct Decision: Equatable {
        let acceptedIndices: [Int]
        let rejectedIndices: [Int]
        let averageSpacingDeg: Double
    }

    /// Keep keyframes with sufficient yaw spacing and basic quality; prefers earlier accepted.
    static func selectForFinalStitch(
        yawRad: [Float],
        pitchRad: [Float],
        sharpness: [Float],
        exposure: [Float],
        dynamicRatio: [Float],
        translationM: [Float],
        minYawSpacingDeg: Float = Quick360Config.keyframeYawIntervalDeg * 0.55,
        minSharpness: Float = Quick360Config.keyframeMinSharpness,
        minExposure: Float = Quick360Config.keyframeMinExposure,
        maxDynamic: Float = Quick360Config.keyframeMaxDynamicRatio,
        maxTranslation: Float = Quick360Config.keyframeMaxTranslationM
    ) -> Decision {
        let n = yawRad.count
        guard n > 0 else {
            return Decision(acceptedIndices: [], rejectedIndices: [], averageSpacingDeg: 0)
        }
        var accepted: [Int] = []
        var rejected: [Int] = []
        for i in 0..<n {
            let qualityOK =
                sharpness[i] >= minSharpness
                && exposure[i] >= minExposure
                && dynamicRatio[i] <= maxDynamic
                && translationM[i] <= maxTranslation
            if !qualityOK {
                rejected.append(i)
                continue
            }
            if let last = accepted.last {
                let dist = SphericalMath.angularDistanceDeg(
                    yawA: yawRad[last], pitchA: pitchRad[last],
                    yawB: yawRad[i], pitchB: pitchRad[i]
                )
                if dist < minYawSpacingDeg {
                    rejected.append(i)
                    continue
                }
            }
            accepted.append(i)
        }
        if accepted.isEmpty, let firstOK = (0..<n).first(where: { sharpness[$0] >= minSharpness }) {
            accepted = [firstOK]
            rejected = (0..<n).filter { $0 != firstOK }
        }
        let spacing = averageAdjacentYawSpacingDeg(yawRad: yawRad, indices: accepted)
        return Decision(acceptedIndices: accepted, rejectedIndices: rejected, averageSpacingDeg: spacing)
    }

    static func averageAdjacentYawSpacingDeg(yawRad: [Float], indices: [Int]) -> Double {
        guard indices.count >= 2 else { return 0 }
        var sum: Double = 0
        for k in 1..<indices.count {
            var d = abs(yawRad[indices[k]] - yawRad[indices[k - 1]])
            while d > .pi { d -= 2 * .pi }
            while d < -.pi { d += 2 * .pi }
            sum += Double(abs(d) * 180 / .pi)
        }
        return sum / Double(indices.count - 1)
    }
}
