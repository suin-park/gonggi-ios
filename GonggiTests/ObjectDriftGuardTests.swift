import CoreGraphics
import XCTest
import simd
@testable import Gonggi

/// Tracking gate, anchor following, the return check and the trace time base. Synthetic data only (no ARKit): none of this is a
/// device test and none of it proves that AR drift does or does not happen on a phone.
final class ObjectDriftGuardTests: XCTestCase {
    // MARK: tracking gate

    private func gate(normalFor seconds: Double, now: Double = 100, floor: [Float]? = nil, mapping: String = "extending") -> ObjectTrackingGate {
        var g = ObjectTrackingGate()
        let start = now - seconds
        var t = start
        while t <= now {
            g.ingest(timestamp: t, tracking: "normal", mapping: mapping)
            t += 0.1
        }
        if let floor {
            for (i, y) in floor.enumerated() { g.addFloorSample(timestamp: now - 1.0 + Double(i) * 0.25, y: y) }
        }
        return g
    }

    func testPlacementNeedsNormalTrackingForAWhileAndAFloorThatHoldsStill() {
        let steady = gate(normalFor: 2.0, floor: [0.001, 0.003, 0.002, 0.004])
        XCTAssertEqual(steady.placementStatus(now: 100), .stable)

        let young = gate(normalFor: 0.5, floor: [0, 0, 0, 0])
        if case .settling = young.placementStatus(now: 100) {} else { XCTFail("normal for 0.5 s is still settling") }

        let wobbly = gate(normalFor: 2.0, floor: [0.00, 0.03, -0.01, 0.04])
        XCTAssertEqual(wobbly.placementStatus(now: 100), .floorUnsteady)

        let none = gate(normalFor: 2.0)
        XCTAssertEqual(none.placementStatus(now: 100), .noFloor)
    }

    func testMappingStatusAloneNeverDecides() {
        // a "limited" map with long normal tracking and a steady floor is fine ...
        let limitedMap = gate(normalFor: 3, floor: [0, 0.001, 0, 0.001], mapping: "limited")
        XCTAssertEqual(limitedMap.placementStatus(now: 100), .stable)
        // ... and a "mapped" map does not rescue limited tracking
        var g = ObjectTrackingGate()
        g.ingest(timestamp: 1, tracking: "limited_insufficient_features", mapping: "mapped")
        XCTAssertEqual(g.placementStatus(now: 5), .insufficientFeatures)
        XCTAssertEqual(g.captureStatus(now: 5), .insufficientFeatures)
    }

    func testPhotosWaitAfterALimitedStretchAndARelocalisation() {
        var g = ObjectTrackingGate()
        g.ingest(timestamp: 10.0, tracking: "limited_relocalizing", mapping: "limited")
        XCTAssertEqual(g.captureStatus(now: 10.1), .relocalizing)
        g.ingest(timestamp: 11.0, tracking: "normal", mapping: "extending")
        XCTAssertEqual(g.lastRelocalizedAt, 11.0, "the world may have shifted at this moment")
        if case .settling = g.captureStatus(now: 11.4) {} else { XCTFail("0.4 s after recovery is still settling") }
        XCTAssertEqual(g.captureStatus(now: 12.2), .stable)
        // a second limited stretch resets the clock
        g.ingest(timestamp: 13.0, tracking: "limited_excessive_motion", mapping: "extending")
        XCTAssertEqual(g.captureStatus(now: 13.1), .excessiveMotion)
    }

    func testRecoveryTextsAreSentencesAndTheTextureHelperIsOnlyAHelper() {
        XCTAssertNil(ObjectTrackingGate.recoveryText(.stable))
        let all: [ObjectTrackingGate.Status] = [.settling(secondsLeft: 1), .initializing, .excessiveMotion, .insufficientFeatures, .relocalizing, .notAvailable, .floorUnsteady, .noFloor]
        for s in all {
            let t = ObjectTrackingGate.recoveryText(s)
            XCTAssertNotNil(t)
            XCTAssertFalse(t!.line.isEmpty)
            XCTAssertFalse(t!.line.contains("바닥을 바꿔"), "the floor never has to be changed")
        }
        let helper = ObjectTrackingGate.recoveryText(.insufficientFeatures)?.helper
        XCTAssertNotNil(helper)
        XCTAssertTrue(helper!.contains("꼭 필요한 것은 아니에요"))
        XCTAssertNil(ObjectTrackingGate.recoveryText(.excessiveMotion)?.helper)
    }

    // MARK: anchor following

    func testAnchorMovesTheGuideOnlyWhenNotDragging() {
        let base = SIMD3<Float>(1, 0, -2)
        XCTAssertNil(ObjectAnchorFollow.nextBase(current: base, anchor: base, isDragging: false), "no movement, no change")
        XCTAssertNil(ObjectAnchorFollow.nextBase(current: base, anchor: base + SIMD3(0.0002, 0, 0), isDragging: false), "below 0.5 mm")
        let moved = base + SIMD3<Float>(0.03, 0, -0.01)
        XCTAssertEqual(ObjectAnchorFollow.nextBase(current: base, anchor: moved, isDragging: false), moved)
        XCTAssertNil(ObjectAnchorFollow.nextBase(current: base, anchor: moved, isDragging: true), "the user's drag wins while it lasts")
    }

    func testV1012LargeAnchorFollowIsRejectedNotApplied() {
        // GONGGI_OBJECT_V1_012: anchor_follow moveM=1.2247 after limited_initializing — must not become a normal follow.
        let base = SIMD3<Float>(-0.9056721, -1.2729919, -1.2789011)
        let jumped = SIMD3<Float>(-0.1596429, -2.0585189, -0.7077780)
        let move = simd_distance(base, jumped)
        XCTAssertEqual(move, ObjectCaptureConsistency.v1012AnchorFollowMoveM, accuracy: 1e-3)

        let decision = ObjectAnchorFollow.decide(
            current: base, anchor: jumped, isDragging: false, trackingAllowsFollow: true
        )
        guard case .rejectLargeJump(let rejected) = decision else {
            return XCTFail("V1_012 jump must be rejectLargeJump, got \(decision)")
        }
        XCTAssertEqual(rejected, move, accuracy: 1e-4)
        XCTAssertNil(ObjectAnchorFollow.nextBase(current: base, anchor: jumped, isDragging: false),
                     "compatibility nextBase must not apply a metre-scale jump")
    }

    func testSmallStableAnchorUpdateStillApplies() {
        let base = SIMD3<Float>(0, 0, -1)
        let small = base + SIMD3<Float>(0.02, 0, -0.01)
        let d = ObjectAnchorFollow.decide(current: base, anchor: small, isDragging: false, trackingAllowsFollow: true)
        XCTAssertEqual(d, .apply(small))
    }

    func testUnstableTrackingHoldsAnchorFollow() {
        let base = SIMD3<Float>(0, 0, -1)
        let small = base + SIMD3<Float>(0.02, 0, 0)
        let d = ObjectAnchorFollow.decide(current: base, anchor: small, isDragging: false, trackingAllowsFollow: false)
        XCTAssertEqual(d, .holdUnstable)
    }

    func testCameraJumpDetectsV1012StyleRebase() {
        let before = SIMD3<Float>(-1.184, -0.783, -1.896)
        let after = SIMD3<Float>(0.208, -1.566, -0.226)
        let jump = ObjectAnchorFollow.cameraJumpM(previous: before, current: after)
        XCTAssertNotNil(jump)
        XCTAssertGreaterThan(jump!, 2.0)
        XCTAssertNil(ObjectAnchorFollow.cameraJumpM(previous: before, current: before + SIMD3(0.05, 0, 0)))
    }

    func testPhotosHeldWhenRangeConsistencyRequiresUserAction() {
        XCTAssertTrue(ObjectCaptureConsistency.shouldHoldPhotos(trackingStable: true, rangeConsistencyHold: true))
        XCTAssertTrue(ObjectCaptureConsistency.shouldHoldPhotos(trackingStable: false, rangeConsistencyHold: false))
        XCTAssertFalse(ObjectCaptureConsistency.shouldHoldPhotos(trackingStable: true, rangeConsistencyHold: false))
        // 253 photos before jump → user must reconfirm; do not auto-resume.
        XCTAssertTrue(ObjectCaptureConsistency.requiresUserRangeAction(savedPhotoCount: 253, discontinuityDetected: true))
        XCTAssertFalse(ObjectCaptureConsistency.requiresUserRangeAction(savedPhotoCount: 0, discontinuityDetected: true))
    }

    func testCentreRefinementStaysOff() {
        XCTAssertFalse(ObjectCaptureConfig.centreRefinementEnabled)
    }

    // MARK: return check

    private func pose(_ x: Float, _ z: Float, yawDeg: Float, pitchDeg: Float = -30) -> ObjectReturnCheck.Pose {
        let y = yawDeg * .pi / 180, p = pitchDeg * .pi / 180
        let f = SIMD3<Float>(sin(y) * cos(p), sin(p), -cos(y) * cos(p))
        return ObjectReturnCheck.Pose(position: SIMD3(x, 1.3, z), forward: simd_normalize(f))
    }

    func testNearStartNeedsPositionHeadingAndPitch() {
        let start = pose(0, 1.3, yawDeg: 0)
        XCTAssertTrue(ObjectReturnCheck.isNearStart(ObjectReturnCheck.delta(from: start, to: pose(0.1, 1.25, yawDeg: 6))))
        XCTAssertFalse(ObjectReturnCheck.isNearStart(ObjectReturnCheck.delta(from: start, to: pose(0.6, 1.3, yawDeg: 3))), "too far")
        XCTAssertFalse(ObjectReturnCheck.isNearStart(ObjectReturnCheck.delta(from: start, to: pose(0.05, 1.3, yawDeg: 40))), "looking elsewhere")
        XCTAssertFalse(ObjectReturnCheck.isNearStart(ObjectReturnCheck.delta(from: start, to: pose(0.05, 1.3, yawDeg: 3, pitchDeg: -55))), "other pitch")
        let d = ObjectReturnCheck.delta(from: start, to: pose(0.3, 1.3, yawDeg: -10))
        XCTAssertEqual(d.positionM, 0.3, accuracy: 1e-5)
        XCTAssertEqual(d.yawDeg, 10, accuracy: 0.01)
    }

    func testRoiStaysInsideTheImage() throws {
        let r1 = try XCTUnwrap(ObjectReturnCheck.roiRect(centre: SIMD2(960, 720), imageWidth: 1920, imageHeight: 1440))
        XCTAssertEqual(r1.width, CGFloat(ObjectReturnCheck.roiSidePx))
        XCTAssertEqual(r1.midX, 960, accuracy: 1)
        let r2 = try XCTUnwrap(ObjectReturnCheck.roiRect(centre: SIMD2(5, 1435), imageWidth: 1920, imageHeight: 1440))
        XCTAssertGreaterThanOrEqual(r2.minX, 0)
        XCTAssertLessThanOrEqual(r2.maxY, 1440)
        XCTAssertNil(ObjectReturnCheck.roiRect(centre: SIMD2(10, 10), imageWidth: 200, imageHeight: 200))
    }

    /// A textured picture, and the same picture moved by (dx, dy): the registration reports the move (sign aside) within ~2 px.
    private func texture(dx: Int, dy: Int, side: Int = 400) -> CGImage {
        var pixels = [UInt8](repeating: 0, count: side * side)
        func value(_ x: Int, _ y: Int) -> UInt8 {
            // a smooth, non-repeating pattern (sum of a few sines), same in both pictures
            let fx = Double(x), fy = Double(y)
            let v = 128 + 40 * sin(fx / 9.0 + fy / 17.0) + 35 * sin(fx / 23.0 - fy / 7.0) + 30 * sin((fx * fy) / 4000.0) + 25 * sin(fx / 5.0)
            return UInt8(max(0, min(255, v)))
        }
        for y in 0..<side {
            for x in 0..<side { pixels[y * side + x] = value(x - dx, y - dy) }
        }
        let provider = CGDataProvider(data: Data(pixels) as CFData)!
        return CGImage(width: side, height: side, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: side,
                       space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
    }

    func testRegistrationFindsASmallShiftAndNoShift() throws {
        let a = texture(dx: 0, dy: 0)
        let same = try XCTUnwrap(ObjectReturnCheck.register(start: a, now: texture(dx: 0, dy: 0)))
        XCTAssertLessThan(same.magnitudePx, 1.0)
        let moved = try XCTUnwrap(ObjectReturnCheck.register(start: a, now: texture(dx: 7, dy: 3)))
        XCTAssertEqual(moved.magnitudePx, (7.0 * 7.0 + 3.0 * 3.0).squareRoot(), accuracy: 2.0)
    }

    // MARK: trace time base

    func testTraceCarriesOneTimeBaseAndTheUserActions() throws {
        var t = ObjectPlacementTrace(appBuild: "2.0 (90)", device: "iPhone")
        t.startedAtEpochMs = 1_790_900_000_000
        t.add(0.0, "tap1", ["sx": 1])
        t.add(0.5, "sample", ["cx": 0, "cqw": 1, "ax": 0, "bx": 0, "guideYaw": 0], ["tracking": "normal"])
        t.add(0.6, "drag_begin"); t.add(1.1, "drag_end"); t.add(1.2, "size"); t.add(2.0, "return_check", ["magPx": 3.2, "anchorShiftM": 0.001])
        let back = try JSONDecoder().decode(ObjectPlacementTrace.self, from: JSONEncoder().encode(t))
        XCTAssertEqual(back.schema, 2)
        XCTAssertEqual(back.startedAtEpochMs, 1_790_900_000_000)
        XCTAssertEqual(back.events.map(\.kind), ["tap1", "sample", "drag_begin", "drag_end", "size", "return_check"])
        XCTAssertEqual(back.events.map(\.tSec), back.events.map(\.tSec).sorted(), "one monotonic clock")
    }
}
