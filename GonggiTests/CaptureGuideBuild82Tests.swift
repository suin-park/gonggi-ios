import simd
import XCTest
@testable import Gonggi

/// Build 82 (`CAPTURE_GUIDE_SPACE_SIZE_20260929.md` rev.2 → implementation scope):
/// - completion list with status: 남음 (not asked yet) / 미해결 (asked, still missing) / 사진 한도 — never "enough";
/// - walking copy leaves the way to the user ("걸을 수 있는 쪽으로"), no one-way arrow, no unverified destination;
/// - optional target prompt (`targetStep`): only on a steady ARKit signal, ≤ 2 per capture, flag-controlled.
/// No recorded capture reached the 520-photo limit, so that case uses synthetic input.
final class CaptureGuideBuild82Tests: XCTestCase {
    private let r1 = CaptureGapModel.RegionKey(x: 0, z: 0)
    private let r2 = CaptureGapModel.RegionKey(x: 1, z: 0)

    private func readyQuality() -> CaptureQualityState {
        var q = CaptureQualityState.zero
        q.trackingQuality = 0.95
        q.overlapAvailable = true
        q.overlapState = .good
        q.capturePhase = .readyToFinish
        q.completionState = .ready
        q.reconstructionReady = true
        q.guidanceAction = .captureComplete
        return q
    }

    // MARK: Completion status

    func testAskedAndNotAskedItemsGetTheirOwnStatus() {
        let items = CaptureCompletionRecommendation.remaining(
            openGaps: [(.opposite, r1, true), (.opposite, r2, false), (.up, r1, true)],
            savedUpPhotos: 5, savedDownPhotos: 0, photoLimitReached: false)
        XCTAssertEqual(items, [
            .init(area: .oppositeDirection, count: 1, status: .promptedUnfilled),
            .init(area: .oppositeDirection, count: 1, status: .notPrompted),
            .init(area: .ceilingEdge, count: 1, status: .promptedUnfilled),
            .init(area: .floorEdge, count: 1, status: .notPrompted),
        ])
        XCTAssertEqual(items.map(\.statusLabel), ["미해결", "남음", "미해결", "남음"])
        XCTAssertEqual(items[0].statusDetail, "안내했지만 아직 부족해요")
        XCTAssertEqual(items[1].statusDetail, "아직 담지 않았어요")
        XCTAssertEqual(items[0].shortLine, "반대 방향 1곳(미해결)")
    }

    func testNothingOpenMeansAnEmptyList() {
        XCTAssertTrue(CaptureCompletionRecommendation.remaining(openGaps: [], savedUpPhotos: 5, savedDownPhotos: 5,
                                                                photoLimitReached: false).isEmpty)
    }

    func testAskedItemStaysUnresolvedNotEnoughAndFinishingStaysOpen() {
        var q = readyQuality()
        q.captureRemaining = CaptureCompletionRecommendation.remaining(
            openGaps: [(.opposite, r1, true)], savedUpPhotos: 5, savedDownPhotos: 5, photoLimitReached: false)
        let g = CaptureUIPresenter.primaryGuidance(quality: q)
        XCTAssertTrue(g.isReadyToFinish, "never a finish gate")
        XCTAssertEqual(g.finishButtonTitle, "기록 완료")
        XCTAssertEqual(g.title, "촬영을 마칠 수 있어요")
        XCTAssertFalse(g.title.contains("충분"))
        XCTAssertTrue((g.subtitle ?? "").contains("반대 방향 1곳(미해결)"))
        XCTAssertFalse((g.subtitle ?? "").contains("충분"))
        XCTAssertEqual(CaptureQuietUIPresenter.statusLine(for: q), "기록을 마칠 수 있어요")
        q.captureRemaining = []
        XCTAssertEqual(CaptureUIPresenter.primaryGuidance(quality: q).title, "촬영이 충분합니다")
        XCTAssertEqual(CaptureQuietUIPresenter.statusLine(for: q), "공간이 충분히 기록됐어요")
    }

    /// Synthetic: no recorded capture reached 520 photos.
    func testPhotoLimitKeepsEveryOpenItemAsPhotoLimitNeverEnough() {
        let items = CaptureCompletionRecommendation.remaining(
            openGaps: [(.opposite, r1, true), (.opposite, r2, false), (.up, r1, false)],
            savedUpPhotos: 0, savedDownPhotos: 0, photoLimitReached: true)
        XCTAssertEqual(items, [
            .init(area: .oppositeDirection, count: 2, status: .photoLimit),
            .init(area: .ceilingEdge, count: 1, status: .photoLimit),
            .init(area: .floorEdge, count: 1, status: .photoLimit),
        ])
        XCTAssertTrue(items.allSatisfy { $0.statusLabel == "사진 한도" })
        XCTAssertTrue(items[0].statusDetail.contains("\(SpatialCaptureConfig.candidateSafetyCap)장"))

        var q = readyQuality()
        q.candidateSafetyCapReached = true
        q.captureRemaining = items
        let g = CaptureUIPresenter.primaryGuidance(quality: q)
        XCTAssertTrue(g.isReadyToFinish)
        XCTAssertEqual(g.title, "촬영을 마칠 수 있어요")
        XCTAssertTrue((g.subtitle ?? "").contains("반대 방향 2곳(사진 한도)"))
        XCTAssertEqual(CaptureQuietUIPresenter.statusLine(for: q), "새 사진이 더 이상 저장되지 않습니다")

        let rows = CaptureSummaryPresentation.remainingRows(items)
        XCTAssertEqual(rows.map { $0.status }, ["사진 한도", "사진 한도", "사진 한도"])
        XCTAssertEqual(rows.first?.name, "반대 방향 2곳")
        XCTAssertFalse(rows.contains { $0.detail.contains("충분") })
    }

    /// Synthetic 520-photo capture through the replay: the saved-photo count hits the limit with directions still open.
    func testSyntheticCaptureAtThePhotoLimitReportsPhotoLimit() {
        var frames: [[Double]] = []
        let n = SpatialCaptureConfig.candidateSafetyCap
        for i in 0..<n {
            let t = Double(i) * 0.3
            let x = 0.004 * Double(i)  // slow walk along +x, always facing −z (opposite direction never seen)
            frames.append([t, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, x, 1.4, 0, 1])
        }
        let fx = CaptureGuideReplay.Fixture(label: "synthetic520", savedFrames: frames, featureSamples: [])
        let r = CaptureGuideReplay.replay(fx, policy: .v4)
        XCTAssertFalse(r.remainingAtEnd.isEmpty)
        XCTAssertTrue(r.remainingAtEnd.allSatisfy { $0.status == .photoLimit }, "\(r.remainingAtEnd)")
        XCTAssertTrue(r.remainingAtEnd.contains { $0.area == .oppositeDirection })
        XCTAssertFalse(r.legacyRecommendationsAtEnd.isEmpty)
    }

    func testOpenGapDetailsFollowTheGapModel() {
        var g = CaptureGapModel()
        // 20 photos in one region, all facing −z and level: opposite + up open, never prompted (no region exit).
        for i in 0..<20 {
            let m = simd_float4x4(columns: (simd_float4(1, 0, 0, 0), simd_float4(0, 1, 0, 0), simd_float4(0, 0, 1, 0),
                                            simd_float4(0.5 + 0.01 * Float(i), 1.4, 0.5, 1)))
            g.observeSaved(timestamp: Double(i) * 0.3, cameraToWorld: m)
        }
        let d = g.openGapDetails()
        XCTAssertEqual(Set(d.map { $0.kind.rawValue }), ["opposite", "up"])
        XCTAssertTrue(d.allSatisfy { !$0.prompted })
        XCTAssertEqual(g.openGaps()[.opposite], 1)
    }

    // MARK: Movement copy

    private let allActions: [GuidanceAction] = [
        .continueCapture, .moveLaterally, .moveForward, .slowDown, .holdSteady, .returnToPreviousArea, .scanNewArea,
        .improveBaseline, .trackingRecovery, .lowTextureWarning, .needMoreYaw, .needUpperCoverage, .needLowerCoverage,
        .bridgeContinuity, .reacquireView, .saveStalled, .captureGap, .captureCoach, .finishBlockedWeakTerminal,
        .captureNearlyComplete, .captureComplete,
    ]

    private func gapPrompt(_ kind: CaptureGapModel.Kind, turn: CaptureGapModel.Turn) -> CaptureGapModel.Prompt {
        CaptureGapModel.Prompt(kind: kind, region: r1, targetAzimuthDeg: 90, targetPitchDeg: 0, turn: turn, shownAt: 0, id: 1)
    }

    func testNoArrowPicksANewWalkingPath() {
        for a in allActions {
            XCTAssertNotEqual(CaptureUIPresenter.direction(for: a), .forward, "\(a)")
        }
        XCTAssertEqual(CaptureUIPresenter.direction(for: .returnToPreviousArea), .returnBack, "back to an area already filmed")
    }

    func testWalkingCopyLeavesTheWayToTheUser() {
        var texts: [String] = []
        for a in allActions {
            let c = CaptureUIPresenter.liveCopy(for: a)
            texts.append(c.title + " " + (c.subtitle ?? ""))
        }
        for k in CaptureGapModel.Kind.allCases {
            for turn in [CaptureGapModel.Turn.ahead, .left, .right, .behind] {
                let c = CaptureUIPresenter.gapCopy(gapPrompt(k, turn: turn))
                texts.append(c.title + " " + (c.subtitle ?? ""))
            }
        }
        for k in CaptureMotionCoach.Kind.allCases {
            let c = CaptureUIPresenter.coachCopy(.init(kind: k, shownAt: 0, id: 1, spot: nil))
            texts.append(c.title + " " + (c.subtitle ?? ""))
        }
        for t in texts {
            XCTAssertFalse(t.contains("끝까지 천천히 걸어가"), t)
            XCTAssertFalse(t.contains("표시된 지점"), t)
            XCTAssertFalse(t.contains("옆으로 걸어 주세요"), t)
            XCTAssertFalse(t.contains("몸을 돌려"), t)
        }
        XCTAssertTrue(CaptureUIPresenter.liveCopy(for: .moveLaterally).title.contains("걸을 수 있는 쪽"))
        XCTAssertTrue(CaptureUIPresenter.coachCopy(.init(kind: .sideStep, shownAt: 0, id: 1, spot: .zero)).title.contains("걸을 수 있는 쪽"))
        let far = CaptureUIPresenter.gapCopy(gapPrompt(.farEnd, turn: .left))
        XCTAssertTrue((far.subtitle ?? "").contains("걸어갈 수 있으면"))
        let tops = CaptureUIPresenter.gapCopy(gapPrompt(.tops, turn: .right))
        XCTAssertTrue((tops.subtitle ?? "").contains("다가갈 수 있으면"))
        let opp = CaptureUIPresenter.gapCopy(gapPrompt(.opposite, turn: .left))
        XCTAssertTrue((opp.subtitle ?? "").contains("걸을 수 있는 쪽"))
        let target = CaptureUIPresenter.coachCopy(.init(kind: .targetStep, shownAt: 0, id: 1, spot: .zero))
        XCTAssertEqual(target.title, "지금 보이는 곳을 화면에 둔 채 걸을 수 있는 쪽으로 두세 걸음 옮겨 주세요")
        for side in ["왼쪽", "오른쪽", "앞쪽", "뒤쪽"] {
            XCTAssertFalse(target.title.contains(side) || (target.subtitle ?? "").contains(side), "no side chosen for the user")
        }
    }

    // MARK: Optional target prompt (coach)

    private func signal(_ keys: Set<String> = ["v:1", "v:2", "v:3"], candidates: Int = 5, share: Float = 0.8,
                        progress: Float? = nil) -> CaptureTargetSignal {
        CaptureTargetSignal(candidates: candidates, narrowKeys: keys, narrowAreaShare: share, activeProgress: progress)
    }

    private func standing(x: Float) -> simd_float4x4 {
        simd_float4x4(columns: (simd_float4(1, 0, 0, 0), simd_float4(0, 1, 0, 0), simd_float4(0, 0, 1, 0), simd_float4(x, 1.4, 0, 1)))
    }

    /// 30 Hz, a saved photo every 0.3 s, standing still facing −z (not a spin).
    @discardableResult
    private func drive(_ c: inout CaptureMotionCoach, from t0: Double, to t1: Double, features: Int? = 200,
                       gapActive: Bool = false, x: Float = 0,
                       target: (Double, CaptureMotionCoach) -> CaptureTargetSignal?) -> [CaptureMotionCoach.Kind] {
        var seen: [CaptureMotionCoach.Kind] = []
        var t = t0, nextSave = t0
        while t < t1 {
            if t >= nextSave { c.observeSaved(timestamp: t); nextSave += 0.3 }
            if let p = c.tick(timestamp: t, cameraToWorld: standing(x: x), rawFeatureCount: features,
                              gapPromptActive: gapActive, target: target(t, c)), seen.last != p.kind {
                seen.append(p.kind)
            }
            t += 1.0 / 30
        }
        return seen
    }

    func testTargetPromptNeedsTwentySecondsAndThreeSteadySeconds() {
        var c = CaptureMotionCoach()
        XCTAssertTrue(drive(&c, from: 0, to: 19.9) { _, _ in self.signal() }.isEmpty)
        XCTAssertTrue(drive(&c, from: 19.9, to: 22.8) { _, _ in self.signal() }.isEmpty, "held < 3 s")
        XCTAssertEqual(drive(&c, from: 22.8, to: 23.5) { _, _ in self.signal() }, [.targetStep])
        XCTAssertEqual(c.records.last?.targetSurfaces, 3)
        XCTAssertEqual(c.activeTargetKeys, ["v:1", "v:2", "v:3"])
    }

    func testUncertainSignalNeverPrompts() {
        var c = CaptureMotionCoach()
        XCTAssertTrue(drive(&c, from: 0, to: 60, features: nil) { _, _ in self.signal() }.isEmpty, "no feature count")
        c = CaptureMotionCoach()
        XCTAssertTrue(drive(&c, from: 0, to: 60, features: 12) { _, _ in self.signal() }.isEmpty, "too few feature points")
        c = CaptureMotionCoach()
        XCTAssertTrue(drive(&c, from: 0, to: 60) { _, _ in self.signal(candidates: 2) }.isEmpty, "too few surfaces")
        c = CaptureMotionCoach()
        XCTAssertTrue(drive(&c, from: 0, to: 60) { _, _ in self.signal(share: 0.3) }.isEmpty, "mostly seen from 3 spots")
        c = CaptureMotionCoach()
        XCTAssertTrue(drive(&c, from: 0, to: 60) { t, _ in
            Int(t) % 2 == 0 ? self.signal(["v:a", "v:b"]) : self.signal(["v:c", "v:d"])
        }.isEmpty, "the target keeps changing")
        c = CaptureMotionCoach()
        XCTAssertTrue(drive(&c, from: 0, to: 60, gapActive: true) { _, _ in self.signal() }.isEmpty, "gap prompt up")
    }

    func testNoTargetSignalKeepsBuild81Behaviour() {
        var a = CaptureMotionCoach(), b = CaptureMotionCoach()
        drive(&a, from: 0, to: 60) { _, _ in nil }
        var t = 0.0, nextSave = 0.0
        while t < 60 {
            if t >= nextSave { b.observeSaved(timestamp: t); nextSave += 0.3 }
            _ = b.tick(timestamp: t, cameraToWorld: standing(x: 0), rawFeatureCount: 200, gapPromptActive: false)
            t += 1.0 / 30
        }
        XCTAssertEqual(a.records, b.records)
        XCTAssertTrue(a.records.isEmpty)
    }

    func testTargetPromptYieldsToAGapPromptAndResolvesWithNewSpots() {
        var c = CaptureMotionCoach()
        drive(&c, from: 0, to: 23.5) { _, _ in self.signal() }
        XCTAssertEqual(c.active?.kind, .targetStep)
        drive(&c, from: 23.5, to: 23.6, gapActive: true) { _, _ in self.signal() }
        XCTAssertNil(c.active)
        XCTAssertEqual(c.records.last?.preempted, true)

        var d = CaptureMotionCoach()
        drive(&d, from: 0, to: 23.5) { _, _ in self.signal() }
        drive(&d, from: 23.5, to: 25) { _, coach in self.signal(progress: coach.activeTargetKeys.isEmpty ? nil : 0.67) }
        XCTAssertNil(d.active)
        XCTAssertEqual(d.records.last?.resolved, true)
    }

    func testAtMostTwoTargetPromptsAndNotTwiceAtTheSameSpot() {
        var c = CaptureMotionCoach()
        drive(&c, from: 0, to: 60) { _, _ in self.signal() }  // one prompt, times out after 10 s, same spot → no repeat
        XCTAssertEqual(c.records.filter { $0.kind == .targetStep }.count, 1)
        XCTAssertLessThanOrEqual(c.records.first?.closedAtSec.map { $0 - c.records[0].shownAtSec } ?? 99, 10.05)
        drive(&c, from: 60, to: 90, x: 2) { _, _ in self.signal() }
        XCTAssertEqual(c.records.filter { $0.kind == .targetStep }.count, 2)
        drive(&c, from: 90, to: 130, x: 4) { _, _ in self.signal() }
        XCTAssertEqual(c.records.filter { $0.kind == .targetStep }.count, 2, "at most 2 per capture")
    }

    func testTargetPromptRanksBelowTheGapPromptAndNeverBlocksFinishing() {
        var q = readyQuality()
        q.guidanceAction = .captureCoach
        q.coachPrompt = .init(kind: .targetStep, shownAt: 0, id: 1, spot: .zero)
        q.gapPrompt = gapPrompt(.opposite, turn: .left)
        XCTAssertEqual(GuidanceRuleEngine().bestDecision(quality: q, trackingLimited: false).action, .captureGap)
        q.gapPrompt = nil
        let best = GuidanceRuleEngine().bestDecision(quality: q, trackingLimited: false)
        XCTAssertEqual(best.action, .captureCoach)
        XCTAssertEqual(best.ruleId, "coach_targetStep")
        let g = CaptureUIPresenter.primaryGuidance(quality: q)
        XCTAssertTrue(g.isReadyToFinish)
        XCTAssertEqual(g.direction, .none)
        XCTAssertTrue(SpatialCaptureConfig.targetStepGuideEnabled, "shipped on; the flag turns it off")
    }

    // MARK: Surface signal (ARKit feature voxels)

    private func keyframe(at p: simd_float3, lookAt t: simd_float3) -> SurfaceCoverageModel.Keyframe {
        let f = simd_normalize(t - p)
        let right = simd_normalize(simd_cross(f, simd_float3(0, 1, 0)))
        let up = simd_cross(right, f)
        let m = simd_float4x4(columns: (simd_float4(right, 0), simd_float4(up, 0), simd_float4(-f, 0), simd_float4(p, 1)))
        return .init(cameraToWorld: m, fx: 1435, fy: 1435, cx: 960, cy: 720, width: 1920, height: 1440, sharp: true)
    }

    func testSurfacesSeenFromOneSpotAreNarrowUntilSeenFromThreeSpots() throws {
        var model = SurfaceCoverageModel()
        var pts: [simd_float3] = []
        for cx in [Float(-0.3), 0, 0.3] {
            for i in 0..<12 { pts.append(simd_float3(cx + 0.01 * Float(i % 4), 1.05 + 0.01 * Float(i / 4), -2.05)) }
        }
        model.addFeaturePoints(pts)
        let target = simd_float3(0, 1.05, -2.05)
        let spot = simd_float3(0, 1.3, 0)
        for _ in 0..<10 { model.observeKeyframe(keyframe(at: spot, lookAt: target)) }
        let view = keyframe(at: spot, lookAt: target).cameraToWorld
        let s = try XCTUnwrap(model.targetStepSignal(cameraToWorld: view, activeKeys: []))
        XCTAssertEqual(s.candidates, 3)
        XCTAssertEqual(s.narrowKeys.count, 3)
        XCTAssertEqual(s.narrowAreaShare, 1, accuracy: 1e-6)
        XCTAssertNil(s.activeProgress)

        for x in [Float(0.6), 1.2] {
            for _ in 0..<3 { model.observeKeyframe(keyframe(at: simd_float3(x, 1.3, 0), lookAt: target)) }
        }
        let after = try XCTUnwrap(model.targetStepSignal(cameraToWorld: view, activeKeys: s.narrowKeys))
        XCTAssertTrue(after.narrowKeys.isEmpty)
        XCTAssertEqual(after.activeProgress ?? 0, 1, accuracy: 1e-6)
    }

    func testCeilingAndFarSurfacesAreNotTargets() throws {
        var model = SurfaceCoverageModel()
        var pts: [simd_float3] = []
        for i in 0..<12 { pts.append(simd_float3(0.01 * Float(i % 4), 2.4 + 0.01 * Float(i / 4), -1.5)) }  // above camera + 0.5
        for i in 0..<12 { pts.append(simd_float3(0.01 * Float(i % 4), 1.3 + 0.01 * Float(i / 4), -4.5)) }  // beyond 3.5 m
        model.addFeaturePoints(pts)
        let spot = simd_float3(0, 1.3, 0)
        for _ in 0..<10 { model.observeKeyframe(keyframe(at: spot, lookAt: simd_float3(0, 1.8, -3))) }
        let s = try XCTUnwrap(model.targetStepSignal(cameraToWorld: keyframe(at: spot, lookAt: simd_float3(0, 1.8, -3)).cameraToWorld,
                                                     activeKeys: []))
        XCTAssertEqual(s.candidates, 0)
    }
}
