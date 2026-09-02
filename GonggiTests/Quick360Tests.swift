import simd
import XCTest
@testable import Gonggi

final class Quick360SphericalMathTests: XCTestCase {
    func testEquirectangularUVCenter() {
        let uv = SphericalMath.equirectangularUV(yawRad: 0, pitchRad: 0)
        XCTAssertEqual(uv.x, 0.5, accuracy: 0.01)
        XCTAssertEqual(uv.y, 0.5, accuracy: 0.01)
    }

    func testEquirectangularUVYaw360() {
        let uv = SphericalMath.equirectangularUV(yawRad: .pi, pitchRad: 0)
        XCTAssertEqual(uv.x, 1.0, accuracy: 0.01)
    }

    func testEquirectangularPixelRoundTrip() {
        let px = SphericalMath.equirectangularPixel(yawRad: 0, pitchRad: 0, width: 2048, height: 1024)
        XCTAssertEqual(px.x, 1024, accuracy: 2)
        XCTAssertEqual(px.y, 512, accuracy: 2)
    }

    func testAngularDistanceZero() {
        let d = SphericalMath.angularDistanceDeg(yawA: 0, pitchA: 0, yawB: 0, pitchB: 0)
        XCTAssertEqual(d, 0, accuracy: 0.01)
    }

    func testValidEquirectangularAspect() {
        XCTAssertTrue(SphericalMath.isValidEquirectangularAspect(width: 2048, height: 1024))
        XCTAssertFalse(SphericalMath.isValidEquirectangularAspect(width: 1024, height: 1024))
    }

    func testRelativeYawPitch() {
        var origin = matrix_identity_float4x4
        var rotated = matrix_identity_float4x4
        rotated.columns.0 = SIMD4<Float>(0, 0, 1, 0)
        rotated.columns.2 = SIMD4<Float>(-1, 0, 0, 0)
        let (yaw, _) = SphericalMath.relativeYawPitchRad(cameraTransform: rotated, originTransform: origin)
        XCTAssertGreaterThan(abs(yaw), 0.5)
    }
}

final class Quick360TargetLayoutTests: XCTestCase {
    func testTargetCount() {
        let targets = Quick360SphericalTargetLayout.makeTargets()
        XCTAssertEqual(targets.count, Quick360Config.targetCount)
        XCTAssertEqual(targets.count, 36)
    }

    func testProgressIncreasesOnSelection() {
        var targets = Quick360SphericalTargetLayout.makeTargets()
        XCTAssertEqual(Quick360SphericalTargetLayout.progressPercent(in: targets), 0)
        targets = Quick360SphericalTargetLayout.markSelected(targets: targets, targetId: 0)
        XCTAssertEqual(Quick360SphericalTargetLayout.progressPercent(in: targets), 3)
    }

    func testWithinTolerance() {
        let target = Quick360SphericalTarget(id: 0, yawDeg: 0, pitchDeg: 0, state: .pending)
        XCTAssertTrue(Quick360SphericalTargetLayout.isWithinTolerance(
            cameraYawRad: 0, cameraPitchRad: 0, target: target
        ))
    }

    func testRotationHintRight() {
        let target = Quick360SphericalTarget(id: 1, yawDeg: 90, pitchDeg: 0, state: .pending)
        let hint = Quick360SphericalTargetLayout.rotationHint(cameraYawRad: 0, target: target)
        XCTAssertEqual(hint, .rotateRight)
    }
}

final class Quick360TranslationGuardTests: XCTestCase {
    func testSafeLevel() {
        XCTAssertEqual(Quick360TranslationGuard.level(for: 0.02), .safe)
    }

    func testWarningLevel() {
        XCTAssertEqual(Quick360TranslationGuard.level(for: 0.1), .warning)
    }

    func testExcessiveLevel() {
        XCTAssertEqual(Quick360TranslationGuard.level(for: 0.2), .excessive)
    }

    func testHoldKeyframeOnExcessive() {
        var state = Quick360TranslationGuard.State.initial
        var moved = matrix_identity_float4x4
        moved.columns.3 = SIMD4<Float>(0.2, 0, 0, 1)
        state = Quick360TranslationGuard.update(
            state: state,
            cameraTransform: moved,
            originTransform: matrix_identity_float4x4
        )
        XCTAssertTrue(state.shouldHoldKeyframe)
    }
}

final class Quick360CandidateBufferTests: XCTestCase {
    func makeCandidate(ts: Double = 1) -> Quick360FrameCandidate {
        Quick360FrameCandidate(
            timestamp: ts, yawRad: 0, pitchRad: 0, translationM: 0.02,
            sharpness: 0.8, exposure: 0.9, dynamicRatio: 0.1,
            intrinsics: CameraIntrinsics(fx: 1000, fy: 1000, cx: 640, cy: 360, width: 1280, height: 720),
            transform: CaptureKeyframeRecord.encodeTransform(matrix_identity_float4x4),
            imageJPEG: nil, fileName: nil
        )
    }

    func testBufferEvictionOnMax() {
        var slots: [Int: Quick360CandidateBuffer.Slot] = [:]
        for i in 0..<15 {
            slots = Quick360CandidateBuffer.ingest(
                slots: slots, targetId: 0, candidate: makeCandidate(ts: Double(i)), now: Double(i) * 0.1
            )
        }
        XCTAssertEqual(slots[0]?.candidates.count, Quick360Config.maxCandidatesPerTarget)
    }

    func testShouldEvaluateAfterWindow() {
        let slot = Quick360CandidateBuffer.Slot(
            targetId: 0,
            candidates: [makeCandidate(), makeCandidate(), makeCandidate()],
            enteredAt: 0,
            lastUpdatedAt: 0.5
        )
        XCTAssertTrue(Quick360CandidateBuffer.shouldEvaluate(slot: slot, now: 0.7))
    }
}

final class Quick360KeyframeScorerTests: XCTestCase {
    func testHigherSharpnessWins() {
        let target = Quick360SphericalTarget(id: 0, yawDeg: 0, pitchDeg: 0, state: .accumulating)
        let sharp = Quick360FrameCandidate(
            timestamp: 1, yawRad: 0, pitchRad: 0, translationM: 0.02,
            sharpness: 0.95, exposure: 0.9, dynamicRatio: 0.05,
            intrinsics: CameraIntrinsics(fx: 1, fy: 1, cx: 0, cy: 0, width: 100, height: 100),
            transform: CaptureKeyframeRecord.encodeTransform(matrix_identity_float4x4),
            imageJPEG: nil, fileName: nil
        )
        let blurry = Quick360FrameCandidate(
            timestamp: 2, yawRad: 0, pitchRad: 0, translationM: 0.02,
            sharpness: 0.2, exposure: 0.9, dynamicRatio: 0.05,
            intrinsics: CameraIntrinsics(fx: 1, fy: 1, cx: 0, cy: 0, width: 100, height: 100),
            transform: CaptureKeyframeRecord.encodeTransform(matrix_identity_float4x4),
            imageJPEG: nil, fileName: nil
        )
        let best = Quick360KeyframeScorer.selectBest(candidates: [blurry, sharp], target: target)
        XCTAssertEqual(best?.candidate.sharpness, 0.95)
    }
}

final class Quick360ImageAnalysisTests: XCTestCase {
    func testSharpnessUniformLow() {
        let gray = [UInt8](repeating: 128, count: 64 * 36)
        let score = Quick360ImageAnalysis.sharpnessScore(grayscale: gray, width: 64, height: 36)
        XCTAssertLessThan(score, 0.2)
    }

    func testSharpnessCheckerboardHigh() {
        var gray = [UInt8]()
        for y in 0..<36 {
            for x in 0..<64 {
                gray.append((x + y) % 2 == 0 ? 255 : 0)
            }
        }
        let score = Quick360ImageAnalysis.sharpnessScore(grayscale: gray, width: 64, height: 36)
        XCTAssertGreaterThan(score, 0.3)
    }

    func testExposureClippingPenalty() {
        let clipped = [UInt8](repeating: 255, count: 100)
        let score = Quick360ImageAnalysis.exposureScore(grayscale: clipped)
        XCTAssertLessThan(score, 0.5)
    }

    func testDifferenceRatioIdentical() {
        let a = [UInt8](repeating: 100, count: 50)
        XCTAssertEqual(Quick360ImageAnalysis.differenceRatio(a: a, b: a), 0, accuracy: 0.01)
    }
}

final class Quick360CoverageMaskTests: XCTestCase {
    func testCoveragePercent() {
        let flags = [true, true, false, false]
        let (_, cov, uncov) = PanoramaCoverageMask.generate(coverageFlags: flags, width: 2, height: 2)
        XCTAssertEqual(cov, 50, accuracy: 0.1)
        XCTAssertEqual(uncov, 50, accuracy: 0.1)
    }
}

final class Quick360StitcherTests: XCTestCase {
    func testMockPanoramaOutputSize() {
        let out = PanoramaStitcher.mockPanorama()
        XCTAssertEqual(out.width, 2048)
        XCTAssertEqual(out.height, 1024)
        XCTAssertTrue(SphericalMath.isValidEquirectangularAspect(width: out.width, height: out.height))
    }

    func testSeamFeatherBlend() {
        let colors = [SIMD3<Float>(1, 0, 0), SIMD3<Float>(0, 1, 0)]
        let weights: [Float] = [1, 1]
        let blended = PanoramaSeamBlender.featherBlend(
            base: colors, accumColors: colors, accumWeights: weights, width: 2, height: 1
        )
        XCTAssertEqual(blended.count, 2)
    }
}

final class Quick360SessionStoreTests: XCTestCase {
    func testPanoramaPaths() throws {
        let sessionId = "test-quick360-\(UUID().uuidString)"
        let dir = try CaptureSessionStore.createPanoramaDirectory(sessionId: sessionId)
        XCTAssertTrue(dir.lastPathComponent == "panorama")
        let kf = try CaptureSessionStore.quick360KeyframeURL(sessionId: sessionId, fileName: "keyframe_0001.jpg")
        XCTAssertTrue(kf.path.contains("keyframes"))
        CaptureSessionStore.deleteSession(sessionId: sessionId)
    }
}

final class Quick360DynamicRegionTests: XCTestCase {
    func testDynamicRatioOnChange() {
        var state = Quick360DynamicRegionDetector.initial()
        let a = [UInt8](repeating: 50, count: 100)
        let b = [UInt8](repeating: 200, count: 100)
        let (r1, s1) = Quick360DynamicRegionDetector.dynamicRatio(state: state, grayscale: a, width: 10, height: 10)
        XCTAssertEqual(r1, 0, accuracy: 0.01)
        let (r2, _) = Quick360DynamicRegionDetector.dynamicRatio(state: s1, grayscale: b, width: 10, height: 10)
        XCTAssertGreaterThan(r2, 0.3)
    }
}

final class Quick360AlignmentRefinerTests: XCTestCase {
    func testTranslationalOffsetIdentical() {
        let gray = [UInt8](repeating: 128, count: 32 * 18)
        let result = PanoramaAlignmentRefiner.estimateTranslationalOffset(
            reference: gray, target: gray, width: 32, height: 18
        )
        XCTAssertFalse(result.applied)
    }
}
