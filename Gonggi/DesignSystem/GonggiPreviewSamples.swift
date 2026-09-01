import Foundation

/// Preview-only UI states — does not affect capture logic.
enum GonggiPreviewSamples {
    static let coachDefault = "천천히 이동하세요"
    static let coachTracking = "카메라를 천천히 움직여 위치를 다시 잡아주세요"
    static let coachFastMove = "조금 더 천천히 이동하세요"
    static let coachLowTexture = "주변 가구나 모서리가 함께 보이도록 촬영하세요"

    static let coverage30 = CaptureQualityState(
        overallCoverage: 0.30,
        motionSpeed: 0.25,
        angularVelocity: 0.2,
        blurScore: 0.85,
        exposureScore: 0.9,
        trackingQuality: 0.92,
        lowTextureScore: 0.2,
        overlapScore: 0.35,
        parallaxScore: 0.3,
        areas: []
    )

    static let coverage68 = CaptureQualityState(
        overallCoverage: 0.68,
        motionSpeed: 0.3,
        angularVelocity: 0.25,
        blurScore: 0.8,
        exposureScore: 0.9,
        trackingQuality: 0.95,
        lowTextureScore: 0.2,
        overlapScore: 0.65,
        parallaxScore: 0.55,
        areas: []
    )

    static let coverage90 = CaptureQualityState(
        overallCoverage: 0.90,
        motionSpeed: 0.22,
        angularVelocity: 0.18,
        blurScore: 0.88,
        exposureScore: 0.92,
        trackingQuality: 0.98,
        lowTextureScore: 0.15,
        overlapScore: 0.82,
        parallaxScore: 0.75,
        areas: []
    )

    static let trackingLimited = CaptureQualityState(
        overallCoverage: 0.45,
        motionSpeed: 0.5,
        angularVelocity: 0.6,
        blurScore: 0.55,
        exposureScore: 0.7,
        trackingQuality: 0.3,
        lowTextureScore: 0.3,
        overlapScore: 0.4,
        parallaxScore: 0.35,
        areas: []
    )

    static let fastMovement = CaptureQualityState(
        overallCoverage: 0.52,
        motionSpeed: 0.85,
        angularVelocity: 0.4,
        blurScore: 0.35,
        exposureScore: 0.85,
        trackingQuality: 0.88,
        lowTextureScore: 0.2,
        overlapScore: 0.5,
        parallaxScore: 0.4,
        areas: []
    )

    static let lowTexture = CaptureQualityState(
        overallCoverage: 0.40,
        motionSpeed: 0.2,
        angularVelocity: 0.15,
        blurScore: 0.75,
        exposureScore: 0.8,
        trackingQuality: 0.9,
        lowTextureScore: 0.72,
        overlapScore: 0.3,
        parallaxScore: 0.25,
        areas: []
    )

    static let sampleSummary = CaptureSessionSummary(
        captureId: "GONGGI_CAPTURE_V1_001",
        startedAt: Date().addingTimeInterval(-142),
        endedAt: Date(),
        quality: coverage68,
        fastMotionSegments: 2,
        lowTextureWarnings: 0,
        areasNeedingRevisit: 3,
        suggestedName: "어릴 적 우리 집",
        avgAngularVelocity: 0.42,
        maxAngularVelocity: 1.1,
        trackingLimitedSec: 2.5,
        goodAreaCount: 5,
        insufficientAreaCount: 3,
        revisitScore: 0.55,
        angleDiversityScore: 0.62
    )

    @MainActor
    static func guidance(
        quality: CaptureQualityState,
        message: String = coachDefault
    ) -> CaptureGuidanceEngine {
        let engine = CaptureGuidanceEngine()
        engine.applySnapshot(quality: quality, message: message)
        return engine
    }
}
