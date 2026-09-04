import XCTest
import UIKit
@testable import Gonggi

final class DirectionCaptureGuideTests: XCTestCase {
    override func setUp() {
        super.setUp()
        DirectionCaptureConfig.frontAutoCaptureDelaySec = 0
        DirectionCaptureConfig.frameBufferCapacity = 24
    }

    override func tearDown() {
        DirectionCaptureConfig.frontAutoCaptureDelaySec = 0.18
        DirectionCaptureConfig.frameBufferCapacity = 18
        super.tearDown()
    }

    func testCrossesTargetOnDecreasingNearMiss() {
        // Device right-turn: -42 → -48 crosses -45 (front_right).
        XCTAssertTrue(
            DirectionCaptureGuide.crossesTarget(previousYaw: -42, currentYaw: -48, targetYaw: -45)
        )
        XCTAssertFalse(
            DirectionCaptureGuide.crossesTarget(previousYaw: -40, currentYaw: -44, targetYaw: -45)
        )
        XCTAssertTrue(
            DirectionCaptureGuide.crossesTarget(previousYaw: -44.4, currentYaw: -46.1, targetYaw: -45)
        )
        // Increasing path must NOT count (wrong direction for this device).
        XCTAssertFalse(
            DirectionCaptureGuide.crossesTarget(previousYaw: 43, currentYaw: 47, targetYaw: 45)
        )
    }

    func testCrossesTargetAtBackAndFrontLeftDecreasing() {
        XCTAssertTrue(
            DirectionCaptureGuide.crossesTarget(previousYaw: -178, currentYaw: -182, targetYaw: -180)
        )
        XCTAssertTrue(
            DirectionCaptureGuide.crossesTarget(previousYaw: -313, currentYaw: -318, targetYaw: -315)
        )
        XCTAssertFalse(
            DirectionCaptureGuide.crossesTarget(previousYaw: -320, currentYaw: -330, targetYaw: -315)
        )
    }

    func testTargetYawMatchesDeviceRightTurnConvention() {
        XCTAssertEqual(DirectionName.front.targetYawDeg, 0)
        XCTAssertEqual(DirectionName.frontRight.targetYawDeg, -45)
        XCTAssertEqual(DirectionName.right.targetYawDeg, -90)
        XCTAssertEqual(DirectionName.back.targetYawDeg, -180)
        XCTAssertEqual(DirectionName.left.targetYawDeg, -270)
        // Display mapping matches device measurements
        XCTAssertEqual(DirectionCaptureGuide.normalizeYaw0to360(-90), 270, accuracy: 0.01)
        XCTAssertEqual(DirectionCaptureGuide.normalizeYaw0to360(-270), 90, accuracy: 0.01)
        XCTAssertEqual(DirectionCaptureGuide.normalizeYaw0to360(-180), 180, accuracy: 0.01)
        XCTAssertEqual(DirectionCaptureGuide.normalizeYaw0to360(-45), 315, accuracy: 0.01)
    }

    func testBestFramePicksClosestYawDecreasing() {
        let frames = [-41, -43, -44.4, -46.1, -48].enumerated().map { i, yaw in
            DirectionBufferedFrame(
                image: UIImage(),
                unwrappedYaw: yaw,
                pitchDeg: 0, rollDeg: 0, elevationDeg: 0,
                timestamp: TimeInterval(i),
                sharpness: 50,
                rotationRate: 0.2
            )
        }
        let best = DirectionCaptureGuide.bestFrame(in: frames, targetYaw: -45)
        XCTAssertEqual(best?.unwrappedYaw ?? 0, -44.4, accuracy: 0.01)
    }

    func testElevationDistinguishesUpAndDownWhenPitchIdentical() {
        // Device: looking up and down both reported relative pitch ≈ -75°.
        XCTAssertEqual(DirectionCaptureGuide.classifyElevation(elevationDeg: 70), .up)
        XCTAssertEqual(DirectionCaptureGuide.classifyElevation(elevationDeg: -70), .down)
        XCTAssertNil(DirectionCaptureGuide.classifyElevation(elevationDeg: 10))
        // Same relative pitch value must not be used for vertical classify anymore.
    }

    func testElevationFromGravityLooksUpVsDown() {
        // Camera ≈ device −Z. Face-up (gravity −Z) → camera toward ground → down.
        let down = DirectionCaptureGuide.elevationDeg(gravityX: 0, gravityY: 0, gravityZ: -1)
        XCTAssertLessThan(down, -50)
        // Face-down (gravity +Z) → camera toward sky → up.
        let up = DirectionCaptureGuide.elevationDeg(gravityX: 0, gravityY: 0, gravityZ: 1)
        XCTAssertGreaterThan(up, 50)
    }

    func testExtremePoseOnlyAtHighPitch() {
        XCTAssertFalse(DirectionCaptureGuide.isExtremePose(pitchDeg: -35, rollDeg: 5))
        XCTAssertTrue(DirectionCaptureGuide.isExtremePose(pitchDeg: 65, rollDeg: 0))
    }

    func testFileNamesMatchCanonical() {
        XCTAssertEqual(DirectionName.frontRight.fileName, "front_right.jpg")
        XCTAssertEqual(DirectionName.backLeft.rawValue, "back_left")
    }

    func testContinuousYawSequenceCapturesFrontRightOnDecreasingCrossing() throws {
        let engine = DirectionCaptureEngine()
        engine.enableMockSweep = false
        try engine.prepareCamera(mockMode: true)
        engine.beginCapture()

        engine.ingestSyntheticFrame(
            image: DirectionCaptureEngine.makeMockImage(direction: .front),
            unwrappedYaw: -0.5, pitchDeg: -8, timestamp: 0.01, sharpness: 100
        )
        XCTAssertNotNil(engine.captured[.front])

        // Never lands exactly on -45
        let seq: [Float] = [-3, -7, -12, -18, -25, -31, -38, -43, -47, -52]
        for (i, yaw) in seq.enumerated() {
            engine.ingestSyntheticFrame(
                image: DirectionCaptureEngine.makeMockImage(direction: .frontRight),
                unwrappedYaw: yaw, pitchDeg: -15, rotationRate: 0.4,
                timestamp: TimeInterval(i) * 0.05 + 0.1,
                sharpness: 90
            )
        }
        XCTAssertNotNil(engine.captured[.frontRight], "-43→-47 must capture front_right")
        XCTAssertEqual(engine.capturedCount, 2)
        CaptureSessionStore.deleteSession(sessionId: engine.sessionId)
    }

    func testFullDecreasingSweepCapturesEightHorizontalsOnce() throws {
        let engine = DirectionCaptureEngine()
        engine.enableMockSweep = false
        try engine.prepareCamera(mockMode: true)
        engine.beginCapture()

        engine.ingestSyntheticFrame(
            image: DirectionCaptureEngine.makeMockImage(direction: .front),
            unwrappedYaw: 0, pitchDeg: 0, timestamp: 0, sharpness: 120
        )
        XCTAssertNotNil(engine.captured[.front])

        var yaws: [Float] = []
        for t in stride(from: -45, through: -315, by: -45) {
            for s in stride(from: Float(t) + 12, through: Float(t) - 8, by: -3.5) {
                yaws.append(s)
            }
        }
        for (i, yaw) in yaws.enumerated() {
            engine.ingestSyntheticFrame(
                image: DirectionCaptureEngine.makeMockImage(direction: .right),
                unwrappedYaw: yaw,
                pitchDeg: -32,
                rotationRate: 0.55,
                timestamp: TimeInterval(i) * 0.02 + 0.2,
                sharpness: 80
            )
        }

        for dir in DirectionName.horizontalOrder {
            XCTAssertNotNil(engine.captured[dir], "missing \(dir.rawValue)")
        }
        XCTAssertEqual(
            DirectionName.horizontalOrder.filter { engine.captured[$0] != nil }.count,
            8
        )

        // Up / down via gravity elevation (pitch stays ~-75 style)
        for elev in stride(from: 10, through: 75, by: 10) {
            engine.ingestSyntheticFrame(
                image: DirectionCaptureEngine.makeMockImage(direction: .up),
                unwrappedYaw: -320, pitchDeg: -75,
                elevationDeg: Float(elev),
                timestamp: 10 + TimeInterval(elev), sharpness: 70
            )
        }
        XCTAssertNotNil(engine.captured[.up])

        for elev in stride(from: 20, through: -75, by: -12) {
            engine.ingestSyntheticFrame(
                image: DirectionCaptureEngine.makeMockImage(direction: .down),
                unwrappedYaw: -320, pitchDeg: -75,
                elevationDeg: Float(elev),
                timestamp: 20 + TimeInterval(abs(elev)), sharpness: 70
            )
        }
        XCTAssertNotNil(engine.captured[.down])
        XCTAssertEqual(engine.capturedCount, 10)
        XCTAssertEqual(engine.phase, .completed)

        CaptureSessionStore.deleteSession(sessionId: engine.sessionId)
    }

    func testDuplicateHorizontalNotRecaptured() throws {
        let engine = DirectionCaptureEngine()
        engine.enableMockSweep = false
        try engine.prepareCamera(mockMode: true)
        engine.beginCapture()
        engine.ingestSyntheticFrame(
            image: DirectionCaptureEngine.makeMockImage(direction: .front),
            unwrappedYaw: 0, pitchDeg: 0, timestamp: 0, sharpness: 100
        )
        for yaw: Float in [-40, -50, -60, -70, -80, -95] {
            engine.ingestSyntheticFrame(
                image: DirectionCaptureEngine.makeMockImage(direction: .frontRight),
                unwrappedYaw: yaw, pitchDeg: 0, timestamp: TimeInterval(abs(yaw)), sharpness: 90
            )
        }
        XCTAssertEqual(
            engine.captured.keys.filter { $0 == .frontRight }.count,
            1
        )
        CaptureSessionStore.deleteSession(sessionId: engine.sessionId)
    }

    func testMotionSequenceKeepsUpdatingLastMotion() throws {
        let engine = DirectionCaptureEngine()
        engine.enableMockSweep = false
        try engine.prepareCamera(mockMode: true)
        engine.beginCapture()

        // Device right-turn display path: 0 → 315 → 270 …
        let samples: [(Float, Float)] = [
            (0, 0), (-20, -5), (-45, -10), (-70, -12), (-90, -8),
            (-135, -15), (-180, -20), (-225, -18), (-270, -10), (-315, -6)
        ]
        for (i, sample) in samples.enumerated() {
            engine.ingestSyntheticFrame(
                image: DirectionCaptureEngine.makeMockImage(direction: .front),
                unwrappedYaw: sample.0,
                pitchDeg: sample.1,
                timestamp: TimeInterval(i) * 0.05,
                sharpness: 80
            )
            XCTAssertEqual(engine.lastMotion.relativeYawDeg, sample.0, accuracy: 0.01)
            XCTAssertEqual(
                engine.lastMotion.yaw0to360,
                DirectionCaptureGuide.normalizeYaw0to360(sample.0),
                accuracy: 0.01
            )
            XCTAssertEqual(engine.lastMotion.pitchDeg, sample.1, accuracy: 0.01)
        }
        CaptureSessionStore.deleteSession(sessionId: engine.sessionId)
    }
}
