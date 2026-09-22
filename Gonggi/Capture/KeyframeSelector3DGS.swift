import Foundation
import simd

/// 3D spatial / 3DGS keyframe policy — separate from TexturedMesh `KeyframeSelector`.
/// Hard quality gates first, then `CaptureBridgeSession` enforces continuity
/// (max angular delta, bridge / reacquisition, frustum-overlap proxy).
enum KeyframeSelector3DGS {
    struct Config: Equatable {
        var minTranslationM: Float = SpatialCaptureConfig.minTranslationM
        var maxRotationRad: Float = SpatialCaptureConfig.maxRotationRad
        var minIntervalSec: Double = SpatialCaptureConfig.minIntervalSec
        var maxMotionSpeedMps: Double = SpatialCaptureConfig.maxMotionSpeedMps
        var maxAngularVelocityRadPerSec: Double = SpatialCaptureConfig.maxAngularVelocityRadPerSec
        var maxLowTextureScore: Double = SpatialCaptureConfig.maxLowTextureScore
        var hardMaxKeyframes: Int = SpatialCaptureConfig.hardMaxKeyframes
        var useBridgeContinuity: Bool = true
    }

    struct Decision: Equatable {
        var accept: Bool
        var reason: String
        var bridgeVerdict: CaptureBridgeVerdict?
        var countsForReconstruction: Bool
        var acceptKind: CaptureAcceptKind
        var frustumOverlap: Double?
        var forwardAngleDeg: Double?
        var yawDeltaDeg: Double?
        /// Compatibility with TF62 adaptive scorer tests (unused by dual-anchor policy).
        var selectionScore: Double? = nil

        /// Compatibility.
        var opticalOverlap: Double? {
            get { frustumOverlap }
            set { frustumOverlap = newValue }
        }

        static func rejected(_ reason: String) -> Decision {
            Decision(
                accept: false,
                reason: reason,
                bridgeVerdict: .reject,
                countsForReconstruction: false,
                acceptKind: .none,
                frustumOverlap: nil,
                forwardAngleDeg: nil,
                yawDeltaDeg: nil
            )
        }
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
        exposureScore: Double = 0.85,
        cellOverlapState: CaptureOverlapState = .notAvailable,
        parallaxGrade: CaptureTranslationBaselineGrade = .acceptable,
        bridgeSession: inout CaptureBridgeSession,
        config: Config = Config()
    ) -> Decision {
        guard trackingNormal else {
            return .rejected("tracking_not_normal")
        }
        if keyframeCount >= config.hardMaxKeyframes {
            return .rejected("max_keyframes")
        }
        if sharpnessState == .blurry {
            return .rejected("blur")
        }
        if let motionSpeed, motionSpeed > config.maxMotionSpeedMps {
            return .rejected("motion_too_fast")
        }
        if let angularVelocity, angularVelocity > config.maxAngularVelocityRadPerSec {
            return .rejected("angular_too_fast")
        }
        _ = lowTextureScore

        guard let lastT = lastKeyframeTimestamp, let lastX = lastKeyframeTransform else {
            return Decision(
                accept: true,
                reason: "first",
                bridgeVerdict: .accept,
                countsForReconstruction: true,
                acceptKind: .reconstructionKeyframe,
                frustumOverlap: 1,
                forwardAngleDeg: 0,
                yawDeltaDeg: 0
            )
        }

        if timestamp - lastT < config.minIntervalSec {
            return .rejected("min_interval")
        }

        // Sync continuity anchor if session was reset mid-capture.
        if bridgeSession.continuityAnchorTransform == nil {
            bridgeSession.noteAccepted(
                timestamp: lastT,
                transform: lastX,
                yawDeltaDeg: 0,
                frustumOverlap: 1,
                kind: .reconstructionKeyframe
            )
        }

        let continuity = bridgeSession.continuityAnchorTransform ?? lastX
        let recon = bridgeSession.reconstructionAnchorTransform
        let signals = CaptureBridgePolicy.signals(
            continuityAnchor: continuity,
            reconstructionAnchor: recon,
            candidate: transform,
            exposureScore: exposureScore,
            lowTextureScore: lowTextureScore ?? 0,
            cellOverlapState: cellOverlapState,
            parallaxGrade: parallaxGrade
        )

        if !config.useBridgeContinuity {
            if signals.translationM < config.minTranslationM {
                return .rejected("translation_too_small")
            }
            let rotation = CaptureMath.rotationDeltaRadians(from: lastX, to: transform)
            if rotation > config.maxRotationRad {
                return .rejected("rotation_excessive")
            }
            return Decision(
                accept: true,
                reason: "translation_ok",
                bridgeVerdict: .accept,
                countsForReconstruction: true,
                acceptKind: .reconstructionKeyframe,
                frustumOverlap: signals.frustumOverlap,
                forwardAngleDeg: signals.forwardAngleDeg,
                yawDeltaDeg: signals.yawDeltaDeg
            )
        }

        let bridge = bridgeSession.evaluate(
            timestamp: timestamp,
            transform: transform,
            signals: signals
        )

        let accept = bridge.verdict == .accept
        return Decision(
            accept: accept,
            reason: bridge.reason,
            bridgeVerdict: bridge.verdict,
            countsForReconstruction: bridge.countsForReconstruction,
            acceptKind: bridge.acceptKind,
            frustumOverlap: bridge.frustumOverlap,
            forwardAngleDeg: bridge.forwardAngleDeg,
            yawDeltaDeg: bridge.yawDeltaDeg
        )
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
        var session = CaptureBridgeSession()
        if let t = lastKeyframeTimestamp, let x = lastKeyframeTransform {
            session.noteAccepted(
                timestamp: t,
                transform: x,
                yawDeltaDeg: 0,
                frustumOverlap: 1,
                kind: .reconstructionKeyframe
            )
        }
        return shouldAccept(
            timestamp: timestamp,
            transform: transform,
            trackingNormal: trackingNormal,
            lastKeyframeTimestamp: lastKeyframeTimestamp,
            lastKeyframeTransform: lastKeyframeTransform,
            keyframeCount: keyframeCount,
            sharpnessState: sharpnessState,
            motionSpeed: motionSpeed,
            angularVelocity: angularVelocity,
            lowTextureScore: lowTextureScore,
            bridgeSession: &session,
            config: config
        )
    }

    /// Compatibility shim for TF62 adaptive-scoring call sites (observe-only; adaptive score unused).
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
        adaptiveContext: AdaptiveKeyframeScorer.Context?,
        config: Config = Config()
    ) -> Decision {
        _ = adaptiveContext
        return shouldAccept(
            timestamp: timestamp,
            transform: transform,
            trackingNormal: trackingNormal,
            lastKeyframeTimestamp: lastKeyframeTimestamp,
            lastKeyframeTransform: lastKeyframeTransform,
            keyframeCount: keyframeCount,
            sharpnessState: sharpnessState,
            motionSpeed: motionSpeed,
            angularVelocity: angularVelocity,
            lowTextureScore: lowTextureScore,
            config: config
        )
    }
}
