import XCTest
@testable import Gonggi

final class DirectionCaptureSeamLevelTests: XCTestCase {
    override func tearDown() {
        DirectionCaptureConfig.captureToleranceDeg = 8
        DirectionCaptureConfig.frontSeamPreferredYawDeg = -327
        DirectionCaptureConfig.frontSeamSoftMinYawDeg = -325
        DirectionCaptureConfig.frontSeamSoftAcceptWaitSec = 1.8
        DirectionCaptureConfig.frontSeamHelperActiveYawDeg = -300
        DirectionCaptureConfig.horizontalLevelWarnDeg = 10
        DirectionCaptureConfig.frontAutoCaptureDelaySec = 0.2
        DirectionCaptureConfig.obliqueShotSettleSec = 0.12
        super.tearDown()
    }

    func testFrontSeamRejectsForensic322() {
        XCTAssertFalse(
            DirectionCaptureGuide.isFrontSeamSoftMinSatisfied(unwrappedYaw: -322)
        )
        XCTAssertFalse(
            DirectionCaptureGuide.isFrontSeamClosureReady(
                unwrappedYaw: -322,
                now: 10,
                softMinEnteredAt: 0
            )
        )
        // Old tolerance alone would have accepted −322 — gate must still refuse.
        XCTAssertTrue(
            DirectionCaptureGuide.withinYawTolerance(currentYaw: -322, targetYaw: -330)
        )
    }

    func testFrontSeamPreferredAcceptsImmediately() {
        XCTAssertTrue(
            DirectionCaptureGuide.isFrontSeamClosureReady(
                unwrappedYaw: -327,
                now: 10,
                softMinEnteredAt: nil
            )
        )
        XCTAssertTrue(
            DirectionCaptureGuide.isFrontSeamClosureReady(
                unwrappedYaw: -330,
                now: 10,
                softMinEnteredAt: nil
            )
        )
    }

    func testFrontSeamSoftMinRequiresWaitBeforeAccept() {
        XCTAssertFalse(
            DirectionCaptureGuide.isFrontSeamClosureReady(
                unwrappedYaw: -325,
                now: 10,
                softMinEnteredAt: 9.5,
                softWaitSec: 1.8
            ),
            "soft band must wait before accept"
        )
        XCTAssertTrue(
            DirectionCaptureGuide.isFrontSeamClosureReady(
                unwrappedYaw: -325,
                now: 12,
                softMinEnteredAt: 10,
                softWaitSec: 1.8
            )
        )
    }

    func testFrontSeamCenterGapAt325IsAbout35() {
        let gap = DirectionCaptureGuide.frontSeamCenterGapDeg(lastShotIosYaw: -325)
        XCTAssertEqual(gap, 35, accuracy: 0.5)
    }

    func testUnwrappedConventionNoWrapAt180() {
        // Continuous decreasing path through back (−180) into back_left (−210).
        XCTAssertTrue(DirectionCaptureGuide.withinYawTolerance(currentYaw: -180, targetYaw: -180))
        XCTAssertTrue(DirectionCaptureGuide.withinYawTolerance(currentYaw: -210, targetYaw: -210))
        XCTAssertGreaterThan(abs((-210) - (-180)), 0)
        XCTAssertEqual((-210) - (-180), -30, accuracy: 0.01)
    }

    func testLevelGuidanceAtMinus18() {
        XCTAssertEqual(
            DirectionCaptureGuide.horizontalLevelGuidanceMessage(elevationDeg: -18),
            "카메라를 조금 위로 들어주세요"
        )
    }

    func testLevelGuidanceNearZeroNil() {
        XCTAssertNil(DirectionCaptureGuide.horizontalLevelGuidanceMessage(elevationDeg: 0))
        XCTAssertNil(DirectionCaptureGuide.horizontalLevelGuidanceMessage(elevationDeg: -9))
        XCTAssertNil(DirectionCaptureGuide.horizontalLevelGuidanceMessage(elevationDeg: 9))
    }

    func testLevelGuidanceTooHigh() {
        XCTAssertEqual(
            DirectionCaptureGuide.horizontalLevelGuidanceMessage(elevationDeg: 12),
            "카메라를 조금 내려주세요"
        )
    }

    func testGuidePrioritySeamOverLevel() {
        let msg = DirectionCaptureGuide.horizontalGuideMessage(
            warnFast: true,
            target: .frontLeft330,
            unwrappedYaw: -322,
            elevationDeg: -18
        )
        XCTAssertEqual(msg, "조금 더 오른쪽으로 돌아주세요")
    }

    func testGuidePriorityLevelOverFastWhenNotSeam() {
        let msg = DirectionCaptureGuide.horizontalGuideMessage(
            warnFast: true,
            target: .right,
            unwrappedYaw: -90,
            elevationDeg: -18
        )
        XCTAssertEqual(msg, "카메라를 조금 위로 들어주세요")
    }

    func testEngineRejects322ThenAcceptsPreferredOnLastShot() {
        DirectionCaptureConfig.frontAutoCaptureDelaySec = 0
        let engine = DirectionCaptureEngine()
        engine.enableMockSweep = false
        engine.autoCompletePhotoInMock = true
        try? engine.prepareCamera(mockMode: true)
        engine.beginCapture()

        let early: [Float] = [0, -30, -60, -90, -120, -150, -180, -210, -240, -270, -300]
        for yaw in early {
            engine.ingestMotionSample(unwrappedYaw: yaw, pitchDeg: -5, elevationDeg: 0)
        }
        XCTAssertEqual(engine.capturedCount, 11)
        XCTAssertNil(engine.captured[.frontLeft330])

        engine.ingestMotionSample(unwrappedYaw: -322, pitchDeg: -5, elevationDeg: 0, timestamp: 50)
        XCTAssertNil(engine.captured[.frontLeft330], "−322 must not accept")
        XCTAssertTrue(engine.guideText.contains("오른쪽"))

        engine.ingestMotionSample(unwrappedYaw: -327, pitchDeg: -5, elevationDeg: 0, timestamp: 51)
        XCTAssertNotNil(engine.captured[.frontLeft330], "−327 preferred must accept")
        XCTAssertEqual(engine.captured[.frontLeft330]?.closureGatePassed, true)
        XCTAssertNotNil(engine.captured[.frontLeft330]?.closureDeltaDeg)
    }

    func testEngineSoftMinAcceptAfterWait() {
        DirectionCaptureConfig.frontAutoCaptureDelaySec = 0
        DirectionCaptureConfig.frontSeamSoftAcceptWaitSec = 0.4
        let engine = DirectionCaptureEngine()
        engine.enableMockSweep = false
        engine.autoCompletePhotoInMock = true
        try? engine.prepareCamera(mockMode: true)
        engine.beginCapture()

        for yaw: Float in [0, -30, -60, -90, -120, -150, -180, -210, -240, -270, -300] {
            engine.ingestMotionSample(unwrappedYaw: yaw, elevationDeg: 0)
        }

        engine.ingestMotionSample(unwrappedYaw: -325.2, elevationDeg: 0, timestamp: 100)
        XCTAssertNil(engine.captured[.frontLeft330], "soft band needs wait")

        engine.ingestMotionSample(unwrappedYaw: -325.2, elevationDeg: 0, timestamp: 100.5)
        XCTAssertNotNil(engine.captured[.frontLeft330], "soft min after wait")
    }

    func testEarlierHorizontalShotsUnchangedAtNominal() {
        DirectionCaptureConfig.frontAutoCaptureDelaySec = 0
        let engine = DirectionCaptureEngine()
        engine.enableMockSweep = false
        engine.autoCompletePhotoInMock = true
        try? engine.prepareCamera(mockMode: true)
        engine.beginCapture()

        engine.ingestMotionSample(unwrappedYaw: 0, elevationDeg: -18)
        XCTAssertNotNil(engine.captured[.front])
        engine.ingestMotionSample(unwrappedYaw: -30, elevationDeg: -18)
        XCTAssertNotNil(engine.captured[.frontRight30])
        // Level guidance soft — capture still proceeds while elev is low.
        XCTAssertEqual(engine.capturedCount, 2)
    }

    func testMetadataIncludesClosureFieldsForLastShot() throws {
        var captures: [DirectionCaptureRecord] = DirectionName.captureOrder.enumerated().map { idx, dir in
            DirectionCaptureRecord(
                direction: dir,
                filePath: "direction_capture/\(dir.fileName)",
                yawDeg: 10,
                pitchDeg: 0,
                rollDeg: 0,
                timestamp: Double(idx),
                elevationDeg: dir.targetElevationDeg,
                finalPixelWidth: 960,
                finalPixelHeight: 1280,
                phase: dir.phaseKind,
                nominalYaw: dir.targetYawDeg,
                nominalElevation: dir.targetElevationDeg,
                capturedYawDeg: dir.targetYawDeg ?? Float(-idx * 30),
                capturedElevationDeg: dir.targetElevationDeg,
                closureDeltaDeg: dir == .frontLeft330 ? 3 : nil,
                horizontalLevelDeltaDeg: dir.isHorizontal ? -2 : nil,
                closureGatePassed: dir == .frontLeft330 ? true : nil
            )
        }
        // Ensure last horizontal uses −327.
        if let i = captures.firstIndex(where: { $0.direction == .frontLeft330 }) {
            captures[i].capturedYawDeg = -327
            captures[i].closureDeltaDeg = 3
            captures[i].closureGatePassed = true
        }
        let report = DirectionCaptureReport(
            sessionId: "test-seam-meta",
            createdAt: "2026-09-07T00:00:00Z",
            captures: captures
        )
        let json = try SpaceCaptureMetadataBuilder.jsonString(from: report)
        let decoded = try JSONDecoder().decode([SpaceCaptureMetadataEntry].self, from: Data(json.utf8))
        let last = try XCTUnwrap(decoded.first { $0.direction == "front_left_330" })
        XCTAssertEqual(last.closureGatePassed, true)
        XCTAssertEqual(last.capturedYawDeg, -327, accuracy: 0.01)
        XCTAssertNotNil(last.closureDeltaDeg)
        XCTAssertNotNil(last.horizontalLevelDeltaDeg)
    }
}
