import XCTest
@testable import Gonggi

final class DirectionCaptureGuideTests: XCTestCase {
    override func tearDown() {
        DirectionCaptureConfig.captureToleranceDeg = 8
        DirectionCaptureConfig.obliqueRelativeYawToleranceDeg = 12
        DirectionCaptureConfig.upperObliqueElevationMinDeg = 45
        DirectionCaptureConfig.upperObliqueElevationMaxDeg = 65
        DirectionCaptureConfig.lowerObliqueElevationMinDeg = -65
        DirectionCaptureConfig.lowerObliqueElevationMaxDeg = -45
        super.tearDown()
    }

    func testRequiredCountIs20AndOrderIsCanonical() {
        XCTAssertEqual(DirectionName.requiredCount, 20)
        XCTAssertEqual(DirectionName.captureOrder.map(\.rawValue), [
            "front", "front_right_30", "front_right_60", "right",
            "back_right_120", "back_right_150", "back",
            "back_left_210", "back_left_240", "left",
            "front_left_300", "front_left_330",
            "up_front_right", "up_back_right", "up_back_left", "up_front_left",
            "down_front_right", "down_back_right", "down_back_left", "down_front_left",
        ])
    }

    func testHorizontalYawTargetsAt30DegreeSteps() {
        XCTAssertEqual(DirectionName.front.targetYawDeg, 0)
        XCTAssertEqual(DirectionName.right.targetYawDeg, -90)
        XCTAssertEqual(DirectionName.frontLeft330.targetYawDeg, -330)
    }

    func testElevationBandsAreLoose() {
        XCTAssertTrue(DirectionCaptureGuide.isUpperObliqueElevationBand(45))
        XCTAssertTrue(DirectionCaptureGuide.isUpperObliqueElevationBand(65))
        XCTAssertFalse(DirectionCaptureGuide.isUpperObliqueElevationBand(44))
        XCTAssertFalse(DirectionCaptureGuide.isUpperObliqueElevationBand(66))
        XCTAssertTrue(DirectionCaptureGuide.isLowerObliqueElevationBand(-45))
        XCTAssertTrue(DirectionCaptureGuide.isLowerObliqueElevationBand(-65))
        XCTAssertFalse(DirectionCaptureGuide.isLowerObliqueElevationBand(-44))
        XCTAssertFalse(DirectionCaptureGuide.isLowerObliqueElevationBand(-66))
    }

    func testGuideCopyHasNoDirectionNames() {
        let h = DirectionCaptureGuide.horizontalGuideMessage(warnFast: false)
        let u = DirectionCaptureGuide.upperObliqueGuideMessage(warnFast: false, waitingForElevation: false)
        let l = DirectionCaptureGuide.lowerObliqueGuideMessage(warnFast: false, waitingForElevation: false)
        XCTAssertFalse(h.contains("up_front_right"))
        XCTAssertFalse(u.contains("up_front_right"))
        XCTAssertFalse(l.contains("down_front_left"))
        XCTAssertTrue(h.contains("오른쪽으로"))
        XCTAssertTrue(u.contains("위로"))
        XCTAssertTrue(l.contains("아래로"))
    }

    // MARK: - Engine

    func testHorizontalProgressUsesPhaseLabel() {
        let engine = DirectionCaptureEngine()
        engine.enableMockSweep = false
        engine.autoCompletePhotoInMock = true
        try? engine.prepareCamera(mockMode: true)
        engine.beginCapture()
        XCTAssertEqual(engine.progressText, "수평 0 / 12")

        engine.ingestMotionSample(unwrappedYaw: 0, pitchDeg: -5)
        XCTAssertNotNil(engine.captured[.front])
        XCTAssertEqual(engine.progressText, "수평 1 / 12")
    }

    func testPendingBlocksDuplicateHorizontalRequest() {
        let engine = DirectionCaptureEngine()
        engine.enableMockSweep = false
        engine.autoCompletePhotoInMock = false
        try? engine.prepareCamera(mockMode: true)
        engine.beginCapture()
        engine.ingestMotionSample(unwrappedYaw: 0)
        XCTAssertEqual(engine.photoRequestCounts[.front] ?? 0, 1)
        engine.ingestMotionSample(unwrappedYaw: 0)
        XCTAssertEqual(engine.photoRequestCounts[.front] ?? 0, 1)
        engine.completePendingPhotoForTests(success: true)
        XCTAssertNotNil(engine.captured[.front])
    }

    func testObliqueUsesRelativeOrbitNotAbsoluteWorldYaw() {
        let engine = DirectionCaptureEngine()
        engine.enableMockSweep = false
        engine.autoCompletePhotoInMock = true
        try? engine.prepareCamera(mockMode: true)
        engine.beginCapture()

        for yaw: Float in [0, -30, -60, -90, -120, -150, -180, -210, -240, -270, -300, -330] {
            engine.ingestMotionSample(unwrappedYaw: yaw, pitchDeg: -5, elevationDeg: 0)
        }
        XCTAssertEqual(engine.phase, .capturingUpperOblique)
        XCTAssertEqual(engine.progressText, "위쪽 0 / 4")

        // Absolute world yaw that used to match up_front_right (-45) must NOT fire before band+orbit.
        engine.ingestMotionSample(unwrappedYaw: -45, elevationDeg: 10)
        XCTAssertEqual(engine.photoRequestCounts[.upFrontRight] ?? 0, 0)

        // Enter band at arbitrary yaw (e.g. -100) → anchors orbit start.
        engine.ingestMotionSample(unwrappedYaw: -100, elevationDeg: 55)
        XCTAssertEqual(engine.photoRequestCounts[.upFrontRight] ?? 0, 1)
        XCTAssertNotNil(engine.captured[.upFrontRight])
        XCTAssertEqual(engine.progressText, "위쪽 1 / 4")

        // Next at start-90 = -190
        engine.ingestMotionSample(unwrappedYaw: -190, elevationDeg: 55)
        XCTAssertNotNil(engine.captured[.upBackRight])
        engine.ingestMotionSample(unwrappedYaw: -280, elevationDeg: 55)
        XCTAssertNotNil(engine.captured[.upBackLeft])
        engine.ingestMotionSample(unwrappedYaw: -370, elevationDeg: 55)
        XCTAssertNotNil(engine.captured[.upFrontLeft])
        XCTAssertEqual(engine.phase, .capturingLowerOblique)
        XCTAssertEqual(engine.progressText, "아래쪽 0 / 4")
    }

    func testFullTwentyShotRelativeOrbitSequence() {
        let engine = DirectionCaptureEngine()
        engine.enableMockSweep = false
        engine.autoCompletePhotoInMock = true
        try? engine.prepareCamera(mockMode: true)
        engine.beginCapture()

        for yaw: Float in [0, -30, -60, -90, -120, -150, -180, -210, -240, -270, -300, -330] {
            engine.ingestMotionSample(unwrappedYaw: yaw, pitchDeg: -5, elevationDeg: 0)
        }
        XCTAssertEqual(engine.capturedCount, 12)

        let upperStart: Float = -50
        for offset: Float in [0, -90, -180, -270] {
            engine.ingestMotionSample(unwrappedYaw: upperStart + offset, elevationDeg: 50)
        }
        XCTAssertEqual(engine.capturedCount, 16)
        XCTAssertEqual(engine.phase, .capturingLowerOblique)

        let lowerStart: Float = -50 - 270
        for offset: Float in [0, -90, -180, -270] {
            engine.ingestMotionSample(unwrappedYaw: lowerStart + offset, elevationDeg: -50)
        }
        XCTAssertEqual(engine.capturedCount, 20)
        XCTAssertEqual(engine.phase, .completed)
        XCTAssertEqual(engine.progressText, "완료 20 / 20")
    }

    func testSaveSuccessOnlyThenAdvance() {
        let engine = DirectionCaptureEngine()
        engine.enableMockSweep = false
        engine.autoCompletePhotoInMock = false
        try? engine.prepareCamera(mockMode: true)
        engine.beginCapture()
        engine.ingestMotionSample(unwrappedYaw: 0)
        XCTAssertEqual(engine.pendingDirection, .front)
        engine.completePendingPhotoForTests(success: true)
        XCTAssertNotNil(engine.captured[.front])
        XCTAssertEqual(engine.progressText, "수평 1 / 12")
    }

    func testUploadPreparationKeepsTwentyImagesUnderSoftBudget() throws {
        let sessionId = "dir-upload-budget-\(UUID().uuidString)"
        let dir = try CaptureSessionStore.createDirectionCaptureDirectory(sessionId: sessionId)
        defer { CaptureSessionStore.deleteSession(sessionId: sessionId) }

        var files: [(direction: String, fileURL: URL)] = []
        for name in DirectionName.captureOrder {
            let size = CGSize(width: 3024, height: 4032)
            let renderer = UIGraphicsImageRenderer(size: size)
            let img = renderer.image { ctx in
                UIColor.darkGray.setFill()
                ctx.fill(CGRect(origin: .zero, size: size))
            }
            let url = dir.appendingPathComponent(name.fileName)
            guard let data = img.jpegData(compressionQuality: 0.92) else {
                return XCTFail("jpeg encode failed")
            }
            try data.write(to: url)
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
