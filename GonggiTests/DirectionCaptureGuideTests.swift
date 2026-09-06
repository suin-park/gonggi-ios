import XCTest
@testable import Gonggi

final class DirectionCaptureGuideTests: XCTestCase {
    override func tearDown() {
        DirectionCaptureConfig.captureToleranceDeg = 8
        DirectionCaptureConfig.obliqueYawToleranceDeg = 15
        DirectionCaptureConfig.elevationToleranceDeg = 8
        super.tearDown()
    }

    func testRequiredCountIs20AndOrderIsCanonical() {
        XCTAssertEqual(DirectionName.requiredCount, 20)
        XCTAssertEqual(DirectionName.captureOrder.count, 20)
        XCTAssertEqual(DirectionName.horizontalOrder.count, 12)
        XCTAssertEqual(DirectionName.upperObliqueOrder.count, 4)
        XCTAssertEqual(DirectionName.lowerObliqueOrder.count, 4)
        XCTAssertEqual(Set(DirectionName.captureOrder.map(\.rawValue)).count, 20)
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
        XCTAssertEqual(DirectionName.frontRight30.targetYawDeg, -30)
        XCTAssertEqual(DirectionName.frontRight60.targetYawDeg, -60)
        XCTAssertEqual(DirectionName.right.targetYawDeg, -90)
        XCTAssertEqual(DirectionName.backRight120.targetYawDeg, -120)
        XCTAssertEqual(DirectionName.backRight150.targetYawDeg, -150)
        XCTAssertEqual(DirectionName.back.targetYawDeg, -180)
        XCTAssertEqual(DirectionName.backLeft210.targetYawDeg, -210)
        XCTAssertEqual(DirectionName.backLeft240.targetYawDeg, -240)
        XCTAssertEqual(DirectionName.left.targetYawDeg, -270)
        XCTAssertEqual(DirectionName.frontLeft300.targetYawDeg, -300)
        XCTAssertEqual(DirectionName.frontLeft330.targetYawDeg, -330)
    }

    func testObliqueYawAndElevationTargets() {
        XCTAssertEqual(DirectionName.upFrontRight.targetYawDeg, -45)
        XCTAssertEqual(DirectionName.upBackRight.targetYawDeg, -135)
        XCTAssertEqual(DirectionName.upBackLeft.targetYawDeg, -225)
        XCTAssertEqual(DirectionName.upFrontLeft.targetYawDeg, -315)
        XCTAssertEqual(DirectionName.downFrontRight.targetYawDeg, -45)
        XCTAssertEqual(DirectionName.upFrontRight.targetElevationDeg, 60)
        XCTAssertEqual(DirectionName.downFrontLeft.targetElevationDeg, -60)
    }

    func testYawToleranceHorizontalDefault8() {
        XCTAssertTrue(DirectionCaptureGuide.withinYawTolerance(currentYaw: -8, targetYaw: 0))
        XCTAssertFalse(DirectionCaptureGuide.withinYawTolerance(currentYaw: -9, targetYaw: 0))
        XCTAssertTrue(DirectionCaptureGuide.withinYawTolerance(currentYaw: -30, targetYaw: -30))
        XCTAssertFalse(DirectionCaptureGuide.withinYawTolerance(currentYaw: -39, targetYaw: -30))
    }

    func testObliqueYawTolerance15() {
        XCTAssertTrue(DirectionCaptureGuide.withinYawTolerance(
            currentYaw: -60, targetYaw: -45, toleranceDeg: DirectionCaptureConfig.obliqueYawToleranceDeg
        ))
        XCTAssertFalse(DirectionCaptureGuide.withinYawTolerance(
            currentYaw: -61, targetYaw: -45, toleranceDeg: DirectionCaptureConfig.obliqueYawToleranceDeg
        ))
    }

    func testElevationBandForOblique() {
        XCTAssertTrue(DirectionCaptureGuide.withinElevationTolerance(elevationDeg: 52, targetElevation: 60))
        XCTAssertFalse(DirectionCaptureGuide.withinElevationTolerance(elevationDeg: 51, targetElevation: 60))
        XCTAssertTrue(DirectionCaptureGuide.withinElevationTolerance(elevationDeg: -68, targetElevation: -60))
        XCTAssertFalse(DirectionCaptureGuide.withinElevationTolerance(elevationDeg: -69, targetElevation: -60))
    }

    func testFileNamesMatchCanonical() {
        XCTAssertEqual(DirectionName.frontRight30.fileName, "front_right_30.jpg")
        XCTAssertEqual(DirectionName.upFrontRight.fileName, "up_front_right.jpg")
        XCTAssertEqual(DirectionName.downBackLeft.fileName, "down_back_left.jpg")
    }

    // MARK: - Engine

    func testHorizontalOrderAdvancesAndProgressUses20() {
        let engine = DirectionCaptureEngine()
        engine.enableMockSweep = false
        engine.autoCompletePhotoInMock = true
        try? engine.prepareCamera(mockMode: true)
        engine.beginCapture()
        XCTAssertEqual(engine.progressText, "0 / 20")
        XCTAssertEqual(engine.currentTarget, .front)

        engine.ingestMotionSample(unwrappedYaw: 0, pitchDeg: -5)
        XCTAssertNotNil(engine.captured[.front])
        XCTAssertEqual(engine.progressText, "1 / 20")
        XCTAssertEqual(engine.currentTarget, .frontRight30)

        engine.ingestMotionSample(unwrappedYaw: -30, pitchDeg: -5)
        XCTAssertNotNil(engine.captured[.frontRight30])
        XCTAssertEqual(engine.currentTarget, .frontRight60)
    }

    func testPendingBlocksDuplicateHorizontalRequest() {
        let engine = DirectionCaptureEngine()
        engine.enableMockSweep = false
        engine.autoCompletePhotoInMock = false
        try? engine.prepareCamera(mockMode: true)
        engine.beginCapture()
        engine.ingestMotionSample(unwrappedYaw: 0)
        XCTAssertEqual(engine.pendingDirection, .front)
        XCTAssertEqual(engine.photoRequestCounts[.front] ?? 0, 1)
        engine.ingestMotionSample(unwrappedYaw: 0)
        XCTAssertEqual(engine.photoRequestCounts[.front] ?? 0, 1)
        engine.completePendingPhotoForTests(success: true)
        XCTAssertNotNil(engine.captured[.front])
    }

    func testFullTwentyShotSequencePhases() {
        let engine = DirectionCaptureEngine()
        engine.enableMockSweep = false
        engine.autoCompletePhotoInMock = true
        try? engine.prepareCamera(mockMode: true)
        engine.beginCapture()

        for yaw: Float in [0, -30, -60, -90, -120, -150, -180, -210, -240, -270, -300, -330] {
            engine.ingestMotionSample(unwrappedYaw: yaw, pitchDeg: -5, elevationDeg: 0)
        }
        XCTAssertEqual(engine.capturedCount, 12)
        XCTAssertEqual(engine.phase, .capturingUpperOblique)
        XCTAssertEqual(engine.currentTarget, .upFrontRight)

        for yaw: Float in [-45, -135, -225, -315] {
            engine.ingestMotionSample(unwrappedYaw: yaw, elevationDeg: 60)
        }
        XCTAssertEqual(engine.capturedCount, 16)
        XCTAssertEqual(engine.phase, .capturingLowerOblique)
        XCTAssertEqual(engine.currentTarget, .downFrontRight)

        for yaw: Float in [-45, -135, -225, -315] {
            engine.ingestMotionSample(unwrappedYaw: yaw, elevationDeg: -60)
        }
        XCTAssertEqual(engine.capturedCount, 20)
        XCTAssertEqual(engine.phase, .completed)
        XCTAssertEqual(engine.progressText, "20 / 20")
    }

    func testUpperObliqueRequiresBothYawAndElevation() {
        let engine = DirectionCaptureEngine()
        engine.enableMockSweep = false
        engine.autoCompletePhotoInMock = true
        try? engine.prepareCamera(mockMode: true)
        engine.beginCapture()
        for yaw: Float in [0, -30, -60, -90, -120, -150, -180, -210, -240, -270, -300, -330] {
            engine.ingestMotionSample(unwrappedYaw: yaw, pitchDeg: -5, elevationDeg: 0)
        }
        // Correct yaw but flat elevation — should not fire.
        engine.ingestMotionSample(unwrappedYaw: -45, elevationDeg: 10)
        XCTAssertEqual(engine.photoRequestCounts[.upFrontRight] ?? 0, 0)
        // Elevation ok but wrong yaw.
        engine.ingestMotionSample(unwrappedYaw: -90, elevationDeg: 60)
        XCTAssertEqual(engine.photoRequestCounts[.upFrontRight] ?? 0, 0)
        engine.ingestMotionSample(unwrappedYaw: -45, elevationDeg: 60)
        XCTAssertEqual(engine.photoRequestCounts[.upFrontRight] ?? 0, 1)
        XCTAssertNotNil(engine.captured[.upFrontRight])
    }

    func testSaveSuccessOnlyThenAdvance() {
        let engine = DirectionCaptureEngine()
        engine.enableMockSweep = false
        engine.autoCompletePhotoInMock = false
        try? engine.prepareCamera(mockMode: true)
        engine.beginCapture()
        engine.ingestMotionSample(unwrappedYaw: 0)
        XCTAssertEqual(engine.pendingDirection, .front)
        XCTAssertNil(engine.captured[.front])
        XCTAssertEqual(engine.currentTarget, .front)
        engine.completePendingPhotoForTests(success: true)
        XCTAssertNotNil(engine.captured[.front])
        XCTAssertEqual(engine.currentTarget, .frontRight30)
        XCTAssertEqual(engine.progressText, "1 / 20")
    }

    func testUploadPreparationKeepsTwentyImagesUnderSoftBudget() throws {
        let sessionId = "dir-upload-budget-\(UUID().uuidString)"
        let dir = try CaptureSessionStore.createDirectionCaptureDirectory(sessionId: sessionId)
        defer { CaptureSessionStore.deleteSession(sessionId: sessionId) }

        var files: [(direction: String, fileURL: URL)] = []
        for name in DirectionName.captureOrder {
            // Simulate a large portrait capture before client compress.
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
            SpaceRecordUploadPreparer.preferredMultipartBudgetBytes,
            "20-shot multipart must stay under soft Vercel budget"
        )
        // Log numbers only (no image bodies).
        print(
            "[uploadBudget] totalImageBytes=\(prepared.report.totalImageBytes)"
                + " estimatedMultipart=\(prepared.report.estimatedMultipartBytes)"
        )
    }
}
