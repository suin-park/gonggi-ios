import Foundation
import simd

/// Verdicts for selector / replay (product-facing continuity, not COLMAP).
enum CaptureBridgeVerdict: String, Codable, Equatable, Sendable {
    case accept
    case bridgeRequired
    case reacquire
    case reject
    case safeComplete
}

enum CaptureBridgeMode: String, Codable, Equatable, Sendable {
    case idle
    case bridging
    case reacquiring
}

enum CaptureAcceptKind: String, Codable, Equatable, Sendable {
    /// May raise `reconstructionCoverageEstimate`.
    case reconstructionKeyframe
    /// Links views only — does **not** raise recon coverage or move reconstructionAnchor.
    case continuityBridgeObservation
    case none
}

struct CaptureBridgeCandidateSignals: Equatable {
    /// Vs **continuityAnchor** (adjacent continuity).
    var frustumOverlap: Double
    var forwardAngleDeg: Double
    var yawDeltaDeg: Double
    /// Translation vs continuityAnchor (adjacent step).
    var translationM: Float
    /// Translation vs **reconstructionAnchor** (cumulative baseline for recon promotion).
    var baselineFromReconstructionAnchorM: Float
    var exposureScore: Double
    var lowTextureScore: Double
    /// Coverage-cell signal from `CellOverlapAnalyzer` — **not** optical/feature overlap.
    /// Diagnostic / soft-risk only; must not alone drive REACQUIRE or continuity hard gates.
    var cellOverlapState: CaptureOverlapState
    /// Diagnostic only — Gonggi `TranslationBaselineAnalyzer` grade (pose heuristic, not depth parallax).
    /// Must **not** be used as the sole hard gate for reconstructionKeyframe promotion.
    var parallaxGrade: CaptureTranslationBaselineGrade

    var opticalOverlap: Double {
        get { frustumOverlap }
        set { frustumOverlap = newValue }
    }
}

struct CaptureBridgeDecision: Equatable {
    var verdict: CaptureBridgeVerdict
    var reason: String
    var mode: CaptureBridgeMode
    var frustumOverlap: Double
    var forwardAngleDeg: Double
    var yawDeltaDeg: Double
    var baselineFromReconstructionAnchorM: Float
    var countsForReconstruction: Bool
    var acceptKind: CaptureAcceptKind

    var opticalOverlap: Double {
        get { frustumOverlap }
        set { frustumOverlap = newValue }
    }
}

/// Dual-anchor continuity / reconstruction session.
///
/// - `continuityAnchor`: angular / frustum continuity; updated on recon KF **or** bridge obs.
/// - `reconstructionAnchor`: cumulative translation baseline; updated on recon KF **only**.
/// Rejects / BRIDGE_REQUIRED / REACQUIRE never advance either anchor.
struct CaptureBridgeSession: Equatable {
    private(set) var mode: CaptureBridgeMode = .idle
    private(set) var bridgeTargetYawDeg: Float?
    private(set) var bridgeStepsAccepted: Int = 0

    private(set) var continuityAnchorTimestamp: Double?
    private(set) var continuityAnchorTransform: simd_float4x4?
    private(set) var reconstructionAnchorTimestamp: Double?
    private(set) var reconstructionAnchorTransform: simd_float4x4?

    private(set) var recentReconYawDeltasDeg: [Double] = []
    private(set) var recentReconFrustumOverlaps: [Double] = []
    private(set) var continuityBrokenSince: Double?
    private(set) var continuityBridgeObservationCount: Int = 0
    private(set) var reconstructionKeyframeCount: Int = 0

    // Compatibility aliases
    var lastAnchorTimestamp: Double? { continuityAnchorTimestamp }
    var lastAnchorTransform: simd_float4x4? { continuityAnchorTransform }
    var lastCommitTimestamp: Double? { continuityAnchorTimestamp }
    var lastCommitTransform: simd_float4x4? { continuityAnchorTransform }
    var lastReconstructionTimestamp: Double? { reconstructionAnchorTimestamp }
    var lastReconstructionTransform: simd_float4x4? { reconstructionAnchorTransform }

    mutating func reset() {
        mode = .idle
        bridgeTargetYawDeg = nil
        bridgeStepsAccepted = 0
        continuityAnchorTimestamp = nil
        continuityAnchorTransform = nil
        reconstructionAnchorTimestamp = nil
        reconstructionAnchorTransform = nil
        recentReconYawDeltasDeg = []
        recentReconFrustumOverlaps = []
        continuityBrokenSince = nil
        continuityBridgeObservationCount = 0
        reconstructionKeyframeCount = 0
    }

    /// After async JPEG encode/write failure: restore anchors to the last durable JPEG pose
    /// (or **clear** them when none exist) and enter reacquire.
    /// Does **not** decrement bridge/recon observation counters or reuse ids.
    mutating func restoreAfterAsyncJPEGFailure(
        at timestamp: Double,
        continuityTimestamp: Double?,
        continuityTransform: simd_float4x4?,
        reconstructionTimestamp: Double?,
        reconstructionTransform: simd_float4x4?,
        enterReacquire: Bool,
        clearReconstructionAnchor: Bool
    ) {
        if enterReacquire {
            mode = .reacquiring
            if continuityBrokenSince == nil {
                continuityBrokenSince = timestamp
            }
        }
        bridgeTargetYawDeg = nil
        bridgeStepsAccepted = 0
        if let t = continuityTimestamp, let x = continuityTransform {
            continuityAnchorTimestamp = t
            continuityAnchorTransform = x
        } else {
            continuityAnchorTimestamp = nil
            continuityAnchorTransform = nil
        }
        if clearReconstructionAnchor {
            if let t = reconstructionTimestamp, let x = reconstructionTransform {
                reconstructionAnchorTimestamp = t
                reconstructionAnchorTransform = x
            } else {
                reconstructionAnchorTimestamp = nil
                reconstructionAnchorTransform = nil
            }
        }
    }

    mutating func noteAccepted(
        timestamp: Double,
        transform: simd_float4x4,
        yawDeltaDeg: Double,
        frustumOverlap: Double,
        kind: CaptureAcceptKind
    ) {
        guard kind != .none else { return }
        // Continuity anchor advances for both accept kinds.
        continuityAnchorTimestamp = timestamp
        continuityAnchorTransform = transform
        continuityBrokenSince = nil

        switch kind {
        case .reconstructionKeyframe:
            reconstructionAnchorTimestamp = timestamp
            reconstructionAnchorTransform = transform
            reconstructionKeyframeCount += 1
            recentReconYawDeltasDeg.append(yawDeltaDeg)
            recentReconFrustumOverlaps.append(frustumOverlap)
            let window = CaptureBridgeConfig.terminalContinuityWindow
            if recentReconYawDeltasDeg.count > window {
                recentReconYawDeltasDeg.removeFirst(recentReconYawDeltasDeg.count - window)
            }
            if recentReconFrustumOverlaps.count > window {
                recentReconFrustumOverlaps.removeFirst(recentReconFrustumOverlaps.count - window)
            }
            mode = .idle
            bridgeTargetYawDeg = nil
            bridgeStepsAccepted = 0
        case .continuityBridgeObservation:
            continuityBridgeObservationCount += 1
            bridgeStepsAccepted += 1
            // reconstructionAnchor intentionally unchanged.
            if let target = bridgeTargetYawDeg {
                let yaw = FrustumOverlapProxy.yawDegrees(from: transform)
                let remain = abs(shortestDeg(yaw - target))
                if Double(remain) <= CaptureBridgeConfig.bridgeStepMaxYawDeg {
                    mode = .idle
                    bridgeTargetYawDeg = nil
                    bridgeStepsAccepted = 0
                } else {
                    mode = .bridging
                }
            } else {
                mode = .bridging
            }
        case .none:
            break
        }
    }

    mutating func noteCommitted(
        timestamp: Double,
        transform: simd_float4x4,
        yawDeltaDeg: Double,
        opticalOverlap: Double,
        wasBridgeStep: Bool
    ) {
        noteAccepted(
            timestamp: timestamp,
            transform: transform,
            yawDeltaDeg: yawDeltaDeg,
            frustumOverlap: opticalOverlap,
            kind: wasBridgeStep ? .continuityBridgeObservation : .reconstructionKeyframe
        )
    }

    mutating func evaluate(
        timestamp: Double,
        transform: simd_float4x4,
        signals: CaptureBridgeCandidateSignals,
        hardGateReason: String? = nil
    ) -> CaptureBridgeDecision {
        if let hard = hardGateReason {
            return decision(.reject, hard, signals, kind: .none, counts: false)
        }

        guard continuityAnchorTransform != nil, continuityAnchorTimestamp != nil else {
            mode = .idle
            return CaptureBridgeDecision(
                verdict: .accept,
                reason: "first",
                mode: mode,
                frustumOverlap: 1,
                forwardAngleDeg: 0,
                yawDeltaDeg: 0,
                baselineFromReconstructionAnchorM: 0,
                countsForReconstruction: true,
                acceptKind: .reconstructionKeyframe
            )
        }

        if signals.translationM < CaptureBridgeConfig.poseJitterTranslationM
            && signals.yawDeltaDeg < CaptureBridgeConfig.poseJitterYawDeg
            && signals.forwardAngleDeg < CaptureBridgeConfig.poseJitterYawDeg
        {
            return decision(.reject, "pose_jitter", signals, kind: .none, counts: false)
        }

        let yawOver = signals.yawDeltaDeg > CaptureBridgeConfig.maxYawDeltaDeg
        let fwdOver = signals.forwardAngleDeg > CaptureBridgeConfig.maxForwardAngleDeg
        let frustumWeak = signals.frustumOverlap < CaptureBridgeConfig.minFrustumOverlapAccept
        // Pose frustum only — CellOverlapAnalyzer is a coverage-cell signal, not optical overlap.
        // Do **not** treat cellOverlapState == .lost as frustumLost / reacquire hard gate.
        let frustumLost = signals.frustumOverlap <= CaptureBridgeConfig.frustumOverlapLost
        let compoundRisk = isCompoundSfmRisk(signals)

        let angularJump = max(signals.yawDeltaDeg, signals.forwardAngleDeg)
        // Unsupported single jump (TF62 ~23–28°) — never progressive-bridge across.
        if angularJump > CaptureBridgeConfig.unsupportedAngularJumpDeg {
            mode = .reacquiring
            if continuityBrokenSince == nil { continuityBrokenSince = timestamp }
            return decision(.reacquire, "reacquire_unsupported_jump", signals, kind: .none, counts: false)
        }

        if frustumLost && (yawOver || fwdOver || compoundRisk) {
            mode = .reacquiring
            if continuityBrokenSince == nil { continuityBrokenSince = timestamp }
            return decision(.reacquire, "reacquire_continuity_lost", signals, kind: .none, counts: false)
        }

        if compoundRisk && (yawOver || fwdOver || frustumWeak) {
            enterBridge(toward: transform)
            // Progressive: try a safe bridge step immediately instead of only BRIDGE_REQUIRED.
            return evaluateBridgeStep(signals: signals, fallbackReason: "bridge_compound_sfm_risk")
        }

        if yawOver || fwdOver || frustumWeak {
            if mode != .bridging && mode != .reacquiring {
                enterBridge(toward: transform)
            }
            // Progressive bridge: accept a step within bridgeStepMax vs continuityAnchor;
            // otherwise BRIDGE_REQUIRED so high-frequency ARFrames can land intermediate steps.
            return evaluateBridgeStep(
                signals: signals,
                fallbackReason: yawOver || fwdOver ? "bridge_angular_delta" : "bridge_frustum_weak"
            )
        }

        if signals.translationM > CaptureBridgeConfig.maxStepTranslationM {
            return decision(.reject, "translation_too_large", signals, kind: .none, counts: false)
        }

        // Continuity soft-band OK. Promote using cumulative baseline vs reconstructionAnchor.
        // Frame-local parallaxGrade is diagnostic only (not a hard gate).
        if signals.baselineFromReconstructionAnchorM >= CaptureBridgeConfig.minReconstructionTranslationM {
            mode = .idle
            bridgeTargetYawDeg = nil
            return decision(.accept, "continuity_ok", signals, kind: .reconstructionKeyframe, counts: true)
        }

        let angular = max(signals.yawDeltaDeg, signals.forwardAngleDeg)
        let frustumOK = signals.frustumOverlap >= CaptureBridgeConfig.minFrustumOverlapBridge
        // Bridge JPEG density: require save-floor angular change in soft-band and while bridging.
        // Soft-exit `evaluateBridgeStep` uses the same floor so progressive steps stay sparse
        // but still ≤ bridgeStepMaxYawDeg.
        if frustumOK && angular >= CaptureBridgeConfig.minBridgeSaveAngularDeg {
            if mode == .idle {
                enterBridge(toward: transform)
            }
            return decision(
                .accept,
                "continuity_bridge_observation",
                signals,
                kind: .continuityBridgeObservation,
                counts: false
            )
        }

        // Pure micro-translate: only while already bridging (do not spam JPEG on walking creep).
        if mode == .bridging || mode == .reacquiring,
           signals.translationM > CaptureBridgeConfig.poseJitterTranslationM,
           angular >= CaptureBridgeConfig.minBridgeAngularDeg
        {
            return decision(
                .accept,
                "continuity_bridge_observation",
                signals,
                kind: .continuityBridgeObservation,
                counts: false
            )
        }

        return decision(.reject, "translation_too_small", signals, kind: .none, counts: false)
    }

    func terminalContinuityStatus() -> (ok: Bool, reason: String) {
        if mode == .bridging || mode == .reacquiring {
            return (false, "bridge_incomplete")
        }
        guard recentReconYawDeltasDeg.count >= CaptureBridgeConfig.minTerminalNeighborLinks else {
            return (false, "insufficient_neighbor_links")
        }
        if let lastYaw = recentReconYawDeltasDeg.last,
           lastYaw > CaptureBridgeConfig.maxTerminalYawJumpDeg
        {
            return (false, "terminal_yaw_jump")
        }
        if let lastF = recentReconFrustumOverlaps.last,
           lastF < CaptureBridgeConfig.minFrustumOverlapAccept
        {
            return (false, "terminal_frustum_weak")
        }
        let weakLinks = recentReconFrustumOverlaps.filter {
            $0 < CaptureBridgeConfig.minFrustumOverlapBridge
        }.count
        if weakLinks > 0 {
            return (false, "recent_continuity_weak")
        }
        return (true, "safe_complete")
    }

    // MARK: - Private

    private mutating func enterBridge(toward transform: simd_float4x4) {
        mode = .bridging
        bridgeTargetYawDeg = FrustumOverlapProxy.yawDegrees(from: transform)
        bridgeStepsAccepted = 0
    }

    private mutating func evaluateBridgeStep(
        signals: CaptureBridgeCandidateSignals,
        fallbackReason: String = "bridge_step_too_large"
    ) -> CaptureBridgeDecision {
        _ = fallbackReason
        if signals.frustumOverlap < CaptureBridgeConfig.minFrustumOverlapBridge {
            if mode != .reacquiring { mode = .reacquiring }
            return decision(.reacquire, "reacquire_bridge_frustum", signals, kind: .none, counts: false)
        }
        if signals.yawDeltaDeg > CaptureBridgeConfig.bridgeStepMaxYawDeg
            || signals.forwardAngleDeg > CaptureBridgeConfig.maxForwardAngleDeg
        {
            if mode != .reacquiring { mode = .bridging }
            return decision(.bridgeRequired, "bridge_step_too_large", signals, kind: .none, counts: false)
        }
        let angularEnough = max(signals.yawDeltaDeg, signals.forwardAngleDeg)
            >= CaptureBridgeConfig.minBridgeSaveAngularDeg
        if !angularEnough && signals.translationM < CaptureBridgeConfig.poseJitterTranslationM {
            return decision(.reject, "pose_jitter", signals, kind: .none, counts: false)
        }
        if !angularEnough {
            // Not enough angular close yet; stay bridging without advancing the anchor.
            if mode != .reacquiring { mode = .bridging }
            return decision(.bridgeRequired, "bridge_step_too_large", signals, kind: .none, counts: false)
        }
        // Cumulative baseline vs reconstructionAnchor — not adjacent continuity step.
        if signals.baselineFromReconstructionAnchorM >= CaptureBridgeConfig.minReconstructionTranslationM {
            mode = .idle
            bridgeTargetYawDeg = nil
            return decision(
                .accept,
                "bridge_step_reconstruction",
                signals,
                kind: .reconstructionKeyframe,
                counts: true
            )
        }
        return decision(
            .accept,
            "continuity_bridge_observation",
            signals,
            kind: .continuityBridgeObservation,
            counts: false
        )
    }

    private func isCompoundSfmRisk(_ s: CaptureBridgeCandidateSignals) -> Bool {
        let dark = s.exposureScore <= CaptureBridgeConfig.darkExposureMax
        let lowTex = s.lowTextureScore >= CaptureBridgeConfig.lowTextureRiskMin
        let largeRot = s.forwardAngleDeg >= CaptureBridgeConfig.compoundLargeRotationDeg
            || s.yawDeltaDeg >= CaptureBridgeConfig.compoundLargeRotationDeg
        // Pose frustum only — coverage-cell overlap (.weak/.lost) is not optical/feature overlap.
        let lowOverlap = s.frustumOverlap < CaptureBridgeConfig.minFrustumOverlapAccept
        return largeRot && lowOverlap && (dark || lowTex)
    }

    private func decision(
        _ verdict: CaptureBridgeVerdict,
        _ reason: String,
        _ signals: CaptureBridgeCandidateSignals,
        kind: CaptureAcceptKind,
        counts: Bool
    ) -> CaptureBridgeDecision {
        CaptureBridgeDecision(
            verdict: verdict,
            reason: reason,
            mode: mode,
            frustumOverlap: signals.frustumOverlap,
            forwardAngleDeg: signals.forwardAngleDeg,
            yawDeltaDeg: signals.yawDeltaDeg,
            baselineFromReconstructionAnchorM: signals.baselineFromReconstructionAnchorM,
            countsForReconstruction: counts,
            acceptKind: kind
        )
    }

    private func shortestDeg(_ d: Float) -> Float {
        var x = d
        while x > 180 { x -= 360 }
        while x < -180 { x += 360 }
        return x
    }
}

enum CaptureBridgePolicy {
    /// Build signals vs continuityAnchor; fill recon baseline from reconstructionAnchor.
    static func signals(
        continuityAnchor: simd_float4x4,
        reconstructionAnchor: simd_float4x4?,
        candidate: simd_float4x4,
        exposureScore: Double,
        lowTextureScore: Double,
        cellOverlapState: CaptureOverlapState,
        parallaxGrade: CaptureTranslationBaselineGrade
    ) -> CaptureBridgeCandidateSignals {
        let sample = FrustumOverlapProxy.sample(from: continuityAnchor, to: candidate)
        let reconRef = reconstructionAnchor ?? continuityAnchor
        let baselineRecon = CaptureMath.translationMeters(from: reconRef, to: candidate)
        return CaptureBridgeCandidateSignals(
            frustumOverlap: sample.frustumOverlap,
            forwardAngleDeg: sample.forwardAngleDeg,
            yawDeltaDeg: sample.yawDeltaDeg,
            translationM: sample.translationM,
            baselineFromReconstructionAnchorM: baselineRecon,
            exposureScore: exposureScore,
            lowTextureScore: lowTextureScore,
            cellOverlapState: cellOverlapState,
            parallaxGrade: parallaxGrade
        )
    }

    /// Compatibility wrapper (assumes same pose for both anchors).
    static func signals(
        from last: simd_float4x4,
        to candidate: simd_float4x4,
        exposureScore: Double,
        lowTextureScore: Double,
        cellOverlapState: CaptureOverlapState,
        parallaxGrade: CaptureTranslationBaselineGrade
    ) -> CaptureBridgeCandidateSignals {
        signals(
            continuityAnchor: last,
            reconstructionAnchor: last,
            candidate: candidate,
            exposureScore: exposureScore,
            lowTextureScore: lowTextureScore,
            cellOverlapState: cellOverlapState,
            parallaxGrade: parallaxGrade
        )
    }
}
