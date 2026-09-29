import simd
import XCTest
@testable import Gonggi

/// ARKit pose (y up, camera looks along −z): azimuth 0 = −Z, clockwise toward +X.
private func coachPose(x: Float = 0, y: Float = 1.4, z: Float = 0, azimuth: Float, pitch: Float = -10) -> simd_float4x4 {
    let a = azimuth * .pi / 180, p = pitch * .pi / 180
    let f = simd_float3(sin(a) * cos(p), sin(p), -cos(a) * cos(p))
    let right = simd_normalize(simd_cross(f, simd_float3(0, 1, 0)))
    let up = simd_cross(right, f)
    return simd_float4x4(columns: (simd_float4(right, 0), simd_float4(up, 0), simd_float4(-f, 0), simd_float4(x, y, z, 1)))
}

final class CaptureMotionCoachTests: XCTestCase {
    /// Drives the coach at 30 Hz; saves a photo every 0.3 s. `pose(t)` gives the camera; returns prompts seen.
    @discardableResult
    private func run(_ c: inout CaptureMotionCoach, from t0: TimeInterval, seconds: Double, features: Int? = 200,
                     gapActive: Bool = false, pose: (TimeInterval) -> simd_float4x4) -> [CaptureMotionCoach.Kind] {
        var seen: [CaptureMotionCoach.Kind] = []
        var nextSave = t0
        var t = t0
        while t < t0 + seconds {
            if t >= nextSave {
                c.observeSaved(timestamp: t)
                nextSave += 0.3
            }
            if let p = c.tick(timestamp: t, cameraToWorld: pose(t), rawFeatureCount: features, gapPromptActive: gapActive),
               seen.last != p.kind {
                seen.append(p.kind)
            }
            t += 1.0 / 30
        }
        return seen
    }

    func testTurningOnTheSpotAsksForASideStepAfterTheHold() {
        var c = CaptureMotionCoach()
        // 15°/s on the spot (small sway): the 8 s window reaches its 6 s span, then 3 s hold.
        run(&c, from: 0, seconds: 8.8) { t in coachPose(x: 0.05 * Float(sin(t)), azimuth: Float(15 * t)) }
        XCTAssertNil(c.active, "not before span + hold")
        run(&c, from: 8.8, seconds: 1.0) { t in coachPose(x: 0.05 * Float(sin(t)), azimuth: Float(15 * t)) }
        XCTAssertEqual(c.active?.kind, .sideStep)
        // Stepping 0.6 m sideways resolves it.
        run(&c, from: 9.8, seconds: 1.5) { t in coachPose(x: Float(0.6 * min(1, (t - 9.8))), azimuth: 150) }
        XCTAssertNil(c.active)
        XCTAssertEqual(c.records.first?.resolved, true)
    }

    /// The old baseline hint used the session's best grade: one walk early on and later spins were never flagged.
    func testASpinAfterAnEarlierWalkIsStillCaught() {
        var c = CaptureMotionCoach()
        run(&c, from: 0, seconds: 20) { t in coachPose(x: Float(0.4 * t), azimuth: 90) }  // 8 m walk
        XCTAssertTrue(c.records.isEmpty)
        let seen = run(&c, from: 20, seconds: 12) { t in coachPose(x: 8, azimuth: Float(20 * (t - 20))) }
        XCTAssertEqual(seen, [.sideStep])
    }

    func testWalkingWhileTurningIsNotASpin() {
        var c = CaptureMotionCoach()
        let seen = run(&c, from: 0, seconds: 30) { t in coachPose(x: Float(0.25 * t), azimuth: Float(12 * t)) }
        XCTAssertTrue(seen.isEmpty)
    }

    func testNoPhotosSavedMeansNoSideStepPrompt() {
        var c = CaptureMotionCoach()
        var t: TimeInterval = 0
        while t < 15 {  // spinning but nothing saved (a stall is handled by the continuity guidance instead)
            _ = c.tick(timestamp: t, cameraToWorld: coachPose(azimuth: Float(20 * t)), rawFeatureCount: 200, gapPromptActive: false)
            t += 1.0 / 30
        }
        XCTAssertNil(c.active)
    }

    func testPlainCeilingAsksToLowerAndIncludeTheEdge() {
        var c = CaptureMotionCoach()
        let seen = run(&c, from: 0, seconds: 1.3, features: 8) { _ in coachPose(azimuth: 0, pitch: 55) }
        XCTAssertEqual(seen, [.ceilingContext])
        // A ceiling with the wall edge / lamp in view keeps features: no prompt.
        var d = CaptureMotionCoach()
        XCTAssertTrue(run(&d, from: 0, seconds: 5, features: 180) { _ in coachPose(azimuth: 0, pitch: 55) }.isEmpty)
        // No feature telemetry: the feature-based prompt is not judged.
        var e = CaptureMotionCoach()
        XCTAssertTrue(run(&e, from: 0, seconds: 5, features: nil) { _ in coachPose(azimuth: 0, pitch: 55) }.isEmpty)
    }

    func testLookingDownAtTheFeetIsAPitchOnlyNotice() {
        var c = CaptureMotionCoach()
        XCTAssertTrue(run(&c, from: 0, seconds: 1.8) { _ in coachPose(azimuth: 0, pitch: -70) }.isEmpty)
        run(&c, from: 1.8, seconds: 0.5) { _ in coachPose(azimuth: 0, pitch: -70) }
        XCTAssertEqual(c.active?.kind, .floorFeet)
        let copy = CaptureUIPresenter.coachCopy(c.active!)
        XCTAssertTrue((copy.subtitle ?? "").contains("찍힐 수 있어요"), "says feet may be in the photo")
        XCTAssertFalse((copy.title + (copy.subtitle ?? "")).contains("감지"), "never claims feet were detected")
        // Ordinary floor shots (−55°…−63° in the 414 capture) do not trigger it.
        var d = CaptureMotionCoach()
        XCTAssertTrue(run(&d, from: 0, seconds: 10) { _ in coachPose(azimuth: 0, pitch: -58) }.isEmpty)
    }

    func testBareFloorPromptWaitsWhileAGapPromptIsUp() {
        var c = CaptureMotionCoach()
        XCTAssertTrue(run(&c, from: 0, seconds: 4, features: 10, gapActive: true) { _ in coachPose(azimuth: 0, pitch: -50) }.isEmpty)
        XCTAssertEqual(run(&c, from: 4, seconds: 2, features: 10, gapActive: false) { _ in coachPose(azimuth: 0, pitch: -50) },
                       [.floorContext])
    }

    func testCeilingGuardTakesOverASideStepPrompt() {
        var c = CaptureMotionCoach()
        run(&c, from: 0, seconds: 10) { t in coachPose(azimuth: Float(15 * t)) }
        XCTAssertEqual(c.active?.kind, .sideStep)
        run(&c, from: 10, seconds: 1.2, features: 5) { t in coachPose(azimuth: Float(15 * t), pitch: 55) }
        XCTAssertEqual(c.active?.kind, .ceilingContext)
        XCTAssertEqual(c.records.first?.preempted, true)
    }

    func testUnansweredSideStepGoesAwayAndThatSpotWaitsBeforeAskingAgain() {
        var c = CaptureMotionCoach()
        let spin: (TimeInterval) -> simd_float4x4 = { t in coachPose(azimuth: Float(15 * t)) }
        run(&c, from: 0, seconds: 25, pose: spin)
        XCTAssertEqual(c.records.count, 1, "shown once, gone after 10 s, same spot rests 30 s")
        XCTAssertEqual(c.records[0].closedAtSec ?? 0, c.records[0].shownAtSec + 10, accuracy: 0.1)
        run(&c, from: 25, seconds: 20, pose: spin)
        XCTAssertEqual(c.records.count, 1, "the same spot waits 30 s after the prompt ended")
        run(&c, from: 45, seconds: 10, pose: spin)
        XCTAssertEqual(c.records.count, 2, "one more reminder at the same spot …")
        run(&c, from: 55, seconds: 60, pose: spin)
        XCTAssertEqual(c.records.count, 2, "… then no more")
    }

    func testResetWindowEndsThePromptAndForgetsTheSpin() {
        var c = CaptureMotionCoach()
        run(&c, from: 0, seconds: 10) { t in coachPose(azimuth: Float(15 * t)) }
        XCTAssertNotNil(c.active)
        c.resetWindow(at: 10)
        XCTAssertNil(c.active)
        XCTAssertNil(c.tick(timestamp: 10.1, cameraToWorld: coachPose(azimuth: 0), rawFeatureCount: 200, gapPromptActive: false))
    }
}

final class CaptureGuideV4GuidanceTests: XCTestCase {
    private func quality() -> CaptureQualityState {
        var q = CaptureQualityState.zero
        q.trackingQuality = 0.95
        q.overlapAvailable = true
        q.overlapState = .good
        return q
    }

    private func gap(_ kind: CaptureGapModel.Kind) -> CaptureGapModel.Prompt {
        CaptureGapModel.Prompt(kind: kind, region: .init(x: 0, z: 0), targetAzimuthDeg: 180, targetPitchDeg: 0,
                               turn: .left, shownAt: 0, id: 1)
    }

    private func coach(_ kind: CaptureMotionCoach.Kind) -> CaptureMotionCoach.Prompt {
        CaptureMotionCoach.Prompt(kind: kind, shownAt: 0, id: 1, spot: kind == .sideStep ? .zero : nil)
    }

    private func best(_ q: CaptureQualityState) -> GuidanceDecision {
        GuidanceRuleEngine().bestDecision(quality: q, trackingLimited: false)
    }

    func testOnlyOnePromptAndTheOrderIsGuardThenSideStepThenGapThenFloor() {
        var q = quality()
        q.gapPrompt = gap(.opposite)
        q.coachPrompt = coach(.ceilingContext)
        XCTAssertEqual(best(q).action, .captureCoach)
        q.coachPrompt = coach(.sideStep)
        XCTAssertEqual(best(q).action, .captureCoach, "side step before the gap prompt")
        q.coachPrompt = coach(.floorContext)
        XCTAssertEqual(best(q).action, .captureGap, "bare floor waits for the gap prompt")
        q.gapPrompt = nil
        XCTAssertEqual(best(q).action, .captureCoach)
        q.coachPrompt = coach(.sideStep)
        q.saveStalledSec = 2
        XCTAssertEqual(best(q).action, .saveStalled, "continuity outranks every guide prompt")
    }

    func testCoachPromptNeverBlocksFinishingAndShowsItsOwnCopy() {
        var q = quality()
        q.coachPrompt = coach(.sideStep)
        q.guidanceAction = .captureCoach
        q.completionState = .ready
        q.reconstructionReady = true
        let g = CaptureUIPresenter.primaryGuidance(quality: q)
        XCTAssertEqual(g.title, "한두 걸음 옆으로 옮겨 주세요")
        XCTAssertTrue(g.isReadyToFinish)
    }

    func testCompletionShowsRecommendationsWithoutBlocking() {
        var q = quality()
        q.completionState = .ready
        q.reconstructionReady = true
        q.guidanceAction = .captureComplete
        q.captureRecommendations = CaptureCompletionRecommendation.items(openGaps: [.opposite: 2, .up: 1],
                                                                           savedUpPhotos: 0, savedDownPhotos: 30)
        let g = CaptureUIPresenter.primaryGuidance(quality: q)
        XCTAssertTrue(g.isReadyToFinish)
        XCTAssertEqual(g.title, "촬영이 충분합니다")
        XCTAssertTrue((g.subtitle ?? "").contains("반대 방향 2곳"))
        XCTAssertTrue((g.subtitle ?? "").contains("천장 경계"))
        XCTAssertFalse((g.subtitle ?? "").contains("바닥 경계"))
        q.captureRecommendations = []
        XCTAssertEqual(CaptureUIPresenter.primaryGuidance(quality: q).subtitle, "공간을 충분히 담았어요. 기록을 완료할 수 있어요")
    }

    func testDefaultCopyNoLongerAsksToTurnTheBody() {
        let actions: [GuidanceAction] = [.continueCapture, .needMoreYaw, .needUpperCoverage, .needLowerCoverage,
                                         .moveLaterally, .improveBaseline, .captureNearlyComplete]
        for a in actions {
            let c = CaptureUIPresenter.liveCopy(for: a)
            XCTAssertFalse((c.title + (c.subtitle ?? "")).contains("몸을 돌려"), "\(a)")
        }
        let opp = CaptureUIPresenter.gapCopy(gap(.opposite))
        XCTAssertFalse((opp.title + (opp.subtitle ?? "")).contains("몸을 돌려"))
        let up = CaptureUIPresenter.gapCopy(gap(.up))
        XCTAssertTrue(up.title.contains("경계") || (up.subtitle ?? "").contains("만나는 선"))
        XCTAssertFalse((up.subtitle ?? "").contains("머물러"), "no dwelling on a plain ceiling")
    }

    func testUpPromptIsLimitedToTwoPerCaptureInV4() {
        XCTAssertEqual(CaptureGapModel.Policy.v4.maxUpPrompts, 2)
        XCTAssertEqual(CaptureGapModel.Policy.v4.maxPromptSec, 16)
        XCTAssertEqual(CaptureGapModel.Policy.v3.maxPromptSec, 20)
        XCTAssertEqual(CaptureGapModel().policy, .v4)
    }
}
