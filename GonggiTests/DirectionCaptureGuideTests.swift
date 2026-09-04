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

    func testCrossesTargetOnNearMissStep() {
        // 43 → 47 must capture front_right (45) without landing on 45.
        XCTAssertTrue(
            DirectionCaptureGuide.crossesTarget(previousYaw: 43, currentYaw: 47, targetYaw: 45)
        )
        XCTAssertFalse(
            DirectionCaptureGuide.crossesTarget(previousYaw: 40, currentYaw: 44, targetYaw: 45)
        )
        XCTAssertTrue(
            DirectionCaptureGuide.crossesTarget(previousYaw: 44.4, currentYaw: 46.1, targetYaw: 45)
        )
    }

    func testCrossesTargetAtBackAndWrapRegion() {
        XCTAssertTrue(
            DirectionCaptureGuide.crossesTarget(previousYaw: 178, currentYaw: 182, targetYaw: 180)
        )
        XCTAssertTrue(
            DirectionCaptureGuide.crossesTarget(previousYaw: 313, currentYaw: 318, targetYaw: 315)
        )
        // Unwrapped past 360 still works for a target on first lap only if target ≤ current.
        XCTAssertFalse(
            DirectionCaptureGuide.crossesTarget(previousYaw: 320, currentYaw: 330, targetYaw: 315)
        )
    }

    func testBestFramePicksClosestYaw() {
        let frames = [41, 43, 44.4, 46.1, 48].enumerated().map { i, yaw in
            DirectionBufferedFrame(
                image: UIImage(),
                unwrappedYaw: yaw,
                pitchDeg: 0, rollDeg: 0,
                timestamp: TimeInterval(i),
                sharpness: 50,
                rotationRate: 0.2
            )
        }
        let best = DirectionCaptureGuide.bestFrame(in: frames, targetYaw: 45)
        XCTAssertEqual(best?.unwrappedYaw ?? -1, 44.4, accuracy: 0.01)
    }

    func testBestFrameTieBreakPrefersSharper() {
        let a = DirectionBufferedFrame(
            image: UIImage(), unwrappedYaw: 44, pitchDeg: 0, rollDeg: 0,
            timestamp: 0, sharpness: 10, rotationRate: 0.2
        )
        let b = DirectionBufferedFrame(
            image: UIImage(), unwrappedYaw: 46, pitchDeg: 0, rollDeg: 0,
            timestamp: 1, sharpness: 200, rotationRate: 0.2
        )
        // Equal distance 1° → sharper wins
        let best = DirectionCaptureGuide.bestFrame(in: [a, b], targetYaw: 45)
        XCTAssertEqual(best?.sharpness ?? 0, 200, accuracy: 0.1)
    }

    func testUpDownPitchClassification() {
        XCTAssertEqual(DirectionCaptureGuide.classifyVertical(pitchDeg: 80), .up)
        XCTAssertEqual(DirectionCaptureGuide.classifyVertical(pitchDeg: -80), .down)
        XCTAssertNil(DirectionCaptureGuide.classifyVertical(pitchDeg: 20))
    }

    func testExtremePoseOnlyAtHighPitch() {
        XCTAssertFalse(DirectionCaptureGuide.isExtremePose(pitchDeg: -35, rollDeg: 5))
        XCTAssertFalse(DirectionCaptureGuide.isExtremePose(pitchDeg: 40, rollDeg: 10))
        XCTAssertTrue(DirectionCaptureGuide.isExtremePose(pitchDeg: 65, rollDeg: 0))
    }

    func testNormalizeYaw0to360() {
        XCTAssertEqual(DirectionCaptureGuide.normalizeYaw0to360(-45), 315, accuracy: 0.01)
        XCTAssertEqual(DirectionCaptureGuide.normalizeYaw0to360(405), 45, accuracy: 0.01)
    }

    func testFileNamesMatchCanonical() {
        XCTAssertEqual(DirectionName.frontRight.fileName, "front_right.jpg")
        XCTAssertEqual(DirectionName.backLeft.rawValue, "back_left")
    }

    func testContinuousYawSequenceCapturesFrontRightOnCrossing() throws {
        let engine = DirectionCaptureEngine()
        try engine.prepareCamera(mockMode: true)
        engine.beginCapture()

        // Front auto (delay=0)
        engine.ingestSyntheticFrame(
            image: DirectionCaptureEngine.makeMockImage(direction: .front),
            unwrappedYaw: 0.5, pitchDeg: -8, timestamp: 0.01, sharpness: 100
        )
        XCTAssertNotNil(engine.captured[.front])

        // Sequence that never lands on exactly 45°
        let seq: [Float] = [3, 7, 12, 18, 25, 31, 38, 43, 47, 52]
        for (i, yaw) in seq.enumerated() {
            engine.ingestSyntheticFrame(
                image: DirectionCaptureEngine.makeMockImage(direction: .frontRight),
                unwrappedYaw: yaw, pitchDeg: -15, rotationRate: 0.4,
                timestamp: TimeInterval(i) * 0.05 + 0.1,
                sharpness: 90
            )
        }
        XCTAssertNotNil(engine.captured[.frontRight], "43→47 must capture front_right")
        XCTAssertEqual(engine.capturedCount, 2)
        CaptureSessionStore.deleteSession(sessionId: engine.sessionId)
    }

    func testFullContinuousSweepCapturesEightHorizontalsOnce() throws {
        let engine = DirectionCaptureEngine()
        try engine.prepareCamera(mockMode: true)
        engine.beginCapture()

        engine.ingestSyntheticFrame(
            image: DirectionCaptureEngine.makeMockImage(direction: .front),
            unwrappedYaw: 0, pitchDeg: 0, timestamp: 0, sharpness: 120
        )
        XCTAssertNotNil(engine.captured[.front])

        // Dense continuous yaw 0→360 with intentional near-misses at each 45° multiple.
        var yaws: [Float] = []
        for t in stride(from: 45, through: 315, by: 45) {
            // approach then cross without hitting exactly t
            for s in stride(from: Float(t) - 12, through: Float(t) + 8, by: 3.5) {
                yaws.append(s)
            }
        }
        for (i, yaw) in yaws.enumerated() {
            engine.ingestSyntheticFrame(
                image: DirectionCaptureEngine.makeMockImage(direction: .right),
                unwrappedYaw: yaw,
                pitchDeg: -32, // would have failed old ≤28 gate
                rotationRate: 0.55, // would have failed old <0.45 gate
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

        // Up / down via threshold crossing
        for pitch in stride(from: 10, through: 85, by: 10) {
            engine.ingestSyntheticFrame(
                image: DirectionCaptureEngine.makeMockImage(direction: .up),
                unwrappedYaw: 320, pitchDeg: Float(pitch),
                timestamp: 10 + TimeInterval(pitch), sharpness: 70
            )
        }
        XCTAssertNotNil(engine.captured[.up])

        for pitch in stride(from: 20, through: -85, by: -12) {
            engine.ingestSyntheticFrame(
                image: DirectionCaptureEngine.makeMockImage(direction: .down),
                unwrappedYaw: 320, pitchDeg: Float(pitch),
                timestamp: 20 + TimeInterval(abs(pitch)), sharpness: 70
            )
        }
        XCTAssertNotNil(engine.captured[.down])
        XCTAssertEqual(engine.capturedCount, 10)
        XCTAssertEqual(engine.phase, .completed)

        CaptureSessionStore.deleteSession(sessionId: engine.sessionId)
    }

    func testDuplicateHorizontalNotRecaptured() throws {
        let engine = DirectionCaptureEngine()
        try engine.prepareCamera(mockMode: true)
        engine.beginCapture()
        engine.ingestSyntheticFrame(
            image: DirectionCaptureEngine.makeMockImage(direction: .front),
            unwrappedYaw: 0, pitchDeg: 0, timestamp: 0, sharpness: 100
        )
        // Cross 45 twice-worth of motion after already past
        for yaw: Float in [40, 50, 60, 70, 80, 95] {
            engine.ingestSyntheticFrame(
                image: DirectionCaptureEngine.makeMockImage(direction: .frontRight),
                unwrappedYaw: yaw, pitchDeg: 0, timestamp: TimeInterval(yaw), sharpness: 90
            )
        }
        XCTAssertEqual(
            engine.captured.keys.filter { $0 == .frontRight }.count,
            1
        )
        CaptureSessionStore.deleteSession(sessionId: engine.sessionId)
    }
}
