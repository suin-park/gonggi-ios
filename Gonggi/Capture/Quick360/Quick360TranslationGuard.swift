import Foundation
import simd

/// Monitors camera translation from capture origin for parallax guard.
enum Quick360TranslationGuard {
    struct State: Equatable {
        var level: Quick360TranslationLevel
        var distanceM: Float
        var maxDistanceM: Float
        var averageDistanceM: Float
        var sampleCount: Int
        var shouldHoldKeyframe: Bool

        static let initial = State(
            level: .safe,
            distanceM: 0,
            maxDistanceM: 0,
            averageDistanceM: 0,
            sampleCount: 0,
            shouldHoldKeyframe: false
        )
    }

    static func level(for distanceM: Float) -> Quick360TranslationLevel {
        if distanceM >= Quick360Config.translationExcessiveM { return .excessive }
        if distanceM >= Quick360Config.translationWarningM { return .warning }
        return .safe
    }

    static func update(
        state: State,
        cameraTransform: simd_float4x4,
        originTransform: simd_float4x4
    ) -> State {
        let distance = CaptureMath.translationMeters(from: originTransform, to: cameraTransform)
        let newMax = max(state.maxDistanceM, distance)
        let newCount = state.sampleCount + 1
        let newAvg = (state.averageDistanceM * Float(state.sampleCount) + distance) / Float(newCount)
        let lvl = level(for: distance)
        return State(
            level: lvl,
            distanceM: distance,
            maxDistanceM: newMax,
            averageDistanceM: newAvg,
            sampleCount: newCount,
            shouldHoldKeyframe: lvl == .excessive
        )
    }

    static func guidance(
        translationLevel: Quick360TranslationLevel,
        rotationHint: Quick360GuidanceKind
    ) -> Quick360GuidanceKind {
        switch translationLevel {
        case .excessive:
            return .returnToOrigin
        case .warning:
            return .holdStill
        case .safe:
            return rotationHint
        }
    }
}
