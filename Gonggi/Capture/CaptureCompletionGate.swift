import Foundation

enum CaptureCompletionGate {
    static func evaluate(
        durationSec: Double,
        keyframeCount: Int,
        pathLengthM: Double,
        qualityCoverage: Double,
        overlapState: CaptureOverlapState,
        sharpnessBlurryFraction: Double,
        trackingNormal: Bool,
        baselineGrade: CaptureTranslationBaselineGrade
    ) -> CaptureCompletionState {
        if durationSec < CaptureCompletionConfig.minimumDurationSec
            || keyframeCount < CaptureCompletionConfig.minimumKeyframes
            || pathLengthM < CaptureCompletionConfig.minimumPathLengthM
        {
            return .notReady
        }
        if CaptureCompletionConfig.requireTrackingNormal, !trackingNormal {
            return .notReady
        }
        if CaptureCompletionConfig.requireOverlapNotLost, overlapState == .lost {
            return .notReady
        }
        if sharpnessBlurryFraction > CaptureCompletionConfig.maxBlurryFraction {
            return .notReady
        }
        if CaptureCompletionConfig.requireBaselineAtLeastAcceptable,
           baselineGrade == .insufficient
        {
            return .notReady
        }
        if qualityCoverage >= CaptureCompletionConfig.qualityCoverageReady {
            return .ready
        }
        if qualityCoverage >= CaptureCompletionConfig.qualityCoverageNearly {
            return .nearlyReady
        }
        return .notReady
    }
}
