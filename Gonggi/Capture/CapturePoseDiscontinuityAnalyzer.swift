import Foundation
import simd

/// DEBUG metrics for suspicious pose jumps (not a perfect tracker-failure classifier).
struct CapturePoseDiscontinuityAnalyzer {
    private(set) var trackingStateTransitions = 0
    private(set) var maxFrameTranslationDeltaM: Float = 0
    private(set) var maxFrameRotationDeltaRad: Float = 0
    private(set) var possiblePoseJumpCount = 0

    private var lastTrackingState: String?
    private var lastTransform: simd_float4x4?

    mutating func reset() {
        trackingStateTransitions = 0
        maxFrameTranslationDeltaM = 0
        maxFrameRotationDeltaRad = 0
        possiblePoseJumpCount = 0
        lastTrackingState = nil
        lastTransform = nil
    }

    mutating func ingest(transform: simd_float4x4, trackingState: String) {
        if let prev = lastTrackingState, prev != trackingState {
            trackingStateTransitions += 1
        }
        lastTrackingState = trackingState

        if let last = lastTransform {
            let t = CaptureMath.translationMeters(from: last, to: transform)
            let r = CaptureMath.rotationDeltaRadians(from: last, to: transform)
            maxFrameTranslationDeltaM = max(maxFrameTranslationDeltaM, t)
            maxFrameRotationDeltaRad = max(maxFrameRotationDeltaRad, r)
            if t >= TranslationBaselineConfig.possibleJumpTranslationM
                || r >= TranslationBaselineConfig.possibleJumpRotationRad
            {
                possiblePoseJumpCount += 1
            }
        }
        lastTransform = transform
    }

    var summary: CapturePoseDiscontinuitySummary {
        CapturePoseDiscontinuitySummary(
            trackingStateTransitions: trackingStateTransitions,
            maxFrameTranslationDeltaM: Double(maxFrameTranslationDeltaM),
            maxFrameRotationDeltaRad: Double(maxFrameRotationDeltaRad),
            possiblePoseJumpCount: possiblePoseJumpCount
        )
    }
}

struct CapturePoseDiscontinuitySummary: Codable, Equatable, Sendable {
    var trackingStateTransitions: Int
    var maxFrameTranslationDeltaM: Double
    var maxFrameRotationDeltaRad: Double
    var possiblePoseJumpCount: Int
}
