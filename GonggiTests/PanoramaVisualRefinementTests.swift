import XCTest
import simd
@testable import Gonggi

final class PanoramaVisualRefinementTests: XCTestCase {
    func testAngularKeyframeSelectionEnforcesSpacing() {
        let yaws: [Float] = [0, 0.05, 0.5, 1.0, 1.05, 2.0]
        let decision = PanoramaKeyframeAngularGate.selectForFinalStitch(
            yawRad: yaws,
            pitchRad: [Float](repeating: 0, count: yaws.count),
            sharpness: [Float](repeating: 0.5, count: yaws.count),
            exposure: [Float](repeating: 0.5, count: yaws.count),
            dynamicRatio: [Float](repeating: 0.1, count: yaws.count),
            translationM: [Float](repeating: 0.05, count: yaws.count),
            minYawSpacingDeg: 20
        )
        XCTAssertTrue(decision.acceptedIndices.contains(0))
        XCTAssertFalse(decision.acceptedIndices.contains(1))
        XCTAssertGreaterThanOrEqual(decision.acceptedIndices.count, 3)
        XCTAssertGreaterThan(decision.averageSpacingDeg, 15)
    }

    func testAngularGateRejectsPoorQuality() {
        let decision = PanoramaKeyframeAngularGate.selectForFinalStitch(
            yawRad: [0, 0.6],
            pitchRad: [0, 0],
            sharpness: [0.01, 0.5],
            exposure: [0.5, 0.5],
            dynamicRatio: [0.1, 0.1],
            translationM: [0, 0],
            minYawSpacingDeg: 10
        )
        XCTAssertFalse(decision.acceptedIndices.contains(0))
        XCTAssertTrue(decision.acceptedIndices.contains(1))
    }

    func testOverlapEstimationRightTurnUsesRightEdgeOfLeftFrame() {
        let K = CameraIntrinsics(fx: 500, fy: 500, cx: 320, cy: 240, width: 640, height: 480)
        var right = matrix_identity_float4x4
        let t: Float = 0.35
        right.columns.0 = SIMD4(cos(t), 0, -sin(t), 0)
        right.columns.2 = SIMD4(sin(t), 0, cos(t), 0)
        let region = PanoramaOverlapEstimator.estimate(
            leftIntrinsics: K,
            rightIntrinsics: K,
            leftTransform: matrix_identity_float4x4,
            rightTransform: right,
            originTransform: matrix_identity_float4x4
        )
        XCTAssertNotNil(region)
        XCTAssertGreaterThan(region!.overlapFraction, 0.15)
        // Overlap boxes must be non-empty horizontal strips on both frames.
        XCTAssertGreaterThan(region!.leftX1 - region!.leftX0, 20)
        XCTAssertGreaterThan(region!.rightX1 - region!.rightX0, 20)
        // One side should be edge-biased (left image right edge OR left edge).
        let leftBiasedRight = region!.leftX0 > K.width / 3
        let leftBiasedLeft = region!.leftX1 < K.width * 2 / 3
        XCTAssertTrue(leftBiasedRight || leftBiasedLeft)
    }

    func testFeatureMatcherFindsShiftedCorners() {
        let w = 64
        let h = 48
        var left = [UInt8](repeating: 40, count: w * h)
        var right = [UInt8](repeating: 40, count: w * h)
        // Bright square
        for y in 16..<28 {
            for x in 20..<32 {
                left[y * w + x] = 220
                right[y * w + (x + 3)] = 220
            }
        }
        let corners = PanoramaFeatureMatcher.detectCorners(gray: left, width: w, height: h, maxCorners: 40, cellSize: 8)
        XCTAssertFalse(corners.isEmpty)
        let matches = PanoramaFeatureMatcher.matchCorners(
            leftGray: left, leftW: w, leftH: h,
            rightGray: right, rightW: w, rightH: h,
            leftCorners: corners,
            searchRadius: 8
        )
        XCTAssertFalse(matches.isEmpty)
        let meanDx = matches.map { $0.right.x - $0.left.x }.reduce(0, +) / Float(matches.count)
        XCTAssertEqual(meanDx, 3, accuracy: 2.5)
    }

    func testRANSACRejectsOutliers() {
        var matches: [PanoramaFeatureMatcher.Match] = []
        for i in 0..<20 {
            let x = Float(i * 3)
            matches.append(.init(
                left: .init(x: x, y: 10),
                right: .init(x: x + 4, y: 10),
                score: 0.9
            ))
        }
        // Outliers
        matches.append(.init(left: .init(x: 5, y: 5), right: .init(x: 50, y: 40), score: 0.9))
        matches.append(.init(left: .init(x: 8, y: 8), right: .init(x: 2, y: 60), score: 0.9))
        let result = PanoramaRANSAC.fitTranslation(matches: matches, iterations: 80, thresholdPx: 2)
        XCTAssertNotNil(result)
        XCTAssertEqual(result!.model.dx, 4, accuracy: 0.8)
        XCTAssertGreaterThan(result!.inlierRatio, 0.7)
    }

    func testRefinementAcceptRejectThresholds() {
        // Too few matches → reject path via refineSequence with tiny images (no features).
        let tiny = PanoramaStitcher.InputKeyframe(
            index: 0,
            rgba: [UInt8](repeating: 128, count: 16 * 16 * 4),
            width: 16,
            height: 16,
            cameraTransform: matrix_identity_float4x4,
            intrinsics: CameraIntrinsics(fx: 10, fy: 10, cx: 8, cy: 8, width: 16, height: 16),
            dynamicRatio: 0,
            fileName: "a"
        )
        var cam = matrix_identity_float4x4
        let t: Float = 0.3
        cam.columns.0 = SIMD4(cos(t), 0, -sin(t), 0)
        cam.columns.2 = SIMD4(sin(t), 0, cos(t), 0)
        let tiny2 = PanoramaStitcher.InputKeyframe(
            index: 1,
            rgba: [UInt8](repeating: 128, count: 16 * 16 * 4),
            width: 16,
            height: 16,
            cameraTransform: cam,
            intrinsics: CameraIntrinsics(fx: 10, fy: 10, cx: 8, cy: 8, width: 16, height: 16),
            dynamicRatio: 0,
            fileName: "b"
        )
        let seq = PanoramaAlignmentRefiner.refineSequence(
            keyframes: [tiny, tiny2],
            fileNames: ["a", "b"],
            originTransform: matrix_identity_float4x4
        )
        XCTAssertEqual(seq.attempts, 1)
        XCTAssertEqual(seq.successes, 0)
        XCTAssertFalse(seq.placements[1].accepted)
        XCTAssertEqual(seq.placements[1].projectionTransform, cam)
    }

    func testARKitFallbackKeepsOriginalTransform() {
        let cam = matrix_identity_float4x4
        let p = PanoramaAlignmentRefiner.applyYawPitchDelta(to: cam, deltaYaw: 0, deltaPitch: 0)
        XCTAssertEqual(p.columns.2.x, cam.columns.2.x, accuracy: 0.01)
        let rotated = PanoramaAlignmentRefiner.applyYawPitchDelta(to: cam, deltaYaw: 0.1, deltaPitch: 0)
        XCTAssertNotEqual(rotated.columns.2.x, cam.columns.2.x, accuracy: 0.001)
    }

    func testSeamMaskContinuityPreferStableRuns() {
        let w = 32
        let h = 8
        var preferred = [Int16](repeating: 0, count: w * h)
        for y in 0..<h {
            for x in 0..<w {
                preferred[y * w + x] = x < 20 ? 0 : 1
            }
        }
        let continuity = PanoramaSeamBlender.seamLabelRunContinuity(
            preferred: preferred, width: w, height: h
        )
        XCTAssertGreaterThan(continuity, 0.9)
    }

    func testHighParallaxDetectionHeuristic() {
        var matches: [PanoramaFeatureMatcher.Match] = []
        for i in 0..<8 {
            matches.append(.init(
                left: .init(x: Float(i * 4), y: 5),
                right: .init(x: Float(i * 4) + 2, y: 5),
                score: 0.9
            ))
        }
        for i in 0..<8 {
            matches.append(.init(
                left: .init(x: Float(i * 4), y: 40),
                right: .init(x: Float(i * 4) + 10, y: 40),
                score: 0.9
            ))
        }
        let high = PanoramaRANSAC.detectHighParallax(
            matches: matches,
            inlierIndices: Array(0..<matches.count),
            disagreementPx: 4
        )
        XCTAssertTrue(high)
    }

    func testKeyframeYawIntervalConfigInRange() {
        XCTAssertGreaterThanOrEqual(Quick360Config.keyframeYawIntervalDeg, 20)
        XCTAssertLessThanOrEqual(Quick360Config.keyframeYawIntervalDeg, 30)
        let horizontal = Quick360Config.yawStepCount
        XCTAssertGreaterThanOrEqual(horizontal, 8)
        XCTAssertLessThanOrEqual(horizontal, 16)
    }
}
