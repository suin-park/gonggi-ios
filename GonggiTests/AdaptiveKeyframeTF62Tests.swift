import simd
import XCTest
@testable import Gonggi

final class AdaptiveKeyframeTF62Tests: XCTestCase {
    func testHardQualityRejectsAreNotBypassedByStarvation() {
        let a = matrix_identity_float4x4
        var far = a
        far.columns.3 = SIMD4(1.0, 0, 0, 1)
        let ctx = makeContext(secondsSince: 2.0, translation: 1.0, inTransition: false)
        let blurry = KeyframeSelector3DGS.shouldAccept(
            timestamp: 10,
            transform: far,
            trackingNormal: true,
            lastKeyframeTimestamp: 8,
            lastKeyframeTransform: a,
            keyframeCount: 5,
            sharpnessState: .blurry,
            adaptiveContext: ctx
        )
        XCTAssertFalse(blurry.accept)
        XCTAssertEqual(blurry.reason, "blur")

        let tracking = KeyframeSelector3DGS.shouldAccept(
            timestamp: 10,
            transform: far,
            trackingNormal: false,
            lastKeyframeTimestamp: 8,
            lastKeyframeTransform: a,
            keyframeCount: 5,
            adaptiveContext: ctx
        )
        XCTAssertFalse(tracking.accept)
        XCTAssertEqual(tracking.reason, "tracking_not_normal")
    }

    func testTimeStarvationAcceptsAfterQualityPass() {
        let a = matrix_identity_float4x4
        var far = a
        far.columns.3 = SIMD4(0.25, 0, 0, 1)
        // Low novelty / high redundancy context so score stays below threshold.
        var ctx = makeContext(secondsSince: 0.75, translation: 0.25, inTransition: false)
        ctx.newCoverageRatio = 0.02
        ctx.cellVisitCount = 12
        ctx.localCoverage = 0.9
        ctx.yawNoveltyDeg = 1
        ctx.pitchNoveltyDeg = 0
        ctx.transitionScore = 0
        let d = KeyframeSelector3DGS.shouldAccept(
            timestamp: 10,
            transform: far,
            trackingNormal: true,
            lastKeyframeTimestamp: 9.25,
            lastKeyframeTransform: a,
            keyframeCount: 5,
            sharpnessState: .sharp,
            motionSpeed: 0.2,
            angularVelocity: 0.2,
            lowTextureScore: 0.1,
            adaptiveContext: ctx
        )
        XCTAssertTrue(d.accept)
        XCTAssertEqual(d.reason, "continuity_time_starvation")
    }

    func testDistanceStarvationAcceptsAfterQualityPass() {
        let a = matrix_identity_float4x4
        var far = a
        far.columns.3 = SIMD4(0.41, 0, 0, 1)
        var ctx = makeContext(secondsSince: 0.35, translation: 0.41, inTransition: false)
        ctx.newCoverageRatio = 0.02
        ctx.cellVisitCount = 12
        ctx.localCoverage = 0.9
        ctx.yawNoveltyDeg = 1
        ctx.transitionScore = 0
        ctx.sharpnessScore = 0.2
        let d = KeyframeSelector3DGS.shouldAccept(
            timestamp: 10,
            transform: far,
            trackingNormal: true,
            lastKeyframeTimestamp: 9.65,
            lastKeyframeTransform: a,
            keyframeCount: 5,
            sharpnessState: .acceptable,
            motionSpeed: 0.2,
            angularVelocity: 0.2,
            lowTextureScore: 0.1,
            adaptiveContext: ctx
        )
        XCTAssertTrue(d.accept)
        XCTAssertEqual(d.reason, "continuity_distance_starvation")
    }

    func testTransitionChainRelaxesOrTightensGap() {
        let a = matrix_identity_float4x4
        var far = a
        far.columns.3 = SIMD4(0.2, 0, 0, 1)
        var ctx = makeContext(secondsSince: 0.45, translation: 0.2, inTransition: true)
        ctx.newCoverageRatio = 0.02
        ctx.cellVisitCount = 12
        ctx.localCoverage = 0.9
        ctx.yawNoveltyDeg = 1
        ctx.transitionScore = 0.5
        let d = KeyframeSelector3DGS.shouldAccept(
            timestamp: 10,
            transform: far,
            trackingNormal: true,
            lastKeyframeTimestamp: 9.55,
            lastKeyframeTransform: a,
            keyframeCount: 5,
            sharpnessState: .sharp,
            motionSpeed: 0.2,
            angularVelocity: 0.2,
            lowTextureScore: 0.1,
            adaptiveContext: ctx
        )
        XCTAssertTrue(d.accept)
        XCTAssertTrue(
            d.reason.contains("transition") || d.reason.contains("continuity"),
            "expected transition/continuity accept, got \(d.reason)"
        )
    }

    func testRegionTrackerSplitsOnTravelWithoutCentroidChase() {
        var tracker = CaptureRegionTracker(
            recentCapacity: 8,
            splitDistanceM: 2.8,
            rejoinDistanceM: 1.6,
            splitCooldownSec: 0.5,
            doorwaySpeedMaxMps: 0.42,
            globalSoftDenom: 48
        )
        var s = tracker.ingest(cellId: "0_0", position: SIMD3(0, 0, 0), timestamp: 0)
        XCTAssertEqual(s.regionCount, 1)
        // Move within room — should stay region 1 (anchor does not chase).
        s = tracker.ingest(cellId: "1_0", position: SIMD3(1.0, 0, 0), timestamp: 1)
        XCTAssertEqual(s.regionCount, 1)
        s = tracker.ingest(cellId: "2_0", position: SIMD3(2.0, 0, 0), timestamp: 2)
        XCTAssertEqual(s.regionCount, 1)
        // Cross split distance from original anchor.
        s = tracker.ingest(cellId: "5_0", position: SIMD3(3.2, 0, 0), timestamp: 3)
        XCTAssertEqual(s.regionCount, 2)
        XCTAssertTrue(s.didSplit)
        // Immediately near new region — no flap merge.
        s = tracker.ingest(cellId: "5_1", position: SIMD3(3.3, 0, 0.2), timestamp: 3.2)
        XCTAssertEqual(s.regionCount, 2)
        // Cooldown: another far jump too soon should not split again.
        s = tracker.ingest(cellId: "10_0", position: SIMD3(6.5, 0, 0), timestamp: 3.4)
        XCTAssertEqual(s.regionCount, 2)
        // After cooldown, third region.
        s = tracker.ingest(cellId: "10_0", position: SIMD3(6.5, 0, 0), timestamp: 4.0)
        XCTAssertEqual(s.regionCount, 3)
    }

    func testSelectionDiagnosticsHistogramsAndIntervals() {
        let acc = CaptureSelectionDiagnosticsAccumulator()
        acc.recordDecision(accepted: true, reason: "first", timestamp: 0, inTransitionChain: false)
        acc.recordDecision(accepted: false, reason: "min_interval", timestamp: 0.1, inTransitionChain: false)
        acc.recordDecision(accepted: true, reason: "continuity_time_starvation", timestamp: 0.8, inTransitionChain: false)
        acc.recordDecision(accepted: true, reason: "transition_chain", timestamp: 1.2, inTransitionChain: true)
        acc.recordDecision(accepted: true, reason: "transition_chain", timestamp: 1.5, inTransitionChain: true)
        let diag = acc.build(
            regionCount: 2,
            framesPerRegion: [0: 2, 1: 2],
            travelDistanceM: 8,
            yawCoverage: 0.4,
            localCoverage: 0.5,
            globalCoverage: 0.6,
            captureDurationSec: 10
        )
        XCTAssertEqual(diag.candidateCount, 5)
        XCTAssertEqual(diag.acceptedCount, 4)
        XCTAssertEqual(diag.rejectedCount, 1)
        XCTAssertEqual(diag.rejectedReasonHistogram["min_interval"], 1)
        XCTAssertEqual(diag.transitionFrameCount, 2)
        XCTAssertEqual(diag.maxAcceptedIntervalSec!, 0.8, accuracy: 0.001)
        XCTAssertNotNil(diag.medianAcceptedIntervalSec)
        XCTAssertEqual(diag.acceptedFramesPerSecond!, 0.4, accuracy: 0.001)
    }

    func testCandidateSafetyCapUnchanged() {
        XCTAssertEqual(SpatialCaptureConfig.candidateSafetyCap, 520)
        XCTAssertEqual(SpatialCaptureConfig.packageSchemaVersion, 2)
        XCTAssertEqual(SpatialCaptureConfig.normalMaxGapSec, 0.7, accuracy: 0.001)
        XCTAssertEqual(SpatialCaptureConfig.transitionMaxGapSec, 0.4, accuracy: 0.001)
        XCTAssertEqual(SpatialCaptureConfig.minIntervalSec, 0.30, accuracy: 0.001)
    }

    private func makeContext(
        secondsSince: Double,
        translation: Float,
        inTransition: Bool
    ) -> AdaptiveKeyframeScorer.Context {
        AdaptiveKeyframeScorer.Context(
            keyframeCount: 5,
            currentCellId: "0_0",
            cellVisitCount: 1,
            newCoverageRatio: 0.5,
            yawNoveltyDeg: 10,
            pitchNoveltyDeg: 5,
            sharpnessScore: 0.8,
            trackingNormal: true,
            overlapState: .good,
            translationFromNearestAcceptedM: translation,
            secondsSinceLastAccept: secondsSince,
            transitionScore: inTransition ? 0.6 : 0.1,
            localCoverage: 0.4,
            globalCoverage: 0.3,
            inTransitionChain: inTransition
        )
    }
}
