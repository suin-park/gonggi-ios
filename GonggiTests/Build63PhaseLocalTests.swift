import XCTest
@testable import Gonggi

final class Build63PhaseLocalTests: XCTestCase {
    override func tearDown() {
        DirectionCaptureConfig.obliqueShotSettleSec = 0.5
        DirectionCaptureConfig.obliquePhaseLocalTargetYawDeg = [0, 90, 180, 270]
        DirectionCaptureConfig.obliqueMinAccumulatedYawDeg = [0, 90, 90, 90]
        DirectionCaptureConfig.obliqueLastShotFailSafeYawDeg = 240
        DirectionCaptureConfig.obliqueLastShotFailSafeWaitSec = 4.0
        DirectionCaptureConfig.obliqueMaxSampleDeltaDeg = 22
        DirectionCaptureConfig.upperObliqueElevationPreferredMinDeg = 40
        DirectionCaptureConfig.upperObliqueElevationPreferredMaxDeg = 55
        DirectionCaptureConfig.lowerObliqueElevationPreferredMinDeg = -55
        DirectionCaptureConfig.lowerObliqueElevationPreferredMaxDeg = -40
        DirectionCaptureConfig.gravityInvertedYThreshold = 0.35
        super.tearDown()
    }

    private func makeEngine() -> DirectionCaptureEngine {
        let engine = DirectionCaptureEngine()
        engine.enableMockSweep = false
        engine.autoCompletePhotoInMock = true
        try? engine.prepareCamera(mockMode: true)
        engine.beginCapture()
        return engine
    }

    private func completeHorizontal(_ engine: DirectionCaptureEngine) {
        for yaw: Float in [0, -30, -60, -90, -120, -150, -180, -210, -240, -270, -300, -330] {
            engine.ingestMotionSample(unwrappedYaw: yaw, pitchDeg: -5, elevationDeg: 0)
        }
    }

    private func settlePhase(
        _ engine: DirectionCaptureEngine,
        yaw: Float,
        elev: Float,
        time: inout TimeInterval,
        roll: Float = 0,
        gravityY: Float = -0.9
    ) {
        let settle = DirectionCaptureConfig.obliqueShotSettleSec
        let steps = max(2, Int(ceil(settle / 0.1)) + 1)
        for _ in 0..<steps {
            time += 0.1
            engine.ingestMotionSample(
                unwrappedYaw: yaw,
                rollDeg: roll,
                rotationRate: 0.2,
                elevationDeg: elev,
                timestamp: time,
                gravityY: gravityY
            )
        }
    }

    private func turnRightPhaseLocal(
        _ engine: DirectionCaptureEngine,
        from start: Float,
        by degrees: Float,
        elev: Float,
        time: inout TimeInterval,
        step: Float = 8,
        roll: Float = 0
    ) {
        var yaw = start
        let end = start - degrees
        while yaw > end + 0.05 {
            yaw -= step
            if yaw < end { yaw = end }
            time += 0.05
            engine.ingestMotionSample(
                unwrappedYaw: yaw,
                rollDeg: roll,
                rotationRate: 0.3,
                elevationDeg: elev,
                timestamp: time,
                gravityY: -0.9
            )
        }
    }

    /// A: H→U Euler yaw jump must not block; phase-local baseline re-anchors.
    func testA_HorizontalToUpperEulerJumpStillProgresses() {
        let engine = makeEngine()
        completeHorizontal(engine)
        XCTAssertEqual(engine.phase, .capturingUpperOblique)

        var t: TimeInterval = 100
        // Simulate Build62-style Euler discontinuity: −328 → −184 with roll≈170.
        settlePhase(engine, yaw: -183.9, elev: 45, time: &t, roll: 170)
        XCTAssertNotNil(engine.captured[.upFrontRight])
        XCTAssertEqual(engine.captured[.upFrontRight]?.phaseLocalYawDeg ?? -1, 0, accuracy: 1)
        XCTAssertEqual(engine.captured[.upFrontRight]?.phaseAnchorGlobalYawDeg ?? 0, -183.9, accuracy: 0.5)
        XCTAssertEqual(engine.captured[.upFrontRight]?.gravityUprightPassed, true)

        turnRightPhaseLocal(engine, from: -183.9, by: 90, elev: 45, time: &t, roll: 170)
        XCTAssertNotNil(engine.captured[.upBackRight])
    }

    /// B: U→L re-anchor independent of upper global yaw.
    func testB_UpperToLowerReAnchor() {
        DirectionCaptureConfig.obliqueShotSettleSec = 0
        let engine = makeEngine()
        completeHorizontal(engine)

        var t: TimeInterval = 200
        engine.ingestMotionSample(unwrappedYaw: -100, elevationDeg: 45, timestamp: t, gravityY: -0.9)
        turnRightPhaseLocal(engine, from: -100, by: 90, elev: 45, time: &t)
        turnRightPhaseLocal(engine, from: -190, by: 90, elev: 45, time: &t)
        turnRightPhaseLocal(engine, from: -280, by: 90, elev: 45, time: &t)
        XCTAssertEqual(engine.phase, .capturingLowerOblique)

        // Jump like forensic U→L (−380 → −545) + roll flip.
        settlePhase(engine, yaw: -545, elev: -47, time: &t, roll: -11)
        XCTAssertNotNil(engine.captured[.downFrontRight])
        XCTAssertEqual(engine.captured[.downFrontRight]?.phaseLocalYawDeg ?? -1, 0, accuracy: 1)
        XCTAssertEqual(engine.captured[.downFrontRight]?.phaseAnchorGlobalYawDeg ?? 0, -545, accuracy: 1)
    }

    /// C: relative roll≈180 + gravity upright → do not reject.
    func testC_RelativeRoll180DoesNotRejectWhenGravityUpright() {
        DirectionCaptureConfig.obliqueShotSettleSec = 0
        let engine = makeEngine()
        completeHorizontal(engine)
        var t: TimeInterval = 300
        engine.ingestMotionSample(
            unwrappedYaw: -50,
            rollDeg: 179,
            elevationDeg: 45,
            timestamp: t,
            gravityY: -0.85,
            gravityUprightPassed: true
        )
        XCTAssertNotNil(engine.captured[.upFrontRight])
        XCTAssertEqual(engine.guideText.contains("바로 세워"), false)
    }

    /// D: inverted device → wait / no capture.
    func testD_InvertedDeviceBlocksCapture() {
        DirectionCaptureConfig.obliqueShotSettleSec = 0
        let engine = makeEngine()
        completeHorizontal(engine)
        var t: TimeInterval = 400
        engine.ingestMotionSample(
            unwrappedYaw: -50,
            rollDeg: 0,
            elevationDeg: 45,
            timestamp: t,
            gravityY: 0.9,
            gravityUprightPassed: false
        )
        XCTAssertNil(engine.captured[.upFrontRight])
        XCTAssertTrue(engine.guideText.contains("바로 세워"))
    }

    /// E: upper +45 preferred → capture OK.
    func testE_Upper45PreferredCaptures() {
        DirectionCaptureConfig.obliqueShotSettleSec = 0
        let engine = makeEngine()
        completeHorizontal(engine)
        engine.ingestMotionSample(unwrappedYaw: -20, elevationDeg: 45, timestamp: 10)
        XCTAssertNotNil(engine.captured[.upFrontRight])
        XCTAssertEqual(engine.captured[.upFrontRight]?.elevationPreferredBandPassed, true)
    }

    /// F: upper +67 too steep → guide + no auto-capture.
    func testF_Upper67TooSteepGuidesWithoutCapture() {
        DirectionCaptureConfig.obliqueShotSettleSec = 0
        let engine = makeEngine()
        completeHorizontal(engine)
        engine.ingestMotionSample(unwrappedYaw: -20, elevationDeg: 67, timestamp: 10)
        XCTAssertNil(engine.captured[.upFrontRight])
        XCTAssertEqual(engine.guideText, "조금 덜 위로 들어주세요")
    }

    /// G: lower −47 preferred → capture OK.
    func testG_Lower47PreferredCaptures() {
        DirectionCaptureConfig.obliqueShotSettleSec = 0
        let engine = makeEngine()
        completeHorizontal(engine)
        var t: TimeInterval = 500
        // Finish upper quickly.
        engine.ingestMotionSample(unwrappedYaw: 0, elevationDeg: 45, timestamp: t)
        turnRightPhaseLocal(engine, from: 0, by: 90, elev: 45, time: &t)
        turnRightPhaseLocal(engine, from: -90, by: 90, elev: 45, time: &t)
        turnRightPhaseLocal(engine, from: -180, by: 90, elev: 45, time: &t)
        XCTAssertEqual(engine.phase, .capturingLowerOblique)

        engine.ingestMotionSample(unwrappedYaw: -300, elevationDeg: -47, timestamp: t + 1)
        XCTAssertNotNil(engine.captured[.downFrontRight])
        XCTAssertEqual(engine.captured[.downFrontRight]?.elevationPreferredBandPassed, true)
    }

    /// H: lower −67 too steep → guide.
    func testH_Lower67TooSteepGuidesWithoutCapture() {
        DirectionCaptureConfig.obliqueShotSettleSec = 0
        let engine = makeEngine()
        completeHorizontal(engine)
        var t: TimeInterval = 600
        engine.ingestMotionSample(unwrappedYaw: 0, elevationDeg: 45, timestamp: t)
        turnRightPhaseLocal(engine, from: 0, by: 90, elev: 45, time: &t)
        turnRightPhaseLocal(engine, from: -90, by: 90, elev: 45, time: &t)
        turnRightPhaseLocal(engine, from: -180, by: 90, elev: 45, time: &t)

        engine.ingestMotionSample(unwrappedYaw: -300, elevationDeg: -67, timestamp: t + 1)
        XCTAssertNil(engine.captured[.downFrontRight])
        XCTAssertEqual(engine.guideText, "조금 덜 아래로 내려주세요")
    }

    /// I: phase-local orbit ignores global multi-revolution magnitude.
    func testI_PhaseLocalIndependentOfGlobalMultiRevolution() {
        DirectionCaptureConfig.obliqueShotSettleSec = 0
        let engine = makeEngine()
        completeHorizontal(engine)
        var t: TimeInterval = 700
        // Start upper already at absurd global yaw.
        let start: Float = -800
        engine.ingestMotionSample(unwrappedYaw: start, elevationDeg: 48, timestamp: t)
        XCTAssertEqual(engine.captured[.upFrontRight]?.phaseLocalYawDeg ?? -1, 0, accuracy: 0.5)
        turnRightPhaseLocal(engine, from: start, by: 90, elev: 48, time: &t)
        XCTAssertNotNil(engine.captured[.upBackRight])
        let local = engine.captured[.upBackRight]?.phaseLocalYawDeg ?? 0
        XCTAssertEqual(local, 90, accuracy: 8)
        XCTAssertLessThan(abs(local), 200, "phase-local must not inherit global |yaw|≈800")
    }

    /// J: H12 / seam gate still works (regression smoke).
    func testJ_HorizontalSeamGateStillRequiresSoftMin() {
        let engine = makeEngine()
        for yaw: Float in [0, -30, -60, -90, -120, -150, -180, -210, -240, -270, -300] {
            engine.ingestMotionSample(unwrappedYaw: yaw, pitchDeg: -5, elevationDeg: 0)
        }
        // −322 is inside ±8 of −330 but fails soft-min −325.
        engine.ingestMotionSample(unwrappedYaw: -322, pitchDeg: -5, elevationDeg: 0)
        XCTAssertNil(engine.captured[.frontLeft330])
        engine.ingestMotionSample(unwrappedYaw: -327, pitchDeg: -5, elevationDeg: 0)
        XCTAssertNotNil(engine.captured[.frontLeft330])
        XCTAssertEqual(engine.captured[.frontLeft330]?.closureGatePassed, true)
    }

    func testGuideCopyPreferredAndBoundary() {
        XCTAssertEqual(
            DirectionCaptureGuide.upperObliqueGuideMessage(
                warnFast: false, waitingForElevation: true
            ),
            "벽과 하늘(천장) 경계가 보이게"
        )
        XCTAssertEqual(
            DirectionCaptureGuide.upperObliqueGuideMessage(
                warnFast: false, waitingForElevation: false, tooSteep: true
            ),
            "조금 덜 위로 들어주세요"
        )
        XCTAssertEqual(
            DirectionCaptureGuide.lowerObliqueGuideMessage(
                warnFast: false, waitingForElevation: true
            ),
            "바닥과 벽 아래가 함께 보이게"
        )
        XCTAssertTrue(DirectionCaptureGuide.isGravityUpright(gravityY: -0.8))
        XCTAssertFalse(DirectionCaptureGuide.isGravityUpright(gravityY: 0.8))
        XCTAssertTrue(DirectionCaptureGuide.isUpperPreferredElevation(45))
        XCTAssertTrue(DirectionCaptureGuide.isUpperTooSteep(67))
        XCTAssertTrue(DirectionCaptureGuide.isLowerPreferredElevation(-47))
        XCTAssertTrue(DirectionCaptureGuide.isLowerTooSteep(-67))
    }

    func testSettleDurationUsesInjectedTimestamp() {
        DirectionCaptureConfig.obliqueShotSettleSec = 0.5
        let engine = makeEngine()
        completeHorizontal(engine)
        var t: TimeInterval = 50
        engine.ingestMotionSample(unwrappedYaw: -40, elevationDeg: 45, timestamp: t, gravityY: -1)
        XCTAssertNil(engine.captured[.upFrontRight], "must wait settle")
        t += 0.3
        engine.ingestMotionSample(unwrappedYaw: -40, elevationDeg: 45, timestamp: t, gravityY: -1)
        XCTAssertNil(engine.captured[.upFrontRight])
        t += 0.25
        engine.ingestMotionSample(unwrappedYaw: -40, elevationDeg: 45, timestamp: t, gravityY: -1)
        XCTAssertNotNil(engine.captured[.upFrontRight])
        XCTAssertGreaterThanOrEqual(engine.captured[.upFrontRight]?.settleDurationMs ?? 0, 400)
    }
}
