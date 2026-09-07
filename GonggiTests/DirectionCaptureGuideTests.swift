import XCTest
@testable import Gonggi

final class DirectionCaptureGuideTests: XCTestCase {
    override func tearDown() {
        DirectionCaptureConfig.captureToleranceDeg = 8
        DirectionCaptureConfig.upperObliqueElevationMinDeg = 35
        DirectionCaptureConfig.upperObliqueElevationMaxDeg = 70
        DirectionCaptureConfig.lowerObliqueElevationMinDeg = -70
        DirectionCaptureConfig.lowerObliqueElevationMaxDeg = -35
        DirectionCaptureConfig.obliqueMinAccumulatedYawDeg = [0, 70, 70, 55]
        DirectionCaptureConfig.obliqueLastShotFailSafeYawDeg = 45
        DirectionCaptureConfig.obliqueLastShotFailSafeWaitSec = 4.0
        DirectionCaptureConfig.obliqueShotSettleSec = 0.12
        DirectionCaptureConfig.frontSeamPreferredYawDeg = -327
        DirectionCaptureConfig.frontSeamSoftMinYawDeg = -325
        DirectionCaptureConfig.frontSeamSoftAcceptWaitSec = 1.8
        DirectionCaptureConfig.horizontalLevelWarnDeg = 10
        super.tearDown()
    }

    func testRequiredCountIs20AndOrderIsCanonical() {
        XCTAssertEqual(DirectionName.requiredCount, 20)
        XCTAssertEqual(Array(DirectionName.captureOrder.map(\.rawValue).prefix(4)), [
            "front", "front_right_30", "front_right_60", "right",
        ])
        XCTAssertEqual(DirectionName.captureOrder.last?.rawValue, "down_front_left")
    }

    func testElevationBandsAreRelaxed() {
        XCTAssertTrue(DirectionCaptureGuide.isUpperObliqueElevationBand(35))
        XCTAssertTrue(DirectionCaptureGuide.isUpperObliqueElevationBand(70))
        XCTAssertFalse(DirectionCaptureGuide.isUpperObliqueElevationBand(34))
        XCTAssertFalse(DirectionCaptureGuide.isUpperObliqueElevationBand(71))
        XCTAssertTrue(DirectionCaptureGuide.isLowerObliqueElevationBand(-35))
        XCTAssertTrue(DirectionCaptureGuide.isLowerObliqueElevationBand(-70))
        XCTAssertFalse(DirectionCaptureGuide.isLowerObliqueElevationBand(-34))
    }

    func testGuideCopyHasNoDirectionNames() {
        let u = DirectionCaptureGuide.upperObliqueGuideMessage(
            warnFast: false, waitingForElevation: false, stuckAtLastShot: true
        )
        XCTAssertEqual(u, "조금만 더 돌아주세요.")
        XCTAssertFalse(u.contains("up_front"))
    }

    func testHorizontalProgressUsesPhaseLabel() {
        let engine = DirectionCaptureEngine()
        engine.enableMockSweep = false
        engine.autoCompletePhotoInMock = true
        try? engine.prepareCamera(mockMode: true)
        engine.beginCapture()
        XCTAssertEqual(engine.progressText, "수평 0 / 12")
        engine.ingestMotionSample(unwrappedYaw: 0, pitchDeg: -5)
        XCTAssertEqual(engine.progressText, "수평 1 / 12")
    }

    private func completeHorizontal(_ engine: DirectionCaptureEngine) {
        for yaw: Float in [0, -30, -60, -90, -120, -150, -180, -210, -240, -270, -300, -330] {
            engine.ingestMotionSample(unwrappedYaw: yaw, pitchDeg: -5, elevationDeg: 0)
        }
    }

    private func turnRight(
        _ engine: DirectionCaptureEngine,
        from start: Float,
        by degrees: Float,
        elev: Float,
        step: Float = 10,
        time: inout TimeInterval
    ) {
        var yaw = start
        let end = start - degrees
        while yaw > end + 0.1 {
            yaw -= step
            if yaw < end { yaw = end }
            time += 0.2
            engine.ingestMotionSample(unwrappedYaw: yaw, elevationDeg: elev, timestamp: time)
        }
    }

    func testObliqueAccumulatedYawFiresWithoutAbsoluteTargets() {
        DirectionCaptureConfig.obliqueShotSettleSec = 0
        let engine = DirectionCaptureEngine()
        engine.enableMockSweep = false
        engine.autoCompletePhotoInMock = true
        try? engine.prepareCamera(mockMode: true)
        engine.beginCapture()
        completeHorizontal(engine)
        XCTAssertEqual(engine.phase, .capturingUpperOblique)

        var t: TimeInterval = 10
        engine.ingestMotionSample(unwrappedYaw: -100, elevationDeg: 50, timestamp: t)
        XCTAssertNotNil(engine.captured[.upFrontRight])
        XCTAssertEqual(engine.progressText, "위쪽 1 / 4")

        turnRight(engine, from: -100, by: 70, elev: 50, time: &t)
        XCTAssertNotNil(engine.captured[.upBackRight])
        turnRight(engine, from: -170, by: 70, elev: 50, time: &t)
        XCTAssertNotNil(engine.captured[.upBackLeft])
        turnRight(engine, from: -240, by: 55, elev: 50, time: &t)
        XCTAssertNotNil(engine.captured[.upFrontLeft])
        XCTAssertEqual(engine.phase, .capturingLowerOblique)
    }

    func testLastShotFailSafeWithLowerYawAndWait() {
        DirectionCaptureConfig.obliqueShotSettleSec = 0
        DirectionCaptureConfig.obliqueLastShotFailSafeWaitSec = 0.3
        DirectionCaptureConfig.obliqueLastShotFailSafeYawDeg = 45

        let engine = DirectionCaptureEngine()
        engine.enableMockSweep = false
        engine.autoCompletePhotoInMock = true
        try? engine.prepareCamera(mockMode: true)
        engine.beginCapture()
        completeHorizontal(engine)

        var t: TimeInterval = 20
        engine.ingestMotionSample(unwrappedYaw: -10, elevationDeg: 50, timestamp: t)
        turnRight(engine, from: -10, by: 70, elev: 50, time: &t)
        turnRight(engine, from: -80, by: 70, elev: 50, time: &t)
        XCTAssertEqual(engine.progressText, "위쪽 3 / 4")
        XCTAssertNil(engine.captured[.upFrontLeft])

        turnRight(engine, from: -150, by: 48, elev: 50, time: &t)
        Thread.sleep(forTimeInterval: 0.35)
        engine.ingestMotionSample(unwrappedYaw: -198, elevationDeg: 50, timestamp: t + 1)
        XCTAssertNotNil(engine.captured[.upFrontLeft], "last-shot fail-safe must fire")
    }

    func testFullTwentyShotAccumulatedSequence() {
        DirectionCaptureConfig.obliqueShotSettleSec = 0
        let engine = DirectionCaptureEngine()
        engine.enableMockSweep = false
        engine.autoCompletePhotoInMock = true
        try? engine.prepareCamera(mockMode: true)
        engine.beginCapture()
        completeHorizontal(engine)

        var t: TimeInterval = 30
        func oneObliquePhase(start: Float, elev: Float) {
            engine.ingestMotionSample(unwrappedYaw: start, elevationDeg: elev, timestamp: t)
            turnRight(engine, from: start, by: 70, elev: elev, time: &t)
            turnRight(engine, from: start - 70, by: 70, elev: elev, time: &t)
            turnRight(engine, from: start - 140, by: 55, elev: elev, time: &t)
        }
        oneObliquePhase(start: -40, elev: 40)
        XCTAssertEqual(engine.capturedCount, 16)
        oneObliquePhase(start: -200, elev: -40)
        XCTAssertEqual(engine.capturedCount, 20)
        XCTAssertEqual(engine.phase, .completed)
    }

    func testUploadPreparationKeepsTwentyImagesUnderSoftBudget() throws {
        let sessionId = "dir-upload-budget-\(UUID().uuidString)"
        let dir = try CaptureSessionStore.createDirectionCaptureDirectory(sessionId: sessionId)
        defer { CaptureSessionStore.deleteSession(sessionId: sessionId) }

        var files: [(direction: String, fileURL: URL)] = []
        for name in DirectionName.captureOrder {
            let size = CGSize(width: 1200, height: 1600)
            let renderer = UIGraphicsImageRenderer(size: size)
            let img = renderer.image { ctx in
                UIColor.darkGray.setFill()
                ctx.fill(CGRect(origin: .zero, size: size))
            }
            let url = dir.appendingPathComponent(name.fileName)
            try img.jpegData(compressionQuality: 0.85)!.write(to: url)
            files.append((direction: name.rawValue, fileURL: url))
        }
        let prepared = try SpaceRecordUploadPreparer.prepareUploadFiles(files, sessionId: sessionId)
        XCTAssertEqual(prepared.files.count, 20)
        XCTAssertLessThanOrEqual(
            prepared.report.estimatedMultipartBytes,
            SpaceRecordUploadPreparer.preferredMultipartBudgetBytes
        )
    }
}
