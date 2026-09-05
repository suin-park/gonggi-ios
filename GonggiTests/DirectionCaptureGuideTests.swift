import XCTest
import UIKit
@testable import Gonggi

final class DirectionCaptureGuideTests: XCTestCase {
    override func setUp() {
        super.setUp()
        DirectionCaptureConfig.frontAutoCaptureDelaySec = 0
        DirectionCaptureConfig.captureToleranceDeg = 10
    }

    override func tearDown() {
        DirectionCaptureConfig.frontAutoCaptureDelaySec = 0.2
        DirectionCaptureConfig.captureToleranceDeg = 9
        super.tearDown()
    }

    // MARK: - Guide helpers

    func testWithinYawToleranceRadius() {
        // User example for ±10 around -45: -36 out, -39 in
        XCTAssertFalse(DirectionCaptureGuide.withinYawTolerance(currentYaw: -36, targetYaw: -45, toleranceDeg: 10))
        XCTAssertTrue(DirectionCaptureGuide.withinYawTolerance(currentYaw: -37, targetYaw: -45, toleranceDeg: 10))
        XCTAssertTrue(DirectionCaptureGuide.withinYawTolerance(currentYaw: -39, targetYaw: -45, toleranceDeg: 10))
        XCTAssertTrue(DirectionCaptureGuide.withinYawTolerance(currentYaw: -43, targetYaw: -45, toleranceDeg: 10))
        XCTAssertTrue(DirectionCaptureGuide.withinYawTolerance(currentYaw: -48, targetYaw: -45, toleranceDeg: 10))
        XCTAssertFalse(DirectionCaptureGuide.withinYawTolerance(currentYaw: -56, targetYaw: -45, toleranceDeg: 10))
    }

    func testWithinElevationTolerance() {
        XCTAssertTrue(DirectionCaptureGuide.withinElevationTolerance(elevationDeg: 70, targetElevation: 70))
        XCTAssertTrue(DirectionCaptureGuide.withinElevationTolerance(elevationDeg: 55, targetElevation: 70))
        XCTAssertFalse(DirectionCaptureGuide.withinElevationTolerance(elevationDeg: 40, targetElevation: 70))
    }

    func testTargetYawMatchesDeviceRightTurnConvention() {
        XCTAssertEqual(DirectionName.front.targetYawDeg, 0)
        XCTAssertEqual(DirectionName.frontRight.targetYawDeg, -45)
        XCTAssertEqual(DirectionName.right.targetYawDeg, -90)
        XCTAssertEqual(DirectionName.back.targetYawDeg, -180)
        XCTAssertEqual(DirectionName.left.targetYawDeg, -270)
        XCTAssertEqual(DirectionCaptureGuide.normalizeYaw0to360(-90), 270, accuracy: 0.01)
        XCTAssertEqual(DirectionCaptureGuide.normalizeYaw0to360(-45), 315, accuracy: 0.01)
    }

    func testElevationFromGravityLooksUpVsDown() {
        let down = DirectionCaptureGuide.elevationDeg(gravityX: 0, gravityY: 0, gravityZ: -1)
        XCTAssertLessThan(down, -50)
        let up = DirectionCaptureGuide.elevationDeg(gravityX: 0, gravityY: 0, gravityZ: 1)
        XCTAssertGreaterThan(up, 50)
    }

    func testFileNamesMatchCanonical() {
        XCTAssertEqual(DirectionName.frontRight.fileName, "front_right.jpg")
        XCTAssertEqual(DirectionName.backLeft.rawValue, "back_left")
    }

    // MARK: - A–E photo request / advance

    /// A. yaw 0 → front capture request exactly once
    func testA_FrontCaptureRequestExactlyOnceAtYaw0() throws {
        let engine = makeTestEngine(autoComplete: false)
        engine.beginCapture()

        engine.ingestMotionSample(unwrappedYaw: 0, pitchDeg: -5)
        XCTAssertEqual(engine.photoRequestCounts[.front] ?? 0, 1)
        XCTAssertEqual(engine.pendingDirection, .front)
        XCTAssertNil(engine.captured[.front], "save 전 captured 금지")

        engine.ingestMotionSample(unwrappedYaw: 1, pitchDeg: -5)
        engine.ingestMotionSample(unwrappedYaw: -2, pitchDeg: -5)
        XCTAssertEqual(engine.photoRequestCounts[.front] ?? 0, 1)

        engine.completePendingPhotoForTests(success: true)
        XCTAssertNotNil(engine.captured[.front])
        XCTAssertEqual(engine.capturedCount, 1)
        XCTAssertEqual(engine.currentTarget, .frontRight)

        CaptureSessionStore.deleteSession(sessionId: engine.sessionId)
    }

    /// B. yaw -37,-41,-44 → front_right request once (target -45 ±10)
    func testB_FrontRightRadiusTriggersOnce() throws {
        let engine = makeTestEngine(autoComplete: false)
        engine.beginCapture()
        seedFrontCaptured(engine)

        // -37 is inside ±10 of -45 (distance 8) → first request
        engine.ingestMotionSample(unwrappedYaw: -37, pitchDeg: -8)
        XCTAssertEqual(engine.photoRequestCounts[.frontRight] ?? 0, 1)
        XCTAssertEqual(engine.pendingDirection, .frontRight)

        engine.ingestMotionSample(unwrappedYaw: -41, pitchDeg: -8)
        engine.ingestMotionSample(unwrappedYaw: -44, pitchDeg: -8)
        XCTAssertEqual(engine.photoRequestCounts[.frontRight] ?? 0, 1)

        engine.completePendingPhotoForTests(success: true)
        XCTAssertNotNil(engine.captured[.frontRight])
        XCTAssertEqual(engine.currentTarget, .right)

        CaptureSessionStore.deleteSession(sessionId: engine.sessionId)
    }

    /// C. 반경 안 여러 frame → capture request 1회만
    func testC_MultipleFramesInRadiusRequestOnce() throws {
        let engine = makeTestEngine(autoComplete: false)
        engine.beginCapture()
        seedFrontCaptured(engine)

        for yaw: Float in [-43, -44, -45, -46] {
            engine.ingestMotionSample(unwrappedYaw: yaw, pitchDeg: -8)
        }
        XCTAssertEqual(engine.photoRequestCounts[.frontRight] ?? 0, 1)
        XCTAssertTrue(engine.isPhotoPending)

        CaptureSessionStore.deleteSession(sessionId: engine.sessionId)
    }

    /// D. photo save 성공 전 → target advance 금지
    func testD_NoAdvanceBeforePhotoSave() throws {
        let engine = makeTestEngine(autoComplete: false)
        engine.beginCapture()

        engine.ingestMotionSample(unwrappedYaw: 0)
        XCTAssertEqual(engine.pendingDirection, .front)
        XCTAssertEqual(engine.capturedCount, 0)
        XCTAssertEqual(engine.currentTarget, .front, "pending 중에도 target은 front 유지")
        XCTAssertEqual(engine.phase, .capturingHorizontal)

        CaptureSessionStore.deleteSession(sessionId: engine.sessionId)
    }

    /// E. photo save 성공 → captured count 증가 + targetIndex advance
    func testE_AdvanceAfterPhotoSave() throws {
        let engine = makeTestEngine(autoComplete: false)
        engine.beginCapture()

        engine.ingestMotionSample(unwrappedYaw: 0)
        XCTAssertEqual(engine.photoRequestCounts[.front] ?? 0, 1)
        engine.completePendingPhotoForTests(success: true)

        XCTAssertEqual(engine.capturedCount, 1)
        XCTAssertNotNil(engine.captured[.front])
        XCTAssertNil(engine.pendingDirection)
        XCTAssertEqual(engine.currentTarget, .frontRight)
        XCTAssertEqual(engine.progressText, "1 / 10")

        CaptureSessionStore.deleteSession(sessionId: engine.sessionId)
    }

    func testFullDecreasingSweepCapturesTenOnce() throws {
        let engine = makeTestEngine(autoComplete: true)
        engine.beginCapture()

        let yaws: [Float] = [
            0, -40, -45, -50, -85, -90, -95,
            -130, -135, -140, -175, -180, -185,
            -220, -225, -230, -265, -270, -275,
            -310, -315, -320
        ]
        for yaw in yaws {
            engine.ingestMotionSample(unwrappedYaw: yaw, pitchDeg: -8)
        }
        for dir in DirectionName.horizontalOrder {
            XCTAssertNotNil(engine.captured[dir], "missing \(dir.rawValue)")
            XCTAssertEqual(engine.photoRequestCounts[dir] ?? 0, 1)
        }

        for elev: Float in [55, 70, 80] {
            engine.ingestMotionSample(unwrappedYaw: -320, elevationDeg: elev)
        }
        XCTAssertNotNil(engine.captured[.up])

        for elev: Float in [-55, -70, -80] {
            engine.ingestMotionSample(unwrappedYaw: -320, elevationDeg: elev)
        }
        XCTAssertNotNil(engine.captured[.down])
        XCTAssertEqual(engine.capturedCount, 10)
        XCTAssertEqual(engine.phase, .completed)

        CaptureSessionStore.deleteSession(sessionId: engine.sessionId)
    }

    func testMotionSequenceKeepsUpdatingLastMotion() throws {
        let engine = makeTestEngine(autoComplete: false)
        engine.beginCapture()
        // Stay outside front radius after first pending so we can still update motion.
        engine.ingestMotionSample(unwrappedYaw: 0)
        XCTAssertTrue(engine.isPhotoPending)

        let samples: [Float] = [-20, -45, -90, -180]
        for yaw in samples {
            engine.ingestMotionSample(unwrappedYaw: yaw, pitchDeg: -10)
            XCTAssertEqual(engine.lastMotion.relativeYawDeg, yaw, accuracy: 0.01)
        }
        CaptureSessionStore.deleteSession(sessionId: engine.sessionId)
    }

    // MARK: - Helpers

    private func makeTestEngine(autoComplete: Bool) -> DirectionCaptureEngine {
        let engine = DirectionCaptureEngine()
        engine.enableMockSweep = false
        engine.autoCompletePhotoInMock = autoComplete
        try? engine.prepareCamera(mockMode: true)
        return engine
    }

    private func seedFrontCaptured(_ engine: DirectionCaptureEngine) {
        engine.autoCompletePhotoInMock = true
        engine.ingestMotionSample(unwrappedYaw: 0)
        XCTAssertNotNil(engine.captured[.front])
        engine.autoCompletePhotoInMock = false
    }
}
