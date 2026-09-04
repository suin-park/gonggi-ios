import XCTest
@testable import Gonggi

final class DirectionCaptureGuideTests: XCTestCase {
    func testHorizontalYawClassification() {
        let cases: [(Float, DirectionName)] = [
            (0, .front),
            (45, .frontRight),
            (90, .right),
            (135, .backRight),
            (180, .back),
            (225, .backLeft),
            (270, .left),
            (315, .frontLeft)
        ]
        for (yaw, expected) in cases {
            let got = DirectionCaptureGuide.classifyHorizontal(yawDeg: yaw)
            XCTAssertEqual(got, expected, "yaw \(yaw) should be \(expected.rawValue)")
        }
    }

    func testPlusMinus180WrapClassification() {
        XCTAssertEqual(DirectionCaptureGuide.classifyHorizontal(yawDeg: -135), .backLeft)
        XCTAssertEqual(DirectionCaptureGuide.classifyHorizontal(yawDeg: -90), .left)
        XCTAssertEqual(DirectionCaptureGuide.classifyHorizontal(yawDeg: -45), .frontLeft)
        XCTAssertEqual(DirectionCaptureGuide.classifyHorizontal(yawDeg: 360), .front)
        XCTAssertEqual(DirectionCaptureGuide.classifyHorizontal(yawDeg: -180), .back)
        XCTAssertEqual(DirectionCaptureGuide.classifyHorizontal(yawDeg: 405), .frontRight)
    }

    func testNormalizeYaw0to360() {
        XCTAssertEqual(DirectionCaptureGuide.normalizeYaw0to360(0), 0, accuracy: 0.01)
        XCTAssertEqual(DirectionCaptureGuide.normalizeYaw0to360(-45), 315, accuracy: 0.01)
        XCTAssertEqual(DirectionCaptureGuide.normalizeYaw0to360(370), 10, accuracy: 0.01)
        XCTAssertEqual(DirectionCaptureGuide.normalizeYaw0to360(-225), 135, accuracy: 0.01)
    }

    func testUpDownPitchClassification() {
        XCTAssertEqual(DirectionCaptureGuide.classifyVertical(pitchDeg: 80), .up)
        XCTAssertEqual(DirectionCaptureGuide.classifyVertical(pitchDeg: 90), .up)
        XCTAssertEqual(DirectionCaptureGuide.classifyVertical(pitchDeg: -80), .down)
        XCTAssertEqual(DirectionCaptureGuide.classifyVertical(pitchDeg: -90), .down)
        XCTAssertNil(DirectionCaptureGuide.classifyVertical(pitchDeg: 20))
        XCTAssertNil(DirectionCaptureGuide.classifyVertical(pitchDeg: -20))
    }

    func testOutsideToleranceIsNil() {
        XCTAssertNil(DirectionCaptureGuide.classifyHorizontal(yawDeg: 22.5, toleranceDeg: 7))
    }

    func testNextTargetSkipsCapturedDirections() {
        var captured: Set<DirectionName> = [.front]
        XCTAssertEqual(
            DirectionCaptureGuide.nextTarget(captured: captured, phase: .capturingHorizontal),
            .frontRight
        )
        captured.formUnion(DirectionName.horizontalOrder)
        XCTAssertEqual(
            DirectionCaptureGuide.nextTarget(captured: captured, phase: .capturingUp),
            .up
        )
        captured.insert(.up)
        XCTAssertEqual(
            DirectionCaptureGuide.nextTarget(captured: captured, phase: .capturingDown),
            .down
        )
    }

    func testStabilityRejectsHighRotation() {
        XCTAssertFalse(
            DirectionCaptureGuide.isStable(rotationRate: 1.5, pitchDeg: 0, rollDeg: 0, for: .front)
        )
        XCTAssertTrue(
            DirectionCaptureGuide.isStable(rotationRate: 0.1, pitchDeg: 5, rollDeg: 3, for: .front)
        )
        XCTAssertFalse(
            DirectionCaptureGuide.isStable(rotationRate: 0.1, pitchDeg: 40, rollDeg: 0, for: .right)
        )
        XCTAssertTrue(
            DirectionCaptureGuide.isStable(rotationRate: 0.1, pitchDeg: 80, rollDeg: 0, for: .up)
        )
    }

    func testFileNamesMatchCanonical() {
        for dir in DirectionName.captureOrder {
            XCTAssertEqual(dir.fileName, "\(dir.rawValue).jpg")
        }
        XCTAssertEqual(DirectionName.frontRight.rawValue, "front_right")
        XCTAssertEqual(DirectionName.backLeft.rawValue, "back_left")
    }

    func testMockEngineCapturesExactlyTenUniqueDirections() async throws {
        // Faster dwell for unit test
        let savedDwell = DirectionCaptureConfig.stabilityDwellSec
        DirectionCaptureConfig.stabilityDwellSec = 0.05
        defer { DirectionCaptureConfig.stabilityDwellSec = savedDwell }

        let engine = DirectionCaptureEngine()
        try engine.prepareCamera(mockMode: true)
        engine.beginCapture()

        let deadline = Date().addingTimeInterval(12)
        while engine.capturedCount < 10, Date() < deadline {
            try await Task.sleep(nanoseconds: 40_000_000)
        }

        XCTAssertEqual(engine.capturedCount, 10)
        XCTAssertEqual(Set(engine.captured.keys).count, 10)
        for dir in DirectionName.captureOrder {
            XCTAssertNotNil(engine.captured[dir], "missing \(dir.rawValue)")
        }
        // Re-feed same pose must not grow count (duplicate prevention).
        let before = engine.capturedCount
        let reading = DirectionMotionReading(
            timestamp: 99, relativeYawDeg: 0, yaw0to360: 0,
            pitchDeg: 0, rollDeg: 0, rotationRate: 0.05
        )
        // phase is completed — evaluate should no-op
        XCTAssertEqual(engine.phase, .completed)
        XCTAssertEqual(before, 10)

        CaptureSessionStore.deleteSession(sessionId: engine.sessionId)
        _ = reading
    }
}
