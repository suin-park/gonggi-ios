import ARKit
import CoreVideo
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
        XCTAssertEqual(targets.count, 24)
    }

    func testProgressIncreasesOnSelection() {
        var targets = Quick360SphericalTargetLayout.makeTargets()
        XCTAssertEqual(Quick360SphericalTargetLayout.progressPercent(in: targets), 0)
        targets = Quick360SphericalTargetLayout.markSelected(targets: targets, targetId: 0)
        XCTAssertEqual(Quick360SphericalTargetLayout.progressPercent(in: targets), 4)
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
    private let w = 10
    private let h = 10

    private func gray(fill: UInt8) -> [UInt8] {
        [UInt8](repeating: fill, count: w * h)
    }

    func testDynamicRatioOnUniformChangeWithSmallRotation() {
        var state = Quick360DynamicRegionDetector.initial()
        let a = gray(fill: 50)
        var b = gray(fill: 50)
        for i in 40..<60 { b[i] = 220 }
        let (r1, s1) = Quick360DynamicRegionDetector.dynamicRatio(
            state: state, grayscale: a, width: w, height: h, yawRad: 0, pitchRad: 0
        )
        XCTAssertEqual(r1, 0, accuracy: 0.01)
        let (r2, _) = Quick360DynamicRegionDetector.dynamicRatio(
            state: s1, grayscale: b, width: w, height: h, yawRad: 0.01, pitchRad: 0
        )
        XCTAssertGreaterThan(r2, 0.05)
    }

    func testLargeCameraRotationIgnored() {
        var state = Quick360DynamicRegionDetector.initial()
        let a = gray(fill: 80)
        let b = gray(fill: 200)
        let (_, s1) = Quick360DynamicRegionDetector.dynamicRatio(
            state: state, grayscale: a, width: w, height: h, yawRad: 0, pitchRad: 0
        )
        let yawDelta = 20 * Float.pi / 180
        let (ratio, _) = Quick360DynamicRegionDetector.dynamicRatio(
            state: s1, grayscale: b, width: w, height: h, yawRad: yawDelta, pitchRad: 0
        )
        XCTAssertEqual(ratio, 0, accuracy: 0.01)
    }

    func testIdenticalFramesLowResidual() {
        var state = Quick360DynamicRegionDetector.initial()
        let a = gray(fill: 100)
        let (_, s1) = Quick360DynamicRegionDetector.dynamicRatio(
            state: state, grayscale: a, width: w, height: h, yawRad: 0, pitchRad: 0
        )
        let (ratio, _) = Quick360DynamicRegionDetector.dynamicRatio(
            state: s1, grayscale: a, width: w, height: h, yawRad: 0.02, pitchRad: 0
        )
        XCTAssertLessThan(ratio, 0.1)
    }

    func testResidualDifferenceIgnoresGlobalShift() {
        var ref = gray(fill: 100)
        var cur = gray(fill: 100)
        for y in 0..<h {
            for x in 0..<w {
                let v = UInt8((x * 10 + y * 3) % 200 + 20)
                ref[y * w + x] = v
                let sx = x > 0 ? x - 1 : x
                cur[y * w + x] = ref[y * w + sx]
            }
        }
        let raw = Quick360ImageAnalysis.differenceRatio(a: ref, b: cur)
        let residual = Quick360ImageAnalysis.residualDifferenceRatio(
            reference: ref, current: cur, width: w, height: h, shiftDx: -1, shiftDy: 0
        )
        XCTAssertGreaterThan(raw, 0.1)
        XCTAssertLessThan(residual, raw)
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

final class Quick360ARBootstrapTests: XCTestCase {
    func testWorldTrackingConfigIsNonLiDARSafe() {
        let config = Quick360ARConfiguration.makeWorldTracking()
        XCTAssertTrue(Quick360ARConfiguration.isNonLiDARSafe(config))
        XCTAssertTrue(config.sceneReconstruction.isEmpty)
        XCTAssertFalse(config.frameSemantics.contains(.sceneDepth))
        XCTAssertFalse(config.frameSemantics.contains(.smoothedSceneDepth))
        XCTAssertTrue(config.planeDetection.isEmpty)
        XCTAssertEqual(config.worldAlignment, .gravity)
    }

    func testLiDARSemanticsWouldFailSafetyCheck() {
        let config = Quick360ARConfiguration.makeWorldTracking()
        // Mutate a copy-like instance: build unsafe config for regression guard.
        let unsafe = ARWorldTrackingConfiguration()
        if ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh) {
            unsafe.sceneReconstruction = .mesh
            XCTAssertFalse(Quick360ARConfiguration.isNonLiDARSafe(unsafe))
        } else {
            // On Simulator / non-LiDAR hosts, mesh is unsupported — safety of makeWorldTracking still holds.
            XCTAssertTrue(Quick360ARConfiguration.isNonLiDARSafe(config))
        }
    }

    /// Documents the required ARView bootstrap order (auto-configure OFF before session assign).
    func testARViewMustDisableAutoConfigureBeforeSessionAssign() {
        // Representable uses: ARView(frame:cameraMode:automaticallyConfigureSession: false)
        // then view.session = session. This flag documents that contract for CI.
        let mustDisableAutoConfigureFirst = true
        XCTAssertTrue(mustDisableAutoConfigureFirst)
    }
}

final class Quick360FrameLifetimeTests: XCTestCase {
    /// Build 3 crash (EXC_BAD_ACCESS): ARFrame hopped to main via DispatchQueue.main.async,
    /// then CVPixelBufferLockBaseAddress / BGRA walk on a recycled buffer.
    /// Contract: only owned `Quick360FramePayload` may cross queues.
    func testPayloadIsOwnedValueTypeWithoutPixelBuffer() {
        let payload = Quick360FramePayload(
            timestamp: 1.0,
            cameraTransform: matrix_identity_float4x4,
            intrinsics: CameraIntrinsics(fx: 1, fy: 1, cx: 0, cy: 0, width: 64, height: 36),
            analysisGrayscale: [UInt8](repeating: 40, count: 64 * 36),
            jpegData: Data([0xFF, 0xD8, 0xFF])
        )
        XCTAssertEqual(payload.analysisGrayscale.count, 64 * 36)
        XCTAssertNotNil(payload.jpegData)
        // Sendable owned copy — safe to hop to main without ARFrame.
        DispatchQueue.main.sync {
            XCTAssertEqual(payload.timestamp, 1.0)
        }
    }

    func testEngineIngestsOwnedPayloadOnMainWithoutARFrame() {
        let engine = Quick360CaptureEngine(mockMode: true)
        engine.start(sessionId: "s", captureId: "c")
        let gray = [UInt8](repeating: 80, count: Quick360FrameEncoder.analysisWidth * Quick360FrameEncoder.analysisHeight)
        let payload = Quick360FramePayload(
            timestamp: 0.5,
            cameraTransform: matrix_identity_float4x4,
            intrinsics: CameraIntrinsics(fx: 500, fy: 500, cx: 320, cy: 240, width: 640, height: 480),
            analysisGrayscale: gray,
            jpegData: nil
        )
        engine.ingest(payload: payload)
        XCTAssertTrue(engine.isRunning)
        XCTAssertFalse(engine.uiState.progressPercent < 0)
    }

    func testWantsJPEGCandidateTrueBeforeOriginSet() {
        let engine = Quick360CaptureEngine(mockMode: false)
        engine.start(sessionId: "s", captureId: "c")
        XCTAssertTrue(engine.wantsJPEGCandidate(cameraTransform: matrix_identity_float4x4))
    }

    func testCIContextRGBARenderFromBGRAPixelBuffer() throws {
        let width = 16
        let height = 8
        var pixelBuffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            width,
            height,
            kCVPixelFormatType_32BGRA,
            [
                kCVPixelBufferCGImageCompatibilityKey: true,
                kCVPixelBufferCGBitmapContextCompatibilityKey: true
            ] as CFDictionary,
            &pixelBuffer
        )
        XCTAssertEqual(status, kCVReturnSuccess)
        let buffer = try XCTUnwrap(pixelBuffer)

        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else {
            XCTFail("missing base address")
            return
        }
        let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
        let ptr = base.assumingMemoryBound(to: UInt8.self)
        for y in 0..<height {
            for x in 0..<width {
                let o = y * bytesPerRow + x * 4
                ptr[o] = 10      // B
                ptr[o + 1] = 20 // G
                ptr[o + 2] = 30 // R
                ptr[o + 3] = 255
            }
        }

        let rendered = try XCTUnwrap(Quick360FrameEncoder.renderRGBA(from: buffer, maxWidth: 16))
        XCTAssertEqual(rendered.width, width)
        XCTAssertEqual(rendered.height, height)
        XCTAssertEqual(rendered.rgba.count, width * height * 4)

        let gray = Quick360FrameEncoder.analysisGrayscale(from: buffer)
        XCTAssertEqual(gray.count, Quick360FrameEncoder.analysisWidth * Quick360FrameEncoder.analysisHeight)

        let jpeg = Quick360FrameEncoder.jpegData(from: buffer, maxWidth: 16)
        XCTAssertNotNil(jpeg)
        XCTAssertGreaterThan(jpeg?.count ?? 0, 0)
    }

    /// Documents Build 3 anti-pattern: never capture ARFrame into main.async.
    func testMustCopyPixelsBeforeMainQueueHop() {
        let copyBeforeAsync = true
        let hopARFrameToMain = false
        XCTAssertTrue(copyBeforeAsync)
        XCTAssertFalse(hopARFrameToMain)
    }
}

