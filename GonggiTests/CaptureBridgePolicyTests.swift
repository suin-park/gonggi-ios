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
            let cand = yawTransform(degrees: Float(i * 5))
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

    /// Continuous 16° over ~0.35s at bridge-observation cadence → progressive bridge steps.
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
        var bridgeJPEGAccepts = 0
        var lastContYaw: Float = 0
        // Bridge interval 0.05s; ~2.3°/step keeps each step inside bridgeStepMax.
        for i in 1...7 {
            let yaw = Float(i) * (16.0 / 7.0)
            let cand = yawTransform(degrees: yaw, translation: SIMD3(0.02 * Float(i), 0, 0))
            let t = Double(i) * 0.05
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
                    let contYaw = FrustumOverlapProxy.yawDegrees(from: session.continuityAnchorTransform!)
                    XCTAssertGreaterThan(contYaw, lastContYaw - 0.01, "anchor must step forward")
                    lastContYaw = contYaw
                }
            }
        }
        XCTAssertGreaterThanOrEqual(bridgeJPEGAccepts, 2, "expected progressive bridge steps, got \(bridgeJPEGAccepts)")
        XCTAssertNotEqual(session.mode, .reacquiring)
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
        let cand = yawTransform(degrees: 4, translation: SIMD3(0.01, 0, 0))
        let d = KeyframeSelector3DGS.shouldAccept(
            timestamp: 0.08,
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
}
