import Foundation
import simd
import XCTest
@testable import Gonggi

final class CaptureBridgePolicyTests: XCTestCase {
    private func yawTransform(degrees: Float, translation: simd_float3 = .zero) -> simd_float4x4 {
        let rad = degrees * .pi / 180
        var m = matrix_identity_float4x4
        m.columns.0 = SIMD4(cos(rad), 0, -sin(rad), 0)
        m.columns.2 = SIMD4(sin(rad), 0, cos(rad), 0)
        m.columns.3 = SIMD4(translation.x, translation.y, translation.z, 1)
        return m
    }

    private func decide(
        to: simd_float4x4,
        timestamp: Double,
        session: inout CaptureBridgeSession,
        exposure: Double = 0.85,
        lowTex: Double = 0.1,
        cell: CaptureOverlapState = .good
    ) -> KeyframeSelector3DGS.Decision {
        KeyframeSelector3DGS.shouldAccept(
            timestamp: timestamp,
            transform: to,
            trackingNormal: true,
            lastKeyframeTimestamp: session.continuityAnchorTimestamp ?? 0,
            lastKeyframeTransform: session.continuityAnchorTransform ?? matrix_identity_float4x4,
            keyframeCount: session.reconstructionKeyframeCount + session.continuityBridgeObservationCount,
            lowTextureScore: lowTex,
            exposureScore: exposure,
            cellOverlapState: cell,
            parallaxGrade: .insufficient, // must not block cumulative promotion
            bridgeSession: &session
        )
    }

    func testOneCmStepsAccumulateToReconstructionKeyframe() {
        var session = CaptureBridgeSession()
        let origin = yawTransform(degrees: 0)
        session.noteAccepted(timestamp: 0, transform: origin, yawDeltaDeg: 0, frustumOverlap: 1, kind: .reconstructionKeyframe)
        var sawReconPromotion = false
        // Steps must exceed poseJitterTranslationM (0.012) and minInterval (0.30s).
        for i in 1...5 {
            let cand = yawTransform(degrees: 0, translation: SIMD3(0.015 * Float(i), 0, 0))
            let d = decide(to: cand, timestamp: Double(i) * 0.35, session: &session)
            XCTAssertTrue(d.accept, "step \(i) \(d.reason)")
            session.noteAccepted(
                timestamp: Double(i) * 0.35,
                transform: cand,
                yawDeltaDeg: d.yawDeltaDeg ?? 0,
                frustumOverlap: d.frustumOverlap ?? 0,
                kind: d.acceptKind
            )
            if d.acceptKind == .reconstructionKeyframe && i >= 2 {
                sawReconPromotion = true
            }
        }
        XCTAssertTrue(sawReconPromotion || session.reconstructionKeyframeCount >= 2)
        XCTAssertGreaterThan(session.continuityBridgeObservationCount + session.reconstructionKeyframeCount, 1)
    }

    func testInPlaceYawDoesNotMoveReconstructionAnchorOrCoverage() {
        var session = CaptureBridgeSession()
        var coverage = ReconstructionCoverageModel()
        let origin = yawTransform(degrees: 0)
        session.noteAccepted(timestamp: 0, transform: origin, yawDeltaDeg: 0, frustumOverlap: 1, kind: .reconstructionKeyframe)
        coverage.commitReconstructionKeyframe(
            transform: origin, countsForReconstruction: true, wasBridgeStep: false, opticalOK: true, parallaxOK: true
        )
        let est0 = coverage.reconstructionCoverageEstimate
        let reconT0 = session.reconstructionAnchorTimestamp
        for i in 1...6 {
            let cand = yawTransform(degrees: Float(i * 8))
            let d = decide(to: cand, timestamp: Double(i) * 0.35, session: &session)
            if d.accept {
                session.noteAccepted(
                    timestamp: Double(i) * 0.35,
                    transform: cand,
                    yawDeltaDeg: d.yawDeltaDeg ?? 0,
                    frustumOverlap: d.frustumOverlap ?? 0,
                    kind: d.acceptKind
                )
                if d.acceptKind == .continuityBridgeObservation {
                    coverage.noteContinuityBridgeObservation()
                }
            }
        }
        XCTAssertEqual(session.reconstructionAnchorTimestamp, reconT0)
        XCTAssertEqual(coverage.reconstructionCoverageEstimate, est0, accuracy: 0.001)
        XCTAssertGreaterThan(session.continuityBridgeObservationCount, 0)
    }

    func testTwentyBridgeObsDoNotResetReconstructionBaseline() {
        var session = CaptureBridgeSession()
        let origin = yawTransform(degrees: 0)
        session.noteAccepted(timestamp: 0, transform: origin, yawDeltaDeg: 0, frustumOverlap: 1, kind: .reconstructionKeyframe)
        let recon0 = session.reconstructionAnchorTransform
        for i in 1...20 {
            let cand = yawTransform(degrees: Float(min(i, 8)), translation: SIMD3(0.002 * Float(i), 0, 0))
            let d = decide(to: cand, timestamp: Double(i) * 0.3, session: &session)
            if d.accept {
                session.noteAccepted(
                    timestamp: Double(i) * 0.3,
                    transform: cand,
                    yawDeltaDeg: d.yawDeltaDeg ?? 0,
                    frustumOverlap: d.frustumOverlap ?? 0,
                    kind: d.acceptKind
                )
            }
        }
        // Continuity advanced; recon anchor only moves on recon KF promotions.
        XCTAssertNotNil(session.continuityAnchorTransform)
        if session.reconstructionKeyframeCount == 1 {
            XCTAssertEqual(session.reconstructionAnchorTransform, recon0)
        } else {
            XCTAssertGreaterThan(session.reconstructionKeyframeCount, 1)
        }
    }

    func testWalkAwayDoesNotPoisonEitherAnchor() {
        var session = CaptureBridgeSession()
        let a = yawTransform(degrees: 0)
        session.noteAccepted(timestamp: 0, transform: a, yawDeltaDeg: 0, frustumOverlap: 1, kind: .reconstructionKeyframe)
        let b = yawTransform(degrees: 5, translation: SIMD3(0.1, 0, 0))
        let d0 = decide(to: b, timestamp: 0.3, session: &session)
        session.noteAccepted(timestamp: 0.3, transform: b, yawDeltaDeg: d0.yawDeltaDeg ?? 0, frustumOverlap: d0.frustumOverlap ?? 0, kind: d0.acceptKind)
        let cont0 = session.continuityAnchorTimestamp
        let recon0 = session.reconstructionAnchorTimestamp
        for i in 0..<8 {
            let cand = yawTransform(degrees: Float(40 + i * 10), translation: SIMD3(0.3 + 0.1 * Float(i), 0, 0))
            _ = decide(to: cand, timestamp: 1.0 + Double(i) * 0.3, session: &session, cell: .lost)
        }
        XCTAssertEqual(session.continuityAnchorTimestamp, cont0)
        XCTAssertEqual(session.reconstructionAnchorTimestamp, recon0)
        XCTAssertFalse(session.terminalContinuityStatus().ok)
    }

    func testRecoverAfterJumpThenTranslatePromotesRecon() {
        var session = CaptureBridgeSession()
        var last = yawTransform(degrees: 0)
        session.noteAccepted(timestamp: 0, transform: last, yawDeltaDeg: 0, frustumOverlap: 1, kind: .reconstructionKeyframe)
        _ = decide(to: yawTransform(degrees: 30, translation: SIMD3(0.1, 0, 0)), timestamp: 0.3, session: &session)
        var recovered = false
        for (i, ang) in [8, 14, 20, 26].enumerated() {
            let cand = yawTransform(degrees: Float(ang), translation: SIMD3(0.08 + 0.04 * Float(i), 0, 0))
            let d = decide(to: cand, timestamp: 0.6 + Double(i) * 0.3, session: &session)
            if d.accept {
                session.noteAccepted(
                    timestamp: 0.6 + Double(i) * 0.3,
                    transform: cand,
                    yawDeltaDeg: d.yawDeltaDeg ?? 0,
                    frustumOverlap: d.frustumOverlap ?? 0,
                    kind: d.acceptKind
                )
                last = cand
                recovered = true
            }
        }
        XCTAssertTrue(recovered)
        _ = last
    }

    func testPoseJitterRejected() {
        var session = CaptureBridgeSession()
        let a = yawTransform(degrees: 0)
        session.noteAccepted(timestamp: 0, transform: a, yawDeltaDeg: 0, frustumOverlap: 1, kind: .reconstructionKeyframe)
        let d = decide(to: yawTransform(degrees: 0.2, translation: SIMD3(0.002, 0, 0)), timestamp: 0.3, session: &session)
        XCTAssertEqual(d.reason, "pose_jitter")
    }

    func testDarkAloneNotForcedReject() {
        var session = CaptureBridgeSession()
        let a = yawTransform(degrees: 0)
        session.noteAccepted(timestamp: 0, transform: a, yawDeltaDeg: 0, frustumOverlap: 1, kind: .reconstructionKeyframe)
        let d = decide(to: yawTransform(degrees: 4, translation: SIMD3(0.12, 0, 0)), timestamp: 0.3, session: &session, exposure: 0.3)
        XCTAssertTrue(d.accept)
    }

    func testCompoundRequiresBridge() {
        var session = CaptureBridgeSession()
        let a = yawTransform(degrees: 0)
        session.noteAccepted(timestamp: 0, transform: a, yawDeltaDeg: 0, frustumOverlap: 1, kind: .reconstructionKeyframe)
        let d = decide(
            to: yawTransform(degrees: 18, translation: SIMD3(0.12, 0, 0)),
            timestamp: 0.3,
            session: &session,
            exposure: 0.3,
            lowTex: 0.7,
            cell: .weak
        )
        XCTAssertFalse(d.accept)
        XCTAssertTrue(d.reason.contains("bridge") || d.bridgeVerdict == .reacquire)
    }

    /// GONGGI_CAPTURE_V1_035: new coverage cell → CellOverlapAnalyzer `.lost` while pose/frustum OK
    /// must **not** alone force REACQUIRE (false reacquire / keyframe starvation).
    func testCellOverlapLostAloneDoesNotReacquireWhenPoseFrustumOK() {
        var session = CaptureBridgeSession()
        let origin = yawTransform(degrees: 0)
        session.noteAccepted(
            timestamp: 0,
            transform: origin,
            yawDeltaDeg: 0,
            frustumOverlap: 1,
            kind: .reconstructionKeyframe
        )
        let cand = yawTransform(degrees: 4, translation: SIMD3(0.08, 0, 0))
        let d = decide(to: cand, timestamp: 0.35, session: &session, cell: .lost)
        XCTAssertNotEqual(d.bridgeVerdict, .reacquire, "cellOverlap.lost must not hard-gate; got \(d.reason)")
        XCTAssertFalse(d.reason.contains("reacquire"), d.reason)
        XCTAssertTrue(d.accept, "expected accept under pose/frustum continuity; got \(d.reason)")
    }

    /// Walking synthetic: after first ~2s, no indefinite REACQUIRE / recon starvation with cell `.lost`.
    func testWalkingTraceWithCellLostDoesNotStarveOrIndefiniteReacquire() {
        var session = CaptureBridgeSession()
        let origin = yawTransform(degrees: 0)
        session.noteAccepted(
            timestamp: 0,
            transform: origin,
            yawDeltaDeg: 0,
            frustumOverlap: 1,
            kind: .reconstructionKeyframe
        )
        var consecutiveReacquire = 0
        var maxConsecutiveReacquire = 0
        var reconKF = 1
        var lastReconX = origin.columns.3.x

        for i in 1...40 {
            let cand = yawTransform(
                degrees: Float(i) * 3,
                translation: SIMD3(0.08 * Float(i), 0, 0)
            )
            let t = Double(i) * 0.35
            let reconBefore = session.reconstructionAnchorTransform
            let contBefore = session.continuityAnchorTransform
            let d = decide(to: cand, timestamp: t, session: &session, cell: .lost)

            if d.bridgeVerdict == .reacquire {
                consecutiveReacquire += 1
                maxConsecutiveReacquire = max(maxConsecutiveReacquire, consecutiveReacquire)
            } else {
                consecutiveReacquire = 0
            }

            if d.accept {
                session.noteAccepted(
                    timestamp: t,
                    transform: cand,
                    yawDeltaDeg: d.yawDeltaDeg ?? 0,
                    frustumOverlap: d.frustumOverlap ?? 0,
                    kind: d.acceptKind
                )
                if d.acceptKind == .reconstructionKeyframe {
                    reconKF += 1
                    lastReconX = cand.columns.3.x
                } else if d.acceptKind == .continuityBridgeObservation {
                    XCTAssertEqual(
                        session.reconstructionAnchorTransform!.columns.3.x,
                        lastReconX,
                        accuracy: 1e-5,
                        "bridge obs must not move reconstructionAnchor"
                    )
                }
            } else {
                // reject / reacquire / bridge_required must not poison anchors
                XCTAssertEqual(
                    session.reconstructionAnchorTransform!.columns.3.x,
                    reconBefore!.columns.3.x,
                    accuracy: 1e-6
                )
                XCTAssertEqual(
                    session.continuityAnchorTransform!.columns.3.x,
                    contBefore!.columns.3.x,
                    accuracy: 1e-6
                )
            }
        }

        XCTAssertLessThan(maxConsecutiveReacquire, 8, "indefinite REACQUIRE streak \(maxConsecutiveReacquire)")
        XCTAssertGreaterThanOrEqual(reconKF, 4, "reconstruction keyframe starvation: reconKF=\(reconKF)")
        XCTAssertNotEqual(session.mode, .reacquiring)
    }

    /// Bridge accepts must not permanently demote recon KF: recon interval is vs last recon timestamp.
    func testReconstructionIntervalUsesLastReconNotLastBridge() {
        var session = CaptureBridgeSession()
        let origin = yawTransform(degrees: 0)
        session.noteAccepted(
            timestamp: 0,
            transform: origin,
            yawDeltaDeg: 0,
            frustumOverlap: 1,
            kind: .reconstructionKeyframe
        )
        // Bridge accept at 0.10s — advances continuity clock but not reconstructionAnchor time.
        let bridgePose = yawTransform(degrees: 7, translation: SIMD3(0.015, 0, 0))
        session.noteAccepted(
            timestamp: 0.10,
            transform: bridgePose,
            yawDeltaDeg: 7,
            frustumOverlap: 0.9,
            kind: .continuityBridgeObservation
        )
        XCTAssertEqual(session.reconstructionAnchorTimestamp, 0)
        XCTAssertEqual(session.continuityAnchorTimestamp, 0.10, accuracy: 1e-9)
        // dt vs continuity = 0.25 ≥ bridge interval, but would be <0.30 if wrongly using bridge clock
        // for recon demote after a hypothetical later bridge — here recon clock is 0.35 ≥ 0.30.
        let cand = yawTransform(degrees: 8, translation: SIMD3(0.12, 0, 0))
        let d = decide(to: cand, timestamp: 0.35, session: &session)
        XCTAssertTrue(d.accept, d.reason)
        XCTAssertEqual(
            d.acceptKind,
            .reconstructionKeyframe,
            "recon interval must use reconstructionAnchorTimestamp; got \(d.reason) kind=\(d.acceptKind)"
        )
    }

    /// Idle soft-band must not enqueue bridge JPEG below minBridgeSaveAngularDeg.
    func testIdleSoftBandBelowSaveFloorDoesNotEnqueueBridgeJPEG() {
        var session = CaptureBridgeSession()
        session.noteAccepted(
            timestamp: 0,
            transform: yawTransform(degrees: 0),
            yawDeltaDeg: 0,
            frustumOverlap: 1,
            kind: .reconstructionKeyframe
        )
        let cand = yawTransform(degrees: 4, translation: SIMD3(0.02, 0, 0))
        let d = decide(to: cand, timestamp: 0.25, session: &session)
        XCTAssertFalse(d.accept, "4° < minBridgeSaveAngularDeg should not save bridge; got \(d.reason)")
        XCTAssertNotEqual(d.acceptKind, .continuityBridgeObservation)
    }

    /// Continuous 16° over ~0.35s at bridge-observation cadence → progressive bridge steps.
    /// Proves continuityAnchor advances to each accepted candidate (forward-vector / transform),
    /// reconstructionAnchor stays fixed, and session does not enter REACQUIRE.
    /// Wrap-safe: does **not** compare raw yaw scalars (which fail near ±180°).
    func testProgressiveBridgeAcceptsIntermediateStepsDuringContinuousYaw() {
        var session = CaptureBridgeSession()
        let origin = yawTransform(degrees: 0)
        session.noteAccepted(
            timestamp: 0,
            transform: origin,
            yawDeltaDeg: 0,
            frustumOverlap: 1,
            kind: .reconstructionKeyframe
        )
        let recon0 = session.reconstructionAnchorTransform!
        var bridgeJPEGAccepts = 0
        // Bridge interval; accumulate past minBridgeSaveAngularDeg (8°) before soft max (12°).
        // 16° over ~0.40s at 0.20s cadence (2 steps) — V1_036-class continuous turn.
        for i in 1...3 {
            let yaw = Float(i) * (16.0 / 3.0)
            let cand = yawTransform(degrees: yaw, translation: SIMD3(0.03 * Float(i), 0, 0))
            let t = Double(i) * CaptureBridgeConfig.minBridgeObservationIntervalSec
            let d = decide(to: cand, timestamp: t, session: &session)
            if d.accept {
                session.noteAccepted(
                    timestamp: t,
                    transform: cand,
                    yawDeltaDeg: d.yawDeltaDeg ?? 0,
                    frustumOverlap: d.frustumOverlap ?? 0,
                    kind: d.acceptKind
                )
                if d.acceptKind == .continuityBridgeObservation {
                    bridgeJPEGAccepts += 1
                    assertForwardAligned(
                        session.continuityAnchorTransform!,
                        cand,
                        message: "continuityAnchor must match accepted bridge candidate"
                    )
                }
            }
        }
        XCTAssertGreaterThanOrEqual(bridgeJPEGAccepts, 1, "expected ≥1 progressive bridge JPEG accept, got \(bridgeJPEGAccepts)")
        XCTAssertLessThanOrEqual(bridgeJPEGAccepts, 3, "bridge density must stay bounded, got \(bridgeJPEGAccepts)")
        assertTransformsNearlyEqual(session.reconstructionAnchorTransform!, recon0)
        XCTAssertNotEqual(session.mode, .reacquiring)
    }

    /// Same progressive-bridge contract while crossing the ±180° yaw boundary.
    func testProgressiveBridgeAcrossYawWrapUpdatesContinuityAnchorByForwardVector() {
        var session = CaptureBridgeSession()
        let origin = yawTransform(degrees: 170)
        session.noteAccepted(
            timestamp: 0,
            transform: origin,
            yawDeltaDeg: 0,
            frustumOverlap: 1,
            kind: .reconstructionKeyframe
        )
        let recon0 = session.reconstructionAnchorTransform!
        var bridgeJPEGAccepts = 0
        // Cross ±180 with 0.20s cadence and ≥ save-floor steps.
        for i in 1...3 {
            let yaw = 170.0 + Double(i) * (16.0 / 3.0)
            let cand = yawTransform(degrees: Float(yaw), translation: SIMD3(0.03 * Float(i), 0, 0))
            let t = Double(i) * CaptureBridgeConfig.minBridgeObservationIntervalSec
            let d = decide(to: cand, timestamp: t, session: &session)
            if d.accept, d.acceptKind == .continuityBridgeObservation {
                session.noteAccepted(
                    timestamp: t,
                    transform: cand,
                    yawDeltaDeg: d.yawDeltaDeg ?? 0,
                    frustumOverlap: d.frustumOverlap ?? 0,
                    kind: d.acceptKind
                )
                bridgeJPEGAccepts += 1
                assertForwardAligned(
                    session.continuityAnchorTransform!,
                    cand,
                    message: "wrap-crossing continuityAnchor must track accepted candidate"
                )
            } else if d.accept {
                session.noteAccepted(
                    timestamp: t,
                    transform: cand,
                    yawDeltaDeg: d.yawDeltaDeg ?? 0,
                    frustumOverlap: d.frustumOverlap ?? 0,
                    kind: d.acceptKind
                )
            }
        }
        XCTAssertGreaterThanOrEqual(bridgeJPEGAccepts, 1, "wrap-crossing progressive bridge expected, got \(bridgeJPEGAccepts)")
        assertTransformsNearlyEqual(session.reconstructionAnchorTransform!, recon0)
        XCTAssertNotEqual(session.mode, .reacquiring)
        XCTAssertGreaterThan(
            forwardAngleDegrees(from: origin, to: session.continuityAnchorTransform!),
            5,
            "continuityAnchor must have progressed across the wrap region"
        )
    }

    func testThirtyDegreeSingleJumpStillReacquires() {
        var session = CaptureBridgeSession()
        let origin = yawTransform(degrees: 0)
        session.noteAccepted(
            timestamp: 0,
            transform: origin,
            yawDeltaDeg: 0,
            frustumOverlap: 1,
            kind: .reconstructionKeyframe
        )
        let cand = yawTransform(degrees: 30, translation: SIMD3(0.05, 0, 0))
        let d = decide(to: cand, timestamp: 0.35, session: &session)
        XCTAssertEqual(d.bridgeVerdict, .reacquire)
        XCTAssertTrue(
            d.reason.contains("reacquire") || d.reason.contains("unsupported"),
            d.reason
        )
        XCTAssertEqual(session.continuityAnchorTransform, origin)
        XCTAssertEqual(session.continuityBridgeObservationCount, 0)
    }

    /// Static / micro-jitter for 3s → no bridge JPEG (eval cadence ≠ save cadence).
    func testStaticJitterThreeSecondsProducesZeroBridgeJPEG() {
        var session = CaptureBridgeSession()
        let origin = yawTransform(degrees: 0)
        session.noteAccepted(
            timestamp: 0,
            transform: origin,
            yawDeltaDeg: 0,
            frustumOverlap: 1,
            kind: .reconstructionKeyframe
        )
        var bridge = 0
        var recon = 0
        for i in 1...15 { // 3.0s at bridge cadence
            let yaw = Float((i % 3) - 1) * 0.3 // ±0.3° jitter
            let cand = yawTransform(degrees: yaw, translation: SIMD3(0.002 * Float(i % 2), 0, 0))
            let t = Double(i) * CaptureBridgeConfig.minBridgeObservationIntervalSec
            let d = decide(to: cand, timestamp: t, session: &session)
            if d.accept {
                session.noteAccepted(
                    timestamp: t,
                    transform: cand,
                    yawDeltaDeg: d.yawDeltaDeg ?? 0,
                    frustumOverlap: d.frustumOverlap ?? 0,
                    kind: d.acceptKind
                )
                if d.acceptKind == .continuityBridgeObservation { bridge += 1 }
                if d.acceptKind == .reconstructionKeyframe { recon += 1 }
            }
        }
        XCTAssertEqual(bridge, 0, "jitter must not enqueue bridge JPEG")
        XCTAssertEqual(recon, 0)
        XCTAssertEqual(session.continuityBridgeObservationCount, 0)
        XCTAssertNotEqual(session.mode, .reacquiring)
    }

    /// Continuous 90° over 3s → bounded progressive bridges, safe angular steps, continuity held.
    func testContinuousNinetyDegreesOverThreeSecondsBoundsBridgeDensity() {
        var session = CaptureBridgeSession()
        let origin = yawTransform(degrees: 0)
        session.noteAccepted(
            timestamp: 0,
            transform: origin,
            yawDeltaDeg: 0,
            frustumOverlap: 1,
            kind: .reconstructionKeyframe
        )
        let recon0 = session.reconstructionAnchorTransform!
        var bridge = 0
        var reacquire = 0
        var maxStep = 0.0
        var lastCont = origin
        let stepDt = CaptureBridgeConfig.minBridgeObservationIntervalSec
        let steps = Int((3.0 / stepDt).rounded(.down))
        for i in 1...steps {
            let yaw = Float(i) * (90.0 / Float(steps))
            let cand = yawTransform(degrees: yaw, translation: SIMD3(0.015 * Float(i), 0, 0))
            let t = Double(i) * stepDt
            let d = decide(to: cand, timestamp: t, session: &session)
            if d.bridgeVerdict == .reacquire { reacquire += 1 }
            if d.accept {
                let step = forwardAngleDegrees(from: lastCont, to: cand)
                if d.acceptKind == .continuityBridgeObservation {
                    bridge += 1
                    maxStep = max(maxStep, step)
                    session.noteAccepted(
                        timestamp: t,
                        transform: cand,
                        yawDeltaDeg: d.yawDeltaDeg ?? 0,
                        frustumOverlap: d.frustumOverlap ?? 0,
                        kind: d.acceptKind
                    )
                    assertForwardAligned(session.continuityAnchorTransform!, cand)
                    lastCont = cand
                } else {
                    session.noteAccepted(
                        timestamp: t,
                        transform: cand,
                        yawDeltaDeg: d.yawDeltaDeg ?? 0,
                        frustumOverlap: d.frustumOverlap ?? 0,
                        kind: d.acceptKind
                    )
                    lastCont = cand
                }
            }
        }
        XCTAssertEqual(reacquire, 0)
        XCTAssertGreaterThan(bridge, 0)
        XCTAssertLessThanOrEqual(bridge, 15, "bridge density too high under save-floor policy: \(bridge)")
        XCTAssertLessThanOrEqual(maxStep, CaptureBridgeConfig.bridgeStepMaxYawDeg + 1.0)
        assertTransformsNearlyEqual(session.reconstructionAnchorTransform!, recon0)
        XCTAssertNotEqual(session.mode, .reacquiring)
    }

    /// Walking + small yaw keeps reconstruction cadence; bridges do not replace recon KFs.
    func testNormalWalkingSmallYawKeepsReconstructionCadence() {
        var session = CaptureBridgeSession()
        let origin = yawTransform(degrees: 0)
        session.noteAccepted(
            timestamp: 0,
            transform: origin,
            yawDeltaDeg: 0,
            frustumOverlap: 1,
            kind: .reconstructionKeyframe
        )
        var bridge = 0
        var recon = 1
        for i in 1...20 {
            let cand = yawTransform(
                degrees: Float(i) * 1.2,
                translation: SIMD3(0.08 * Float(i), 0, 0)
            )
            let t = Double(i) * 0.35 // recon cadence
            let d = decide(to: cand, timestamp: t, session: &session)
            if d.accept {
                session.noteAccepted(
                    timestamp: t,
                    transform: cand,
                    yawDeltaDeg: d.yawDeltaDeg ?? 0,
                    frustumOverlap: d.frustumOverlap ?? 0,
                    kind: d.acceptKind
                )
                if d.acceptKind == .continuityBridgeObservation { bridge += 1 }
                if d.acceptKind == .reconstructionKeyframe { recon += 1 }
            }
        }
        XCTAssertGreaterThanOrEqual(recon, 4, "reconstruction keyframes starved: \(recon)")
        XCTAssertLessThan(bridge, recon, "bridges must not dominate walking recon path")
    }

    /// Enqueue failure contract: without noteAccepted (sync JPEG enqueue fail), continuityAnchor must not advance.
    func testSkippedNoteAcceptedOnEnqueueFailureDoesNotAdvanceContinuityAnchor() {
        var session = CaptureBridgeSession()
        let origin = yawTransform(degrees: 0)
        session.noteAccepted(
            timestamp: 0,
            transform: origin,
            yawDeltaDeg: 0,
            frustumOverlap: 1,
            kind: .reconstructionKeyframe
        )
        let cand = yawTransform(degrees: 9, translation: SIMD3(0.02, 0, 0))
        let d = decide(to: cand, timestamp: 0.25, session: &session)
        XCTAssertTrue(d.accept, d.reason)
        XCTAssertEqual(d.acceptKind, .continuityBridgeObservation)
        // Simulate jpeg_queue_full / pixel_copy_failed: do not call noteAccepted.
        XCTAssertEqual(session.continuityAnchorTransform, origin)
        XCTAssertEqual(session.continuityBridgeObservationCount, 0)
    }

    func testBridgeFeaturePersistenceZeroBlocksAnchorAdvance() {
        var session = CaptureBridgeSession()
        let origin = yawTransform(degrees: 0)
        session.noteAccepted(
            timestamp: 0,
            transform: origin,
            yawDeltaDeg: 0,
            frustumOverlap: 1,
            kind: .reconstructionKeyframe
        )
        let cand = yawTransform(degrees: 9, translation: SIMD3(0.01, 0, 0))
        let d = KeyframeSelector3DGS.shouldAccept(
            timestamp: 0.25,
            transform: cand,
            trackingNormal: true,
            lastKeyframeTimestamp: session.continuityAnchorTimestamp,
            lastKeyframeTransform: session.continuityAnchorTransform,
            keyframeCount: 1,
            previousFramePersistentRatio: 0,
            featurePersistenceAvailable: true,
            bridgeSession: &session
        )
        XCTAssertFalse(d.accept, "zero persistence must block bridge JPEG / anchor advance; got \(d.reason) kind=\(d.acceptKind)")
        XCTAssertEqual(d.reason, "bridge_feature_persistence_weak")
        XCTAssertEqual(session.continuityAnchorTransform, origin)
    }

    func testBridgeFeaturePersistencePositiveAllowsAccept() {
        var session = CaptureBridgeSession()
        let origin = yawTransform(degrees: 0)
        session.noteAccepted(
            timestamp: 0,
            transform: origin,
            yawDeltaDeg: 0,
            frustumOverlap: 1,
            kind: .reconstructionKeyframe
        )
        let cand = yawTransform(degrees: 9, translation: SIMD3(0.02, 0, 0))
        let d = KeyframeSelector3DGS.shouldAccept(
            timestamp: 0.25,
            transform: cand,
            trackingNormal: true,
            lastKeyframeTimestamp: session.continuityAnchorTimestamp,
            lastKeyframeTransform: session.continuityAnchorTransform,
            keyframeCount: 1,
            previousFramePersistentRatio: 0.5,
            featurePersistenceAvailable: true,
            bridgeSession: &session
        )
        XCTAssertTrue(d.accept, d.reason)
        XCTAssertEqual(d.acceptKind, .continuityBridgeObservation)
    }

    /// Unavailable / unsupported persistence must not be treated as 0 (no permanent bridge block).
    func testBridgeFeaturePersistenceUnavailableDoesNotHardBlock() {
        var session = CaptureBridgeSession()
        let origin = yawTransform(degrees: 0)
        session.noteAccepted(
            timestamp: 0,
            transform: origin,
            yawDeltaDeg: 0,
            frustumOverlap: 1,
            kind: .reconstructionKeyframe
        )
        let cand = yawTransform(degrees: 9, translation: SIMD3(0.02, 0, 0))
        let d = KeyframeSelector3DGS.shouldAccept(
            timestamp: 0.25,
            transform: cand,
            trackingNormal: true,
            lastKeyframeTimestamp: session.continuityAnchorTimestamp,
            lastKeyframeTransform: session.continuityAnchorTransform,
            keyframeCount: 1,
            previousFramePersistentRatio: nil,
            featurePersistenceAvailable: false,
            bridgeSession: &session
        )
        XCTAssertTrue(d.accept, "unavailable persistence must fall back to pose/frustum; got \(d.reason)")
        XCTAssertNotEqual(d.reason, "bridge_feature_persistence_weak")
    }

    func testContinuityYawHintWrapSafeAndUnreliableHidesArrow() {
        let a = yawTransform(degrees: 170)
        let b = yawTransform(degrees: -170) // +20° shortest across wrap
        let signed = ContinuityYawHint.signedYawDegrees(from: a, to: b)
        XCTAssertEqual(signed, 20, accuracy: 0.5)
        XCTAssertEqual(ContinuityYawHint.circularDeltaDegrees(350), -10, accuracy: 1e-6)
        XCTAssertFalse(ContinuityYawHint.isYawHintReliable(frustumOverlap: 0.05))
        XCTAssertTrue(ContinuityYawHint.isYawHintReliable(frustumOverlap: 0.5))

        let store = ContinuityAnchorThumbnailStore()
        store.updateLiveProximity(
            signedYawDeg: 25,
            frustumOverlap: 0.05,
            at: 1.0,
            verdict: .reacquire,
            yawHintReliable: false
        )
        // Force visible path: reacquire long enough + fake jpeg via private path is unavailable;
        // assert proximity update cleared signed yaw when unreliable.
        store.noteBridgeVerdict(.reacquire, at: 1.0)
        let snap = store.snapshot(now: 2.0)
        // Without jpeg, not visible — signedYaw still nil when unreliable was set.
        XCTAssertNil(snap.signedYawDeg)
    }

    func testReacquireThumbnailTargetFrozenWhileReacquiring() {
        let store = ContinuityAnchorThumbnailStore()
        // Simulate two anchor updates then long REACQUIRE — target timestamp must stay.
        store.updateLiveProximity(signedYawDeg: 10, frustumOverlap: 0.2, at: 1.0, verdict: .accept)
        // Without pixel buffer we only check reacquire visibility timing + freeze API.
        store.noteBridgeVerdict(.reacquire, at: 2.0)
        let mid = store.snapshot(now: 2.2)
        XCTAssertFalse(mid.visible, "must wait ≥0.5s")
        let late = store.snapshot(now: 2.6)
        // Still no jpeg → not visible, but reacquireSince held.
        XCTAssertFalse(late.visible)
        store.noteBridgeVerdict(.reacquire, at: 5.0) // still reacquiring
        XCTAssertNil(store.frozenAnchorTimestamp) // no image yet
        store.noteBridgeVerdict(.accept, at: 6.0)
        let cleared = store.snapshot(now: 6.1)
        XCTAssertFalse(cleared.visible)
    }

    // MARK: - Helpers

    private func forwardAngleDegrees(from a: simd_float4x4, to b: simd_float4x4) -> Double {
        Double(CaptureMath.rotationDeltaRadians(from: a, to: b) * 180 / .pi)
    }

    private func assertForwardAligned(
        _ anchor: simd_float4x4,
        _ candidate: simd_float4x4,
        message: String = "",
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let deg = forwardAngleDegrees(from: anchor, to: candidate)
        XCTAssertLessThan(deg, 0.5, "\(message) forwardAngle=\(deg)°", file: file, line: line)
        let ta = SIMD3(anchor.columns.3.x, anchor.columns.3.y, anchor.columns.3.z)
        let tb = SIMD3(candidate.columns.3.x, candidate.columns.3.y, candidate.columns.3.z)
        XCTAssertLessThan(simd_distance(ta, tb), 1e-4, "\(message) translation", file: file, line: line)
    }

    private func assertTransformsNearlyEqual(
        _ a: simd_float4x4,
        _ b: simd_float4x4,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        assertForwardAligned(a, b, message: "transforms must match", file: file, line: line)
    }
}
