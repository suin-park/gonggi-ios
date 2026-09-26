import simd
import XCTest
@testable import Gonggi

/// 2026-09-23 living-room capture: after kf_00277 (93.5 s) nothing was saved for 99.4 s —
/// ~3,900 sharp candidates were rejected as `reacquire_unsupported_jump` because the continuity
/// anchor pointed at a view the user never faced again. These tests pin the stale-anchor escape.
final class ReanchorAfterStallTests: XCTestCase {
    private var savedStallSec: Double = 0

    override func setUp() {
        super.setUp()
        savedStallSec = CaptureBridgeConfig.reanchorAfterStallSec
    }

    override func tearDown() {
        CaptureBridgeConfig.reanchorAfterStallSec = savedStallSec
        super.tearDown()
    }

    /// ARKit-style camera pose: yaw about +y, camera looks along -z, positioned at `p`.
    private func pose(yawDeg: Float, _ p: simd_float3 = .zero) -> simd_float4x4 {
        var m = simd_float4x4(simd_quatf(angle: yawDeg * .pi / 180, axis: simd_float3(0, 1, 0)))
        m.columns.3 = simd_float4(p, 1)
        return m
    }

    private func evaluate(_ s: inout CaptureBridgeSession, t: Double, x: simd_float4x4) -> CaptureBridgeDecision {
        let sig = CaptureBridgePolicy.signals(
            continuityAnchor: s.continuityAnchorTransform!,
            reconstructionAnchor: s.reconstructionAnchorTransform,
            candidate: x,
            exposureScore: 0.85,
            lowTextureScore: 0.2,
            cellOverlapState: .good,
            parallaxGrade: .acceptable
        )
        return s.evaluate(timestamp: t, transform: x, signals: sig)
    }

    private func anchored() -> CaptureBridgeSession {
        var s = CaptureBridgeSession()
        s.noteAccepted(timestamp: 0, transform: pose(yawDeg: 0), yawDeltaDeg: 0, frustumOverlap: 1, kind: .reconstructionKeyframe)
        return s
    }

    func testStaleAnchorEscapesOnSteadyViewAfterStall() {
        var s = anchored()
        let away = pose(yawDeg: 130, simd_float3(1.17, 0, 0))
        var first: CaptureBridgeDecision?
        var escapeAt: Double?
        for i in 1...120 {
            let t = Double(i) * 0.05
            let d = evaluate(&s, t: t, x: away)
            if first == nil { first = d }
            if d.reason == CaptureBridgeSession.reanchorReason {
                escapeAt = t
                XCTAssertEqual(d.verdict, .accept)
                XCTAssertEqual(d.acceptKind, .reconstructionKeyframe)
                break
            }
            XCTAssertEqual(d.verdict, .reacquire)
        }
        XCTAssertEqual(first?.reason, "reacquire_unsupported_jump")
        XCTAssertNotNil(escapeAt)
        // Stall ≥ 3 s after the first REACQUIRE (0.05 s) and view steady ≥ 0.5 s.
        XCTAssertGreaterThanOrEqual(escapeAt ?? 0, 3.05 - 1e-6)
        XCTAssertLessThan(escapeAt ?? 99, 3.2)
        XCTAssertEqual(s.reanchorCount, 1)
        XCTAssertEqual(s.mode, .idle)
    }

    func testQuickReturnToLastSavedViewReconnectsWithoutEscape() {
        var s = anchored()
        for i in 1...20 { _ = evaluate(&s, t: Double(i) * 0.05, x: pose(yawDeg: 130)) }
        XCTAssertEqual(s.mode, .reacquiring)
        let back = evaluate(&s, t: 1.2, x: pose(yawDeg: 5, simd_float3(0.05, 0, 0)))
        XCTAssertNotEqual(back.reason, CaptureBridgeSession.reanchorReason)
        XCTAssertNotEqual(back.verdict, .reacquire)
        XCTAssertEqual(s.reanchorCount, 0)
    }

    func testNoEscapeWhileTheCameraKeepsTurning() {
        var s = anchored()
        for i in 1...200 {
            let t = Double(i) * 0.05
            // 20°/s continuous turn far from the anchor: never steady for 0.5 s.
            let d = evaluate(&s, t: t, x: pose(yawDeg: 130 + Float(t) * 20))
            XCTAssertNotEqual(d.reason, CaptureBridgeSession.reanchorReason, "no anchor mid-turn (t=\(t))")
        }
        XCTAssertEqual(s.reanchorCount, 0)
    }

    func testEscapeCanBeDisabled() {
        CaptureBridgeConfig.reanchorAfterStallSec = 0
        var s = anchored()
        for i in 1...200 {
            let d = evaluate(&s, t: Double(i) * 0.05, x: pose(yawDeg: 130))
            XCTAssertEqual(d.reason, "reacquire_unsupported_jump")
        }
        XCTAssertEqual(s.reanchorCount, 0)
    }

    func testContinuityRulesStillApplyInsideTheNewSegment() {
        var s = anchored()
        let away = pose(yawDeg: 130, simd_float3(1.17, 0, 0))
        var t = 0.0
        while t < 5 {
            t += 0.05
            let d = evaluate(&s, t: t, x: away)
            if d.reason == CaptureBridgeSession.reanchorReason {
                // App side: the escape keyframe is saved and becomes the new anchor.
                s.noteAccepted(timestamp: t, transform: away, yawDeltaDeg: 0, frustumOverlap: 1, kind: .reconstructionKeyframe)
                break
            }
        }
        XCTAssertEqual(s.reanchorCount, 1)
        // A 30° jump from the new anchor is still an unsupported jump.
        let jump = evaluate(&s, t: t + 0.4, x: pose(yawDeg: 160, simd_float3(1.17, 0, 0)))
        XCTAssertEqual(jump.reason, "reacquire_unsupported_jump")
    }

    func testSaveStallNoticeOutranksReacquire() {
        var engine = GuidanceRuleEngine()
        var q = CaptureQualityState.zero
        q.trackingQuality = 0.95
        q.bridgeMode = .reacquiring
        q.bridgeVerdict = .reacquire
        q.saveStalledSec = 5
        XCTAssertEqual(engine.evaluateDecision(quality: q, trackingLimited: false).action, .saveStalled)
        q.saveStalledSec = 0
        var fresh = GuidanceRuleEngine()
        XCTAssertEqual(fresh.evaluateDecision(quality: q, trackingLimited: false).action, .reacquireView)
        // Tracking loss still wins over the stall notice.
        q.saveStalledSec = 5
        var tracking = GuidanceRuleEngine()
        XCTAssertEqual(tracking.evaluateDecision(quality: q, trackingLimited: true).action, .trackingRecovery)
        XCTAssertEqual(CaptureUIPresenter.liveCopy(for: .saveStalled).title, "사진이 저장되지 않고 있어요")
    }

    func testSaveContinuitySummarisesGaps() {
        let s = SpatialCaptureSaveContinuity(
            keyframeTimestamps: [0, 0.3, 0.6, 93.5, 192.9, 193.3],
            reanchorCount: 0, stallNoticeEpisodes: 0, longestStallNoticeSec: 0,
            longestCandidateEvaluationGapSec: 19.6
        )
        XCTAssertEqual(s.keyframeCount, 6)
        XCTAssertEqual(s.longestSaveGapSec, 99.4, accuracy: 1e-9)
        XCTAssertEqual(s.saveGapsOver3Sec, 2)
        XCTAssertEqual(s.saveGapsOver10Sec, 2)
    }

    /// Before / after on a reproduction of the living-room event: normal walk-through saves,
    /// then frames stop reaching the selector (8 s), the user ends up facing ~130° away and films
    /// that side for ~67 s with slow pans and pauses, then turns back.
    func testReplayBeforeAfterOnLivingRoomLikeStall() {
        var rows: [PoseReplayHarness.PoseRow] = []
        var t = 0.0
        let dt = 1.0 / 20
        // 0–90 s: walk 4 m while panning ±40° slowly (normal continuity).
        while t < 90 {
            let yaw = Float(40 * sin(t / 9))
            rows.append(.init(timestamp: t, transform: pose(yawDeg: 95 + yaw, simd_float3(0.6, 0, Float(-t / 90 * 4))), trackingNormal: true))
            t += dt
        }
        // 90–98 s: no candidates reach the selector (dropped / blurred turn).
        t = 98
        // 98–165 s: facing ~130° away, slow pans with 1 s pauses, moving 1 m.
        while t < 165 {
            let phase = (t - 98).truncatingRemainder(dividingBy: 6)
            let pan: Float = phase < 1 ? 0 : Float(12 * sin((t - 98) / 4))
            rows.append(.init(timestamp: t, transform: pose(yawDeg: 225 + pan, simd_float3(0.6 - Float(t - 98) / 67, 0, -3.3)), trackingNormal: true))
            t += dt
        }
        // 165–170 s: back toward the original view.
        while t < 170 {
            rows.append(.init(timestamp: t, transform: pose(yawDeg: 100, simd_float3(-0.2, 0, -3.3)), trackingNormal: true))
            t += dt
        }

        CaptureBridgeConfig.reanchorAfterStallSec = 0
        let before = PoseReplayHarness.replay(poses: rows)
        CaptureBridgeConfig.reanchorAfterStallSec = savedStallSec
        let after = PoseReplayHarness.replay(poses: rows)

        print("[REANCHOR] before: saved=\(before.liveN) maxNoSaveSec=\(String(format: "%.1f", before.maxLiveNoAcceptSec)) segments=\(before.liveSegments) chainIntact=\(before.chainIntactLive) linkViolations=\(before.linkViolations)")
        print("[REANCHOR] after:  saved=\(after.liveN) maxNoSaveSec=\(String(format: "%.1f", after.maxLiveNoAcceptSec)) segments=\(after.liveSegments) chainIntact=\(after.chainIntactLive) linkViolations=\(after.linkViolations)")

        XCTAssertGreaterThan(before.maxLiveNoAcceptSec, 60, "reproduces the long no-save window")
        XCTAssertLessThan(after.maxLiveNoAcceptSec, before.maxLiveNoAcceptSec)
        XCTAssertLessThan(after.maxLiveNoAcceptSec, 13, "8 s of no candidates + ≤ ~4 s stall/steady")
        XCTAssertGreaterThan(after.liveN, before.liveN)
        XCTAssertTrue(after.chainIntactLive, "every link inside a segment still passes the link gate")
        XCTAssertGreaterThanOrEqual(after.liveSegments, 2)
    }
}
