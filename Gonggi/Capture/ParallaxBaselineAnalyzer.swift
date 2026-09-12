import Foundation
import simd

/// Translation-baseline analyzer for 3DGS capture quality (NOT depth-aware parallax,
/// NOT view-angle diversity). Reference = last accepted 3DGS keyframe.
struct TranslationBaselineAnalyzer {
    private(set) var lastKeyframeTransform: simd_float4x4?
    private(set) var maxBaselineM: Float = 0
    private(set) var totalPathLengthM: Float = 0
    private(set) var bestGrade: CaptureTranslationBaselineGrade = .insufficient
    private var lastPosition: SIMD3<Float>?

    mutating func reset() {
        lastKeyframeTransform = nil
        maxBaselineM = 0
        totalPathLengthM = 0
        bestGrade = .insufficient
        lastPosition = nil
    }

    struct Evaluation: Equatable {
        var translationBaselineM: Float
        var grade: CaptureTranslationBaselineGrade
        var isInPlaceRotation: Bool
    }

    mutating func evaluate(
        transform: simd_float4x4,
        trackingNormal: Bool
    ) -> Evaluation {
        let pos = CaptureFrameContract.translation(from: transform)
        if let last = lastPosition {
            totalPathLengthM += simd_distance(last, pos)
        }
        lastPosition = pos

        guard let ref = lastKeyframeTransform else {
            return Evaluation(translationBaselineM: 0, grade: .insufficient, isInPlaceRotation: false)
        }

        let baseline = CaptureMath.translationMeters(from: ref, to: transform)
        maxBaselineM = max(maxBaselineM, baseline)
        let rot = CaptureMath.rotationDeltaRadians(from: ref, to: transform)
        let inPlace = baseline < TranslationBaselineConfig.inPlaceMaxTranslationM
            && rot >= TranslationBaselineConfig.inPlaceRotationRad

        let grade: CaptureTranslationBaselineGrade
        if !trackingNormal || inPlace {
            grade = .insufficient
        } else if baseline >= TranslationBaselineConfig.goodBaselineM {
            grade = .good
        } else if baseline >= TranslationBaselineConfig.minAcceptableBaselineM {
            grade = .acceptable
        } else {
            grade = .insufficient
        }

        if grade.score > bestGrade.score {
            bestGrade = grade
        }
        return Evaluation(translationBaselineM: baseline, grade: grade, isInPlaceRotation: inPlace)
    }

    mutating func acceptKeyframe(transform: simd_float4x4) {
        lastKeyframeTransform = transform
    }
}

/// Backward-compatible name used by older call sites.
typealias ParallaxBaselineAnalyzer = TranslationBaselineAnalyzer
