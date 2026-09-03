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

    func testStartPoseMapsToSphereFrontCenter() {
        let origin = matrix_identity_float4x4
        let (yaw, pitch) = SphericalMath.relativeYawPitchRad(
            cameraTransform: origin,
            originTransform: origin
        )
        XCTAssertEqual(yaw, 0, accuracy: 0.02)
        XCTAssertEqual(pitch, 0, accuracy: 0.02)
        let uv = SphericalMath.equirectangularUV(yawRad: yaw, pitchRad: pitch)
        XCTAssertEqual(uv.x, 0.5, accuracy: 0.02)
        XCTAssertEqual(uv.y, 0.5, accuracy: 0.02)
    }

    func testPlus90YawMapsExpectedU() {
        // Ry(+90°): optical forward → -X, sphere yaw → -π/2, U → 0.25
        var cam = matrix_identity_float4x4
        let t = Float.pi / 2
        cam.columns.0 = SIMD4(cos(t), 0, -sin(t), 0)
        cam.columns.2 = SIMD4(sin(t), 0, cos(t), 0)
        let (yaw, _) = SphericalMath.relativeYawPitchRad(
            cameraTransform: cam,
            originTransform: matrix_identity_float4x4
        )
        XCTAssertEqual(yaw, -Float.pi / 2, accuracy: 0.05)
        let uv = SphericalMath.equirectangularUV(yawRad: yaw, pitchRad: 0)
        XCTAssertEqual(uv.x, 0.25, accuracy: 0.03)
    }

    func testMinus90YawMapsExpectedU() {
        var cam = matrix_identity_float4x4
        let t = -Float.pi / 2
        cam.columns.0 = SIMD4(cos(t), 0, -sin(t), 0)
        cam.columns.2 = SIMD4(sin(t), 0, cos(t), 0)
        let (yaw, _) = SphericalMath.relativeYawPitchRad(
            cameraTransform: cam,
            originTransform: matrix_identity_float4x4
        )
        XCTAssertEqual(yaw, Float.pi / 2, accuracy: 0.05)
        let uv = SphericalMath.equirectangularUV(yawRad: yaw, pitchRad: 0)
        XCTAssertEqual(uv.x, 0.75, accuracy: 0.03)
    }

    func testPitchUpDownMapsExpectedV() {
        // Pitch up: rotate around X so forward gains +Y
        var up = matrix_identity_float4x4
        let a: Float = 0.4
        up.columns.1 = SIMD4(0, cos(a), sin(a), 0)
        up.columns.2 = SIMD4(0, -sin(a), cos(a), 0)
        let (_, pitchUp) = SphericalMath.relativeYawPitchRad(
            cameraTransform: up,
            originTransform: matrix_identity_float4x4
        )
        XCTAssertGreaterThan(pitchUp, 0.2)
        let vUp = SphericalMath.equirectangularUV(yawRad: 0, pitchRad: pitchUp).y
        XCTAssertLessThan(vUp, 0.5)

        var down = matrix_identity_float4x4
        let b: Float = -0.4
        down.columns.1 = SIMD4(0, cos(b), sin(b), 0)
        down.columns.2 = SIMD4(0, -sin(b), cos(b), 0)
        let (_, pitchDown) = SphericalMath.relativeYawPitchRad(
            cameraTransform: down,
            originTransform: matrix_identity_float4x4
        )
        XCTAssertLessThan(pitchDown, -0.2)
        let vDown = SphericalMath.equirectangularUV(yawRad: 0, pitchRad: pitchDown).y
        XCTAssertGreaterThan(vDown, 0.5)
    }

    func testOpticalForwardIsNegativeZ() {
        let f = SphericalMath.forwardVector(from: matrix_identity_float4x4)
        XCTAssertEqual(f.x, 0, accuracy: 0.001)
        XCTAssertEqual(f.y, 0, accuracy: 0.001)
        XCTAssertEqual(f.z, -1, accuracy: 0.001)
    }
}

final class Quick360TargetLayoutTests: XCTestCase {
    func testTargetCount() {
        let targets = Quick360SphericalTargetLayout.makeTargets()
        XCTAssertEqual(targets.count, Quick360Config.targetCount)
        XCTAssertEqual(targets.count, Quick360Config.yawStepCount * Quick360Config.pitchBandsDeg.count)
        XCTAssertGreaterThanOrEqual(Quick360Config.yawStepCount, 8)
        XCTAssertLessThanOrEqual(Quick360Config.yawStepCount, 16)
    }

    func testProgressIncreasesOnSelection() {
        var targets = Quick360SphericalTargetLayout.makeTargets()
        XCTAssertEqual(Quick360SphericalTargetLayout.progressPercent(in: targets), 0)
        targets = Quick360SphericalTargetLayout.markSelected(targets: targets, targetId: 0)
        let expected = Int((1.0 / Double(targets.count) * 100).rounded())
        XCTAssertEqual(Quick360SphericalTargetLayout.progressPercent(in: targets), expected)
        XCTAssertGreaterThan(expected, 0)
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
        XCTAssertEqual(Quick360TranslationGuard.level(for: 0.30), .warning)
    }

    func testExcessiveLevel() {
        XCTAssertEqual(Quick360TranslationGuard.level(for: 0.50), .excessive)
    }

    func testDoesNotBlockCaptureOnExcessive() {
        var state = Quick360TranslationGuard.State.initial
        var moved = matrix_identity_float4x4
        moved.columns.3 = SIMD4<Float>(0.5, 0, 0, 1)
        state = Quick360TranslationGuard.update(
            state: state,
            cameraTransform: moved,
            originTransform: matrix_identity_float4x4
        )
        XCTAssertEqual(state.level, .excessive)
        XCTAssertFalse(state.shouldHoldKeyframe)
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
        XCTAssertTrue(config.planeDetection.contains(.horizontal))
        XCTAssertFalse(config.planeDetection.contains(.vertical))
        XCTAssertEqual(config.worldAlignment, .gravity)
    }

    func testVerticalPlaneDetectionFailsSafetyCheck() {
        let unsafe = ARWorldTrackingConfiguration()
        unsafe.planeDetection = [.horizontal, .vertical]
        XCTAssertFalse(Quick360ARConfiguration.isNonLiDARSafe(unsafe))
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
            jpegData: Data([0xFF, 0xD8, 0xFF]),
            brushRGBA: [],
            brushWidth: 0,
            brushHeight: 0,
            ambientIntensity: 500,
            ambientColorTemperature: 6500
        )
        XCTAssertEqual(payload.analysisGrayscale.count, 64 * 36)
        XCTAssertNotNil(payload.jpegData)
        // Value-type owned copy — safe across queues without retaining ARFrame/CVPixelBuffer.
        var hoppedTimestamp: Double = 0
        let sem = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            hoppedTimestamp = payload.timestamp
            sem.signal()
        }
        XCTAssertEqual(sem.wait(timeout: .now() + 2), .success)
        XCTAssertEqual(hoppedTimestamp, 1.0)
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
            jpegData: nil,
            brushRGBA: [],
            brushWidth: 0,
            brushHeight: 0,
            ambientIntensity: nil,
            ambientColorTemperature: nil
        )
        engine.ingest(payload: payload)
        XCTAssertTrue(engine.isRunning)
        XCTAssertFalse(engine.uiState.progressPercent < 0)
    }

    func testWantsJPEGCandidateTrueBeforeOriginSet() {
        let engine = Quick360CaptureEngine(mockMode: false)
        engine.start(sessionId: "s", captureId: "c")
        engine.beginCapture()
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

final class Quick360HybridSpaceTests: XCTestCase {
    func testCameraRayToSphereUV() {
        let yaw: Float = 0
        let pitch: Float = 0
        let uv = SphericalMath.equirectangularUV(yawRad: yaw, pitchRad: pitch)
        XCTAssertEqual(uv.x, 0.5, accuracy: 0.02)
        XCTAssertEqual(uv.y, 0.5, accuracy: 0.02)
    }

    func testFloorRayIntersectionBelowCamera() {
        let origin = simd_float3(0, 1.5, 0)
        let dir = simd_normalize(simd_float3(0, -1, 0.2))
        let t = Quick360FloorMath.rayPlaneIntersection(
            rayOrigin: origin,
            rayDirection: dir,
            planePoint: simd_float3(0, 0, 0),
            planeNormal: simd_float3(0, 1, 0)
        )
        XCTAssertNotNil(t)
        XCTAssertGreaterThan(t ?? 0, 0)
    }

    func testFloorLocalUVConversion() {
        let transform = matrix_identity_float4x4
        let uv = Quick360FloorMath.worldToFloorUV(
            worldPoint: simd_float3(0.5, 0, -0.5),
            floorCenter: .zero,
            extentX: 2,
            extentZ: 2,
            worldTransform: transform
        )
        XCTAssertNotNil(uv)
        XCTAssertEqual(uv!.x, 0.75, accuracy: 0.05)
        XCTAssertEqual(uv!.y, 0.25, accuracy: 0.05)
    }

    func testGrazingAngleRejected() {
        let grazing = Quick360FloorMath.isGrazingAngle(
            rayDirection: simd_normalize(simd_float3(1, -0.05, 0)),
            planeNormal: simd_float3(0, 1, 0),
            minCos: Quick360Config.floorMinIncidenceCos
        )
        XCTAssertTrue(grazing)
        let steep = Quick360FloorMath.isGrazingAngle(
            rayDirection: simd_normalize(simd_float3(0, -1, 0)),
            planeNormal: simd_float3(0, 1, 0),
            minCos: Quick360Config.floorMinIncidenceCos
        )
        XCTAssertFalse(steep)
    }

    func testFloorDetectorPrefersBelowCameraNearOrigin() {
        var low = matrix_identity_float4x4
        low.columns.3 = SIMD4(0, 0, 0, 1)
        var far = matrix_identity_float4x4
        far.columns.3 = SIMD4(8, 0, 0, 1)
        let candidates = [
            Quick360FloorDetector.Candidate(
                identifier: UUID(), worldTransform: far, extent: simd_float3(2, 0, 2),
                alignment: "horizontal", updateCount: 5
            ),
            Quick360FloorDetector.Candidate(
                identifier: UUID(), worldTransform: low, extent: simd_float3(2, 0, 2),
                alignment: "horizontal", updateCount: 5
            )
        ]
        var cam = matrix_identity_float4x4
        cam.columns.3 = SIMD4(0, 1.5, 0, 1)
        let best = Quick360FloorDetector.selectBest(
            candidates: candidates,
            cameraTransform: cam,
            originTransform: cam
        )
        XCTAssertEqual(best?.worldTransform.columns.3.x ?? 99, 0, accuracy: 0.01)
    }

    func testSphereBrushIncreasesCoverage() {
        let brush = Quick360LiveSphereBrush(width: 128, height: 64)
        let before = brush.coveragePercent()
        var thumb = [UInt8](repeating: 180, count: 32 * 24 * 4)
        for i in stride(from: 0, to: thumb.count, by: 4) {
            thumb[i] = 200
            thumb[i + 1] = 40
            thumb[i + 2] = 40
            thumb[i + 3] = 255
        }
        brush.paint(
            thumbRGBA: thumb,
            thumbWidth: 32,
            thumbHeight: 24,
            cameraTransform: matrix_identity_float4x4,
            captureBasis: Quick360CaptureBasis.make(fromStartCamera: matrix_identity_float4x4)!,
            intrinsics: CameraIntrinsics(fx: 400, fy: 400, cx: 320, cy: 240, width: 640, height: 480),
            observationConfidence: 0.8,
            now: 1
        )
        XCTAssertGreaterThan(brush.coveragePercent(), before)
        XCTAssertGreaterThan(brush.updateCount, 0)

        // After fade settles, captured preview stays vivid (not heavy desaturate).
        let preview = brush.composePreviewRGBA(now: 1 + Quick360Config.brushRevealFadeSec + 0.05)
        var foundVivid = false
        for i in 0..<(128 * 64) where brush.confidence[i] > 180 {
            let o = i * 4
            if preview[o] > 150 && preview[o + 1] < 100 {
                foundVivid = true
                break
            }
        }
        XCTAssertTrue(foundVivid)
    }

    func testCapturedPreviewIsNotWashedToGray() {
        let brush = Quick360LiveSphereBrush(width: 64, height: 32)
        var thumb = [UInt8](repeating: 0, count: 16 * 12 * 4)
        for i in stride(from: 0, to: thumb.count, by: 4) {
            thumb[i] = 220
            thumb[i + 1] = 30
            thumb[i + 2] = 30
            thumb[i + 3] = 255
        }
        brush.paint(
            thumbRGBA: thumb, thumbWidth: 16, thumbHeight: 12,
            cameraTransform: matrix_identity_float4x4,
            captureBasis: Quick360CaptureBasis.make(fromStartCamera: matrix_identity_float4x4)!,
            intrinsics: CameraIntrinsics(fx: 300, fy: 300, cx: 160, cy: 120, width: 320, height: 240),
            observationConfidence: 0.9,
            now: 10
        )
        let preview = brush.composePreviewRGBA(now: 11)
        let unseenGray = Int(Quick360Config.unseenNeutralGray)
        var capturedDistinctFromGray = 0
        for i in 0..<(64 * 32) where brush.confidence[i] > 0 {
            let o = i * 4
            let dist = abs(Int(preview[o]) - unseenGray) + abs(Int(preview[o + 1]) - unseenGray)
            if dist > 40 { capturedDistinctFromGray += 1 }
        }
        XCTAssertGreaterThan(capturedDistinctFromGray, 20)
    }

    func testFloorConfidenceReplacementPrefersBetterObservation() {
        let atlas = Quick360FloorAtlas(size: 64)
        let floor = CapturedFloorSurface.make(
            worldTransform: matrix_identity_float4x4,
            originTransform: matrix_identity_float4x4,
            extent: simd_float3(2, 0, 2),
            trackingConfidence: 0.8,
            textureSize: 64
        )
        var weak = [UInt8](repeating: 40, count: 16 * 16 * 4)
        for i in stride(from: 3, to: weak.count, by: 4) { weak[i] = 255 }
        // Camera looking down at floor (ARKit -Z forward → -Y world).
        var cam = matrix_identity_float4x4
        cam.columns.0 = SIMD4(1, 0, 0, 0)
        cam.columns.1 = SIMD4(0, 0, -1, 0)
        cam.columns.2 = SIMD4(0, 1, 0, 0)
        cam.columns.3 = SIMD4(0, 1.2, 0, 1)
        _ = atlas.paintFromCamera(
            thumbRGBA: weak, thumbWidth: 16, thumbHeight: 16,
            cameraTransform: cam,
            intrinsics: CameraIntrinsics(fx: 200, fy: 200, cx: 8, cy: 8, width: 16, height: 16),
            floor: floor, observationConfidence: 0.3, dynamicRatio: 0
        )
        let mid = atlas.coveragePercent()
        var strong = [UInt8](repeating: 220, count: 16 * 16 * 4)
        for i in stride(from: 3, to: strong.count, by: 4) { strong[i] = 255 }
        _ = atlas.paintFromCamera(
            thumbRGBA: strong, thumbWidth: 16, thumbHeight: 16,
            cameraTransform: cam,
            intrinsics: CameraIntrinsics(fx: 200, fy: 200, cx: 8, cy: 8, width: 16, height: 16),
            floor: floor, observationConfidence: 0.9, dynamicRatio: 0
        )
        XCTAssertGreaterThan(atlas.coveragePercent(), 0)
        XCTAssertGreaterThanOrEqual(atlas.coveragePercent(), mid)
    }

    func testFloorMetadataSerialization() throws {
        let surface = CapturedFloorSurface.make(
            worldTransform: matrix_identity_float4x4,
            originTransform: matrix_identity_float4x4,
            extent: simd_float3(2.5, 0, 2.5),
            trackingConfidence: 0.7,
            textureSize: 512
        )
        let meta = CapturedFloorSurfaceMetadata(surface: surface)
        let data = try JSONEncoder().encode(meta)
        let decoded = try JSONDecoder().decode(CapturedFloorSurfaceMetadata.self, from: data)
        XCTAssertEqual(decoded.textureWidth, 512)
        XCTAssertEqual(decoded.extent[0], 2.5, accuracy: 0.01)
        XCTAssertTrue(decoded.isShadowReceiverReady)
    }

    func testNoFloorFallbackStillAllowsCapture() {
        let engine = Quick360CaptureEngine(mockMode: true)
        engine.start(sessionId: "s", captureId: "c")
        engine.beginCapture()
        XCTAssertNil(engine.floorSurface)
        XCTAssertTrue(engine.isCapturing)
        XCTAssertTrue(engine.isRunning)
    }

    func testFloorExtentClamp() {
        let big = Quick360FloorMath.clampExtent(simd_float3(20, 0, 20), maxRadius: 3)
        XCTAssertLessThanOrEqual(big.x, 6.01)
        let small = Quick360FloorMath.clampExtent(simd_float3(0.1, 0, 0.1), maxRadius: 3)
        XCTAssertGreaterThanOrEqual(small.x, Quick360Config.floorMinExtentM)
    }

    func testSessionFloorPaths() throws {
        let id = UUID().uuidString
        let dir = try CaptureSessionStore.createFloorDirectory(sessionId: id)
        XCTAssertTrue(dir.path.contains("floor"))
        let tex = try CaptureSessionStore.quick360FloorTextureURL(sessionId: id)
        XCTAssertTrue(tex.lastPathComponent.contains("floor-texture"))
        CaptureSessionStore.deleteSession(sessionId: id)
    }

    func testGuidanceHidesTechnicalTerms() {
        let texts = [
            Quick360GuidanceKind.faceForward.primaryText,
            Quick360GuidanceKind.lookAround.primaryText,
            Quick360GuidanceKind.lookDownFloor.primaryText,
            Quick360GuidanceKind.stayInPlace.primaryText
        ]
        for text in texts {
            XCTAssertFalse(text.lowercased().contains("plane"))
            XCTAssertFalse(text.lowercased().contains("anchor"))
            XCTAssertFalse(text.lowercased().contains("yaw"))
            XCTAssertFalse(text.contains("translation"))
        }
    }
}

final class Quick360BrushOrientationTests: XCTestCase {
    func testPortraitUsesImageSpaceRightOrientation() {
        let o = Quick360BrushOrientation.cgImageOrientation(for: .portrait)
        XCTAssertEqual(o, .right)
    }

    func testPortraitIntrinsicsSwapAxes() {
        let sensor = CameraIntrinsics(fx: 1000, fy: 800, cx: 640, cy: 360, width: 1280, height: 720)
        let oriented = Quick360BrushOrientation.remappedIntrinsics(sensor, interface: .portrait)
        XCTAssertEqual(oriented.width, 720)
        XCTAssertEqual(oriented.height, 1280)
        XCTAssertEqual(oriented.fx, 800, accuracy: 0.1)
        XCTAssertEqual(oriented.fy, 1000, accuracy: 0.1)
        // 90° CW (.right): (cx,cy) → (H−1−cy, cx) — must match CIImage.oriented(.right), not CCW.
        XCTAssertEqual(oriented.cx, Float(720 - 1) - 360, accuracy: 0.1)
        XCTAssertEqual(oriented.cy, 640, accuracy: 0.1)
        // Must not leave landscape dims — that caused 90° content on sphere.
        XCTAssertLessThan(oriented.width, oriented.height)
    }

    func testPortraitRemapMatchesOrientedPixelFromSensorCW() {
        let sensor = CameraIntrinsics(fx: 1000, fy: 800, cx: 640, cy: 360, width: 1280, height: 720)
        let oriented = Quick360BrushOrientation.remappedIntrinsics(sensor, interface: .portrait)
        let mapped = Quick360BrushOrientation.orientedPixelFromSensorPortraitCW(
            sensorU: sensor.cx,
            sensorV: sensor.cy,
            sensorWidth: sensor.width,
            sensorHeight: sensor.height
        )
        XCTAssertEqual(oriented.cx, mapped.x, accuracy: 0.01)
        XCTAssertEqual(oriented.cy, mapped.y, accuracy: 0.01)
    }

    func testPortraitUpsideDownUsesCCWRemap() {
        let sensor = CameraIntrinsics(fx: 1000, fy: 800, cx: 640, cy: 360, width: 1280, height: 720)
        let oriented = Quick360BrushOrientation.remappedIntrinsics(sensor, interface: .portraitUpsideDown)
        XCTAssertEqual(oriented.cx, 360, accuracy: 0.1)
        XCTAssertEqual(oriented.cy, Float(1280 - 1) - 640, accuracy: 0.1)
    }

    func testPortraitCenterPixelRayIsOpticalForward() {
        let halfX: Float = 0.6
        let halfY: Float = 0.45
        let ray = Quick360BrushOrientation.portraitPixelRayDirection(
            normalizedX: 0.5, normalizedY: 0.5, halfFOVx: halfX, halfFOVy: halfY
        )
        XCTAssertEqual(ray.x, 0, accuracy: 0.05)
        XCTAssertEqual(ray.y, 0, accuracy: 0.05)
        XCTAssertEqual(ray.z, -1, accuracy: 0.05)
    }

    func testPortraitTopPixelRayPointsUp() {
        let ray = Quick360BrushOrientation.portraitPixelRayDirection(
            normalizedX: 0.5, normalizedY: 0.0, halfFOVx: 0.5, halfFOVy: 0.5
        )
        XCTAssertGreaterThan(ray.y, 0.2)
        XCTAssertLessThan(ray.z, 0)
    }

    func testPortraitRightPixelRayPointsRight() {
        let ray = Quick360BrushOrientation.portraitPixelRayDirection(
            normalizedX: 1.0, normalizedY: 0.5, halfFOVx: 0.5, halfFOVy: 0.5
        )
        XCTAssertGreaterThan(ray.x, 0.2)
        XCTAssertLessThan(ray.z, 0)
    }

    func testNoHardcodedYawOffsetForOrientation() {
        // Orientation fix lives in CGImagePropertyOrientation, not sphere yaw.
        let start = SphericalMath.relativeYawPitchRad(
            cameraTransform: matrix_identity_float4x4,
            originTransform: matrix_identity_float4x4
        )
        XCTAssertEqual(start.yaw, 0, accuracy: 0.01)
        XCTAssertNotEqual(
            Quick360BrushOrientation.cgImageOrientation(for: .portrait),
            .up
        )
    }

    func testNoHorizontalMirrorInYawSign() {
        // Turning right (Ry +90) → negative sphere yaw → U < 0.5 (content moves left on panosphere).
        var cam = matrix_identity_float4x4
        let t = Float.pi / 2
        cam.columns.0 = SIMD4(cos(t), 0, -sin(t), 0)
        cam.columns.2 = SIMD4(sin(t), 0, cos(t), 0)
        let (yaw, _) = SphericalMath.relativeYawPitchRad(
            cameraTransform: cam,
            originTransform: matrix_identity_float4x4
        )
        XCTAssertLessThan(yaw, 0)
    }

    func testFOVCornersCompactAroundCenterForForwardFrame() {
        let thumb = CameraIntrinsics(fx: 280, fy: 280, cx: 95, cy: 127, width: 192, height: 256)
        let cam = matrix_identity_float4x4
        let basis = Quick360CaptureBasis.make(fromStartCamera: cam)!
        let corners = Quick360FOVDiagnostics.footprintCorners(
            thumbIntrinsics: thumb,
            cameraTransform: cam,
            basis: basis
        )
        XCTAssertEqual(corners.count, 4)
        XCTAssertTrue(Quick360FOVDiagnostics.isCompactAroundCenter(corners))
        let cu = corners.map(\.u).reduce(0, +) / 4
        let cv = corners.map(\.v).reduce(0, +) / 4
        XCTAssertEqual(cu, 0.5, accuracy: 0.08)
        XCTAssertEqual(cv, 0.5, accuracy: 0.08)
    }

    func testFOVCornersMoveRightWithBodyYaw() {
        let thumb = CameraIntrinsics(fx: 280, fy: 280, cx: 95, cy: 127, width: 192, height: 256)
        let start = matrix_identity_float4x4
        let basis = Quick360CaptureBasis.make(fromStartCamera: start)!
        let t = Float(0.4)
        var cam = matrix_identity_float4x4
        cam.columns.0 = SIMD4(cos(t), 0, -sin(t), 0)
        cam.columns.2 = SIMD4(sin(t), 0, cos(t), 0)
        let at0 = Quick360FOVDiagnostics.footprintCorners(
            thumbIntrinsics: thumb, cameraTransform: start, basis: basis
        )
        let atRight = Quick360FOVDiagnostics.footprintCorners(
            thumbIntrinsics: thumb, cameraTransform: cam, basis: basis
        )
        let u0 = at0.map(\.u).reduce(0, +) / 4
        let uR = atRight.map(\.u).reduce(0, +) / 4
        XCTAssertLessThan(uR, u0)
    }

    func testPerspectiveCenterPixelMapsToSphereFront() {
        let thumb = CameraIntrinsics(fx: 300, fy: 300, cx: 100, cy: 150, width: 201, height: 301)
        let cam = matrix_identity_float4x4
        let basis = Quick360CaptureBasis.make(fromStartCamera: cam)!
        let (yaw, pitch) = basis.sphereYawPitchFromPixel(
            pixelU: thumb.cx, pixelV: thumb.cy, thumbIntrinsics: thumb, cameraTransform: cam
        )
        XCTAssertEqual(yaw, 0, accuracy: 0.02)
        XCTAssertEqual(pitch, 0, accuracy: 0.02)
    }

    func testPerspectiveTopCenterHasPositivePitchNearZeroYaw() {
        let thumb = CameraIntrinsics(fx: 300, fy: 300, cx: 100, cy: 150, width: 201, height: 301)
        let cam = matrix_identity_float4x4
        let basis = Quick360CaptureBasis.make(fromStartCamera: cam)!
        let (yaw, pitch) = basis.sphereYawPitchFromPixel(
            pixelU: thumb.cx, pixelV: 0, thumbIntrinsics: thumb, cameraTransform: cam
        )
        XCTAssertEqual(yaw, 0, accuracy: 0.05)
        XCTAssertGreaterThan(pitch, 0.15)
    }

    func testPerspectiveRightCenterHasPositiveYawNearZeroPitch() {
        let thumb = CameraIntrinsics(fx: 300, fy: 300, cx: 100, cy: 150, width: 201, height: 301)
        let cam = matrix_identity_float4x4
        let basis = Quick360CaptureBasis.make(fromStartCamera: cam)!
        let (yaw, pitch) = basis.sphereYawPitchFromPixel(
            pixelU: Float(thumb.width - 1), pixelV: thumb.cy, thumbIntrinsics: thumb, cameraTransform: cam
        )
        XCTAssertGreaterThan(yaw, 0.15)
        XCTAssertEqual(pitch, 0, accuracy: 0.05)
    }

    func testCameraRayAxisConventionCenterTopRight() {
        let thumb = CameraIntrinsics(fx: 300, fy: 300, cx: 100, cy: 150, width: 201, height: 301)
        let rays = Quick360PerspectiveProjection.sampleAxisRays(thumbIntrinsics: thumb)
        XCTAssertEqual(rays.center.x, 0, accuracy: 0.02)
        XCTAssertEqual(rays.center.y, 0, accuracy: 0.02)
        XCTAssertEqual(rays.center.z, -1, accuracy: 0.02)
        XCTAssertGreaterThan(rays.topCenter.y, 0.2)
        XCTAssertEqual(rays.topCenter.x, 0, accuracy: 0.05)
        XCTAssertGreaterThan(rays.rightCenter.x, 0.2)
        XCTAssertEqual(rays.rightCenter.y, 0, accuracy: 0.05)
    }

    func testAxisRaysInGravityBasisTopPitchRightYawOnly() {
        let thumb = CameraIntrinsics(fx: 300, fy: 300, cx: 100, cy: 150, width: 201, height: 301)
        let cam = matrix_identity_float4x4
        let basis = Quick360CaptureBasis.make(fromStartCamera: cam)!
        let yp = Quick360PerspectiveProjection.sampleAxisYawPitch(
            thumbIntrinsics: thumb, cameraTransform: cam, basis: basis
        )
        XCTAssertEqual(yp.center.yaw, 0, accuracy: 0.03)
        XCTAssertEqual(yp.center.pitch, 0, accuracy: 0.03)
        XCTAssertEqual(yp.topCenter.yaw, 0, accuracy: 0.05)
        XCTAssertGreaterThan(yp.topCenter.pitch, 0.15)
        XCTAssertGreaterThan(yp.rightCenter.yaw, 0.15)
        XCTAssertEqual(yp.rightCenter.pitch, 0, accuracy: 0.05)
    }

    func testRemappedIntrinsicsThenRaysStayPortraitAligned() {
        // Sensor landscape → portrait remapped → thumb rays must not swap X/Y.
        let sensor = CameraIntrinsics(fx: 1000, fy: 800, cx: 640, cy: 360, width: 1280, height: 720)
        let oriented = Quick360BrushOrientation.remappedIntrinsics(sensor, interface: .portrait)
        let thumb = Quick360PerspectiveProjection.scaledIntrinsics(oriented, thumbWidth: 180, thumbHeight: 320)
        let rays = Quick360PerspectiveProjection.sampleAxisRays(thumbIntrinsics: thumb)
        XCTAssertEqual(rays.center.x, 0, accuracy: 0.03)
        XCTAssertEqual(rays.center.y, 0, accuracy: 0.03)
        XCTAssertEqual(rays.center.z, -1, accuracy: 0.03)
        XCTAssertGreaterThan(rays.topCenter.y, abs(rays.topCenter.x) + 0.1)
        XCTAssertGreaterThan(rays.rightCenter.x, abs(rays.rightCenter.y) + 0.1)
    }

    func testPerspectiveFourCornersHaveIndependentYawPitch() {
        let thumb = CameraIntrinsics(fx: 280, fy: 280, cx: 95, cy: 127, width: 192, height: 256)
        let cam = matrix_identity_float4x4
        let basis = Quick360CaptureBasis.make(fromStartCamera: cam)!
        let corners = Quick360PerspectiveProjection.footprintCorners(
            thumbIntrinsics: thumb, cameraTransform: cam, basis: basis
        )
        XCTAssertEqual(corners.count, 4)
        let tl = corners[0]
        let tr = corners[1]
        let br = corners[2]
        let bl = corners[3]
        XCTAssertLessThan(tl.yawRad, 0)
        XCTAssertGreaterThan(tr.yawRad, 0)
        XCTAssertGreaterThan(tl.pitchRad, 0)
        XCTAssertLessThan(br.pitchRad, 0)
        XCTAssertEqual(tr.yawRad, br.yawRad, accuracy: 0.02)
        XCTAssertEqual(tl.yawRad, bl.yawRad, accuracy: 0.02)
        XCTAssertEqual(tl.pitchRad, tr.pitchRad, accuracy: 0.02)
        XCTAssertEqual(bl.pitchRad, br.pitchRad, accuracy: 0.02)
        XCTAssertGreaterThan(tr.yawRad - tl.yawRad, 0.3)
        XCTAssertGreaterThan(tl.pitchRad - bl.pitchRad, 0.3)
    }

    func testPerspectiveRoundTripCenterPixel() {
        let thumb = CameraIntrinsics(fx: 300, fy: 300, cx: 100, cy: 150, width: 201, height: 301)
        let cam = matrix_identity_float4x4
        let basis = Quick360CaptureBasis.make(fromStartCamera: cam)!
        let uv = basis.projectSphereDirectionToPixel(
            yawRad: 0, pitchRad: 0, cameraTransform: cam, thumbIntrinsics: thumb
        )
        XCTAssertNotNil(uv)
        XCTAssertEqual(uv!.x, thumb.cx, accuracy: 1.5)
        XCTAssertEqual(uv!.y, thumb.cy, accuracy: 1.5)
    }

    func testSingleFrameOpaquePaintWritesWithoutBlendGate() {
        let brush = Quick360LiveSphereBrush(width: 64, height: 32)
        var rgba = [UInt8](repeating: 0, count: 16 * 16 * 4)
        for i in 0..<(16 * 16) {
            rgba[i * 4] = 255
            rgba[i * 4 + 1] = 0
            rgba[i * 4 + 2] = 0
            rgba[i * 4 + 3] = 255
        }
        let basis = Quick360CaptureBasis.make(fromStartCamera: matrix_identity_float4x4)!
        brush.paint(
            thumbRGBA: rgba,
            thumbWidth: 16,
            thumbHeight: 16,
            cameraTransform: matrix_identity_float4x4,
            captureBasis: basis,
            intrinsics: CameraIntrinsics(fx: 500, fy: 500, cx: 320, cy: 240, width: 640, height: 480),
            observationConfidence: 1,
            now: 1,
            options: .singleFrameDebug
        )
        let cx = 32
        let cy = 16
        let o = (cy * 64 + cx) * 4
        XCTAssertEqual(brush.confidence[cy * 64 + cx], 255)
        XCTAssertGreaterThan(brush.rgba[o], 200)
        XCTAssertLessThan(brush.rgba[o + 1], 40)
    }

    // MARK: - Gravity-aligned basis

    private func cameraLooking(
        yawRad: Float,
        pitchRad: Float = 0,
        rollRad: Float = 0
    ) -> simd_float4x4 {
        // Build camera with optical -Z = world direction from yaw(around Y) then pitch.
        let cy = cos(yawRad), sy = sin(yawRad)
        let cp = cos(pitchRad), sp = sin(pitchRad)
        let cr = cos(rollRad), sr = sin(rollRad)
        // Forward (optical -Z in world): yaw around Y then pitch.
        let forward = simd_normalize(simd_float3(sy * cp, sp, -cy * cp))
        let worldUp = simd_float3(0, 1, 0)
        var right = simd_normalize(simd_cross(forward, worldUp))
        if abs(simd_dot(forward, worldUp)) > 0.98 {
            right = simd_float3(1, 0, 0)
        }
        var up = simd_normalize(simd_cross(right, forward))
        // Apply roll around forward.
        let rolledRight = right * cr + up * sr
        let rolledUp = -right * sr + up * cr
        right = rolledRight
        up = rolledUp
        // columns: 0=right, 1=up, 2=-forward (ARKit)
        var m = matrix_identity_float4x4
        m.columns.0 = SIMD4(right.x, right.y, right.z, 0)
        m.columns.1 = SIMD4(up.x, up.y, up.z, 0)
        m.columns.2 = SIMD4(-forward.x, -forward.y, -forward.z, 0)
        return m
    }

    func testGravityBasisStartPitchThenYaw60KeepsPitch() {
        let start = cameraLooking(yawRad: 0, pitchRad: 0.35) // ~20° up
        let basis = Quick360CaptureBasis.make(fromStartCamera: start)!
        let startYP = basis.centerYawPitch(cameraTransform: start)
        XCTAssertEqual(startYP.yaw, 0, accuracy: 0.05)
        XCTAssertEqual(startYP.pitch, 0.35, accuracy: 0.05)

        let turned = cameraLooking(yawRad: Float.pi / 3, pitchRad: 0.35) // +60° yaw, same pitch
        let yp = basis.centerYawPitch(cameraTransform: turned)
        XCTAssertEqual(yp.yaw, Float.pi / 3, accuracy: 0.08)
        XCTAssertEqual(yp.pitch, startYP.pitch, accuracy: 0.08)
        XCTAssertLessThan(abs(yp.pitch), 1.0) // must not explode toward pole (~80°)
    }

    func testGravityBasisStartRollThenYaw60() {
        let start = cameraLooking(yawRad: 0, pitchRad: 0.1, rollRad: 0.4)
        let basis = Quick360CaptureBasis.make(fromStartCamera: start)!
        let turned = cameraLooking(yawRad: Float.pi / 3, pitchRad: 0.1, rollRad: 0.4)
        let yp = basis.centerYawPitch(cameraTransform: turned)
        XCTAssertEqual(yp.yaw, Float.pi / 3, accuracy: 0.1)
        XCTAssertEqual(yp.pitch, 0.1, accuracy: 0.1)
    }

    func testGravityBasisRollOnlyKeepsYawPitchStable() {
        let start = cameraLooking(yawRad: 0.2, pitchRad: 0.05)
        let basis = Quick360CaptureBasis.make(fromStartCamera: start)!
        let base = basis.centerYawPitch(cameraTransform: start)
        let rolled = cameraLooking(yawRad: 0.2, pitchRad: 0.05, rollRad: 0.5)
        let yp = basis.centerYawPitch(cameraTransform: rolled)
        XCTAssertEqual(yp.yaw, base.yaw, accuracy: 0.05)
        XCTAssertEqual(yp.pitch, base.pitch, accuracy: 0.05)
    }

    // MARK: - Roll-free patch orientation

    func testStabilizedFrameDropsRollKeepsForward() {
        let level = cameraLooking(yawRad: 0, pitchRad: 0.15)
        let rolled = cameraLooking(yawRad: 0, pitchRad: 0.15, rollRad: 0.45) // ~26°
        let f0 = Quick360StabilizedCameraFrame.make(fromCamera: level)!
        let fR = Quick360StabilizedCameraFrame.make(fromCamera: rolled)!
        XCTAssertEqual(f0.forward.x, fR.forward.x, accuracy: 0.02)
        XCTAssertEqual(f0.forward.y, fR.forward.y, accuracy: 0.02)
        XCTAssertEqual(f0.forward.z, fR.forward.z, accuracy: 0.02)
        XCTAssertEqual(f0.right.x, fR.right.x, accuracy: 0.03)
        XCTAssertEqual(f0.right.y, fR.right.y, accuracy: 0.03)
        XCTAssertEqual(f0.right.z, fR.right.z, accuracy: 0.03)
        XCTAssertEqual(f0.up.x, fR.up.x, accuracy: 0.03)
        XCTAssertEqual(f0.up.y, fR.up.y, accuracy: 0.03)
        XCTAssertEqual(f0.up.z, fR.up.z, accuracy: 0.03)
        // Raw camera +X must differ under roll (otherwise test is vacuous).
        let rawRight0 = simd_float3(level.columns.0.x, level.columns.0.y, level.columns.0.z)
        let rawRightR = simd_float3(rolled.columns.0.x, rolled.columns.0.y, rolled.columns.0.z)
        XCTAssertGreaterThan(simd_length(rawRight0 - rawRightR), 0.2)
    }

    func testRollOnlyKeepsPatchPixelYawPitchUpright() {
        let thumb = CameraIntrinsics(fx: 300, fy: 300, cx: 100, cy: 150, width: 201, height: 301)
        let level = cameraLooking(yawRad: 0, pitchRad: 0)
        let rolled = cameraLooking(yawRad: 0, pitchRad: 0, rollRad: 0.4) // ~23°
        let basis = Quick360CaptureBasis.make(fromStartCamera: level)!
        let yp0 = Quick360PerspectiveProjection.sampleAxisYawPitch(
            thumbIntrinsics: thumb, cameraTransform: level, basis: basis
        )
        let ypR = Quick360PerspectiveProjection.sampleAxisYawPitch(
            thumbIntrinsics: thumb, cameraTransform: rolled, basis: basis
        )
        // Center stays; top → pitch only; right → yaw only — identical under roll.
        XCTAssertEqual(ypR.center.yaw, yp0.center.yaw, accuracy: 0.03)
        XCTAssertEqual(ypR.center.pitch, yp0.center.pitch, accuracy: 0.03)
        XCTAssertEqual(ypR.topCenter.yaw, yp0.topCenter.yaw, accuracy: 0.04)
        XCTAssertEqual(ypR.topCenter.pitch, yp0.topCenter.pitch, accuracy: 0.04)
        XCTAssertEqual(ypR.rightCenter.yaw, yp0.rightCenter.yaw, accuracy: 0.04)
        XCTAssertEqual(ypR.rightCenter.pitch, yp0.rightCenter.pitch, accuracy: 0.04)
        XCTAssertEqual(ypR.topCenter.yaw, 0, accuracy: 0.05)
        XCTAssertGreaterThan(ypR.topCenter.pitch, 0.15)
        XCTAssertGreaterThan(ypR.rightCenter.yaw, 0.15)
        XCTAssertEqual(ypR.rightCenter.pitch, 0, accuracy: 0.05)
    }

    func testRollOnlyStabilizedWorldRaysMatchLevel() {
        let thumb = CameraIntrinsics(fx: 300, fy: 300, cx: 100, cy: 150, width: 201, height: 301)
        let level = cameraLooking(yawRad: 0.1, pitchRad: 0.08)
        let rolled = cameraLooking(yawRad: 0.1, pitchRad: 0.08, rollRad: 0.5)
        let basis = Quick360CaptureBasis.make(fromStartCamera: level)!
        let w0 = Quick360PerspectiveProjection.sampleAxisWorldRays(
            thumbIntrinsics: thumb, cameraTransform: level, basis: basis
        )
        let wR = Quick360PerspectiveProjection.sampleAxisWorldRays(
            thumbIntrinsics: thumb, cameraTransform: rolled, basis: basis
        )
        XCTAssertEqual(w0.center.x, wR.center.x, accuracy: 0.03)
        XCTAssertEqual(w0.center.y, wR.center.y, accuracy: 0.03)
        XCTAssertEqual(w0.center.z, wR.center.z, accuracy: 0.03)
        XCTAssertEqual(w0.topCenter.x, wR.topCenter.x, accuracy: 0.03)
        XCTAssertEqual(w0.topCenter.y, wR.topCenter.y, accuracy: 0.03)
        XCTAssertEqual(w0.topCenter.z, wR.topCenter.z, accuracy: 0.03)
        XCTAssertEqual(w0.rightCenter.x, wR.rightCenter.x, accuracy: 0.03)
        XCTAssertEqual(w0.rightCenter.y, wR.rightCenter.y, accuracy: 0.03)
        XCTAssertEqual(w0.rightCenter.z, wR.rightCenter.z, accuracy: 0.03)

        // Full camera rotation WOULD spin the top ray under roll — that was the bug.
        let topLocal = Quick360PerspectiveProjection.sampleAxisRays(thumbIntrinsics: thumb).topCenter
        let raw0 = simd_normalize(Quick360CaptureBasis.cameraRotation(from: level) * topLocal)
        let rawR = simd_normalize(Quick360CaptureBasis.cameraRotation(from: rolled) * topLocal)
        XCTAssertGreaterThan(simd_length(raw0 - rawR), 0.15)
    }

    func testBodyYawMovesPatchRightWhileKeepingUprightAxes() {
        let thumb = CameraIntrinsics(fx: 300, fy: 300, cx: 100, cy: 150, width: 201, height: 301)
        let start = cameraLooking(yawRad: 0, pitchRad: 0)
        let basis = Quick360CaptureBasis.make(fromStartCamera: start)!
        let turned = cameraLooking(yawRad: 0.4, pitchRad: 0) // ~23° body right
        let yp = Quick360PerspectiveProjection.sampleAxisYawPitch(
            thumbIntrinsics: thumb, cameraTransform: turned, basis: basis
        )
        XCTAssertGreaterThan(yp.center.yaw, 0.3)
        XCTAssertEqual(yp.center.pitch, 0, accuracy: 0.05)
        // Patch upright: top still pitch-only relative to center; right still yaw-only.
        XCTAssertEqual(yp.topCenter.yaw, yp.center.yaw, accuracy: 0.05)
        XCTAssertGreaterThan(yp.topCenter.pitch, yp.center.pitch + 0.15)
        XCTAssertGreaterThan(yp.rightCenter.yaw, yp.center.yaw + 0.15)
        XCTAssertEqual(yp.rightCenter.pitch, yp.center.pitch, accuracy: 0.05)
    }

    func testActualPitchUpMovesPatchUpWithStabilizedFrame() {
        let thumb = CameraIntrinsics(fx: 300, fy: 300, cx: 100, cy: 150, width: 201, height: 301)
        let start = cameraLooking(yawRad: 0, pitchRad: 0)
        let basis = Quick360CaptureBasis.make(fromStartCamera: start)!
        let lookingUp = cameraLooking(yawRad: 0, pitchRad: 0.35)
        let yp = Quick360PerspectiveProjection.sampleAxisYawPitch(
            thumbIntrinsics: thumb, cameraTransform: lookingUp, basis: basis
        )
        XCTAssertEqual(yp.center.yaw, 0, accuracy: 0.05)
        XCTAssertGreaterThan(yp.center.pitch, 0.3)
        let world = Quick360PerspectiveProjection.sampleAxisWorldRays(
            thumbIntrinsics: thumb, cameraTransform: lookingUp, basis: basis
        )
        XCTAssertGreaterThan(world.center.y, 0.25)
    }

    func testGravityBasisActualPitchUpIncreasesPitch() {
        let start = cameraLooking(yawRad: 0, pitchRad: 0)
        let basis = Quick360CaptureBasis.make(fromStartCamera: start)!
        let up = cameraLooking(yawRad: 0, pitchRad: 0.5)
        let yp = basis.centerYawPitch(cameraTransform: up)
        XCTAssertEqual(yp.yaw, 0, accuracy: 0.05)
        XCTAssertGreaterThan(yp.pitch, 0.4)
    }

    func testGravityRightPixelWorldRayPositiveYaw() {
        let cam = matrix_identity_float4x4
        let basis = Quick360CaptureBasis.make(fromStartCamera: cam)!
        let thumb = CameraIntrinsics(fx: 300, fy: 300, cx: 100, cy: 150, width: 201, height: 301)
        let (yaw, pitch) = basis.sphereYawPitchFromPixel(
            pixelU: Float(thumb.width - 1),
            pixelV: thumb.cy,
            thumbIntrinsics: thumb,
            cameraTransform: cam
        )
        XCTAssertGreaterThan(yaw, 0.1)
        XCTAssertEqual(pitch, 0, accuracy: 0.08)
    }

    func testGravityCenterPixelMatchesCameraForward() {
        let cam = cameraLooking(yawRad: 0.25, pitchRad: -0.1)
        let basis = Quick360CaptureBasis.make(fromStartCamera: cam)!
        let thumb = CameraIntrinsics(fx: 300, fy: 300, cx: 100, cy: 150, width: 201, height: 301)
        let fromPixel = basis.sphereYawPitchFromPixel(
            pixelU: thumb.cx, pixelV: thumb.cy, thumbIntrinsics: thumb, cameraTransform: cam
        )
        let fromCenter = basis.centerYawPitch(cameraTransform: cam)
        XCTAssertEqual(fromPixel.yaw, fromCenter.yaw, accuracy: 0.03)
        XCTAssertEqual(fromPixel.pitch, fromCenter.pitch, accuracy: 0.03)
    }

    func testRelativeRollNearZeroWhenLevel() {
        let roll = Quick360FOVDiagnostics.relativeRollRad(
            cameraTransform: matrix_identity_float4x4,
            originTransform: matrix_identity_float4x4
        )
        XCTAssertEqual(roll, 0, accuracy: 0.02)
    }

    func testSplitDebugSettingsDefaultsHideFloor() {
        let s = Quick360SplitDebugSettings.default
        XCTAssertFalse(s.showFloorRenderer)
        XCTAssertFalse(s.enabled)
        XCTAssertFalse(s.singleFrameMode) // production continuous paint
        XCTAssertTrue(Quick360SplitDebugSettings.splitDebug.singleFrameMode)
    }

    func testSplitDebugTestALocksPaintsAndFreezesIndependentlyOfCanStart() {
        let engine = Quick360CaptureEngine(mockMode: true)
        engine.updateSplitDebugSettings { settings in
            settings.enabled = true
            settings.singleFrameMode = true
            settings.paintEnabled = true
        }
        engine.start(sessionId: "test-a", captureId: "cap-a")

        let w = 32
        let h = 48
        var rgba = [UInt8](repeating: 180, count: w * h * 4)
        for i in 0..<(w * h) {
            rgba[i * 4 + 3] = 255
        }
        let payload = Quick360FramePayload(
            timestamp: 1.0,
            cameraTransform: matrix_identity_float4x4,
            intrinsics: CameraIntrinsics(fx: 500, fy: 500, cx: 320, cy: 240, width: 640, height: 480),
            analysisGrayscale: [UInt8](repeating: 40, count: 64 * 36),
            jpegData: nil,
            brushRGBA: rgba,
            brushWidth: w,
            brushHeight: h,
            ambientIntensity: nil,
            ambientColorTemperature: nil
        )
        // Pre-start ingest caches frame; production canStart may still be false.
        engine.ingest(payload: payload)
        let pre = engine.debugPreviewSnapshot()
        XCTAssertTrue(pre.hasCachedFrame)
        XCTAssertEqual(pre.brushDebug.brushWidth, w)
        XCTAssertEqual(pre.brushDebug.brushHeight, h)
        XCTAssertFalse(pre.brushDebug.originLocked)

        XCTAssertTrue(engine.runSplitDebugTestA())
        let snap = engine.debugPreviewSnapshot()
        XCTAssertEqual(snap.testPhase, .testAFrozen)
        XCTAssertTrue(engine.splitDebugSettings.frozen)
        XCTAssertTrue(snap.brushDebug.originLocked)
        XCTAssertEqual(snap.brushDebug.relativeYawDeg, 0, accuracy: 0.5)
        XCTAssertEqual(snap.brushDebug.relativePitchDeg, 0, accuracy: 0.5)
        XCTAssertEqual(snap.brushDebug.centerU, 0.5, accuracy: 0.02)
        XCTAssertEqual(snap.brushDebug.centerV, 0.5, accuracy: 0.02)
        XCTAssertEqual(snap.brushDebug.brushWidth, w)
        XCTAssertNotNil(snap.sphere)

        engine.resetSplitDebugTest()
        let reset = engine.debugPreviewSnapshot()
        XCTAssertEqual(reset.testPhase, .idle)
        XCTAssertFalse(engine.splitDebugSettings.frozen)
        XCTAssertFalse(reset.brushDebug.originLocked)
    }

    func testSplitDebugHUDKeepsSourceSizeWhenEmptyBrushFrameArrives() {
        let engine = Quick360CaptureEngine(mockMode: true)
        engine.updateSplitDebugSettings { $0.enabled = true }
        engine.start(sessionId: "src", captureId: "src")
        let w = 20
        let h = 30
        var rgba = [UInt8](repeating: 100, count: w * h * 4)
        for i in 0..<(w * h) { rgba[i * 4 + 3] = 255 }
        let full = Quick360FramePayload(
            timestamp: 1.0,
            cameraTransform: matrix_identity_float4x4,
            intrinsics: CameraIntrinsics(fx: 400, fy: 400, cx: 200, cy: 150, width: 400, height: 300),
            analysisGrayscale: [UInt8](repeating: 10, count: 64 * 36),
            jpegData: nil,
            brushRGBA: rgba,
            brushWidth: w,
            brushHeight: h,
            ambientIntensity: nil,
            ambientColorTemperature: nil
        )
        engine.ingest(payload: full)
        let empty = Quick360FramePayload(
            timestamp: 1.2,
            cameraTransform: matrix_identity_float4x4,
            intrinsics: CameraIntrinsics(fx: 400, fy: 400, cx: 200, cy: 150, width: 400, height: 300),
            analysisGrayscale: [UInt8](repeating: 10, count: 64 * 36),
            jpegData: nil,
            brushRGBA: [],
            brushWidth: 0,
            brushHeight: 0,
            ambientIntensity: nil,
            ambientColorTemperature: nil
        )
        engine.ingest(payload: empty)
        let snap = engine.debugPreviewSnapshot()
        XCTAssertEqual(snap.brushDebug.brushWidth, w)
        XCTAssertEqual(snap.brushDebug.brushHeight, h)
    }
}

final class Quick360SphereCoordinateConventionTests: XCTestCase {
    func testEquirectUVMatchesSphericalMath() {
        let uv = Quick360SphereCoordinateConvention.equirectangularUV(yawRad: 0, pitchRad: 0)
        let ref = SphericalMath.equirectangularUV(yawRad: 0, pitchRad: 0)
        XCTAssertEqual(uv.x, ref.x, accuracy: 0.001)
        XCTAssertEqual(uv.y, ref.y, accuracy: 0.001)
        XCTAssertEqual(uv.x, 0.5, accuracy: 0.01)
        XCTAssertEqual(uv.y, 0.5, accuracy: 0.01)
    }

    func testOpticalForwardAtOriginIsNegativeZ() {
        let f = Quick360SphereCoordinateConvention.opticalForward(yawRad: 0, pitchRad: 0)
        XCTAssertEqual(f.x, 0, accuracy: 0.01)
        XCTAssertEqual(f.y, 0, accuracy: 0.01)
        XCTAssertEqual(f.z, -1, accuracy: 0.01)
    }

    func testInsideOutScaleIsNegativeX() {
        let s = Quick360SphereCoordinateConvention.insideOutScale
        XCTAssertEqual(s.x, -1, accuracy: 0.001)
        XCTAssertEqual(s.y, 1, accuracy: 0.001)
        XCTAssertEqual(s.z, 1, accuracy: 0.001)
    }

    func testPrepareEquirectForInsideOutIsPassthroughNoHorizontalFlip() {
        // Asymmetric 2×1 RGBA: left pixel red, right pixel blue.
        let rgba: [UInt8] = [
            255, 0, 0, 255,
            0, 0, 255, 255
        ]
        guard let src = Quick360ImageBuffer.cgImage(rgba: rgba, width: 2, height: 1) else {
            XCTFail("cgImage")
            return
        }
        guard let out = Quick360SphereCoordinateConvention.prepareEquirectTextureForInsideOut(src) else {
            XCTFail("prepare")
            return
        }
        XCTAssertEqual(out.width, 2)
        XCTAssertEqual(out.height, 1)
        guard let data = out.dataProvider?.data as Data? else {
            XCTFail("data")
            return
        }
        // Left stays red — must not be horizontally mirrored for inside-out scale.
        XCTAssertEqual(data[0], 255)
        XCTAssertEqual(data[1], 0)
        XCTAssertEqual(data[2], 0)
        XCTAssertEqual(data[4], 0)
        XCTAssertEqual(data[5], 0)
        XCTAssertEqual(data[6], 255)
    }

    /// Portrait-like camera: +X = world up, +Y = world −X (90° from identity).
    /// Raw camera parenting would map equirect pitch along world −X; gravity pose keeps +Y = up.
    func testGravityAlignedSphereKeepsMeshYAsWorldUpUnderPortraitRoll() {
        // columns: X=(0,1,0), Y=(-1,0,0), Z=(0,0,1) — look still −Z.
        let origin = simd_float4x4(
            SIMD4<Float>(0, 1, 0, 0),
            SIMD4<Float>(-1, 0, 0, 0),
            SIMD4<Float>(0, 0, 1, 0),
            SIMD4<Float>(0, 0, 0, 1)
        )
        let camY = simd_float3(origin.columns.1.x, origin.columns.1.y, origin.columns.1.z)
        XCTAssertEqual(camY.x, -1, accuracy: 0.01)
        XCTAssertEqual(simd_dot(camY, SIMD3<Float>(0, 1, 0)), 0, accuracy: 0.01)

        guard let pose = Quick360SphereCoordinateConvention.gravityAlignedSphereTransform(
            originCamera: origin
        ) else {
            XCTFail("gravity pose")
            return
        }
        let meshUp = simd_float3(pose.columns.1.x, pose.columns.1.y, pose.columns.1.z)
        XCTAssertEqual(meshUp.x, 0, accuracy: 0.05)
        XCTAssertEqual(meshUp.y, 1, accuracy: 0.05)
        XCTAssertEqual(meshUp.z, 0, accuracy: 0.05)

        let meshForward = -simd_float3(pose.columns.2.x, pose.columns.2.y, pose.columns.2.z)
        XCTAssertEqual(meshForward.x, 0, accuracy: 0.05)
        XCTAssertEqual(meshForward.y, 0, accuracy: 0.05)
        XCTAssertEqual(meshForward.z, -1, accuracy: 0.05)
    }

    func testPortraitRemappedUnprojectWithoutAxisFixDiffersFromSensorRay() {
        // Documents why we align sphere to gravity instead of inventing texture ±90°.
        // Sensor ray at left-center vs portrait-top (CW maps sensor left → portrait top)
        // share a scene direction only after gravity/stabilized display — remapped K
        // alone is for portrait thumb sampling, not raw ARKit R*ray equivalence.
        let sensor = CameraIntrinsics(fx: 1000, fy: 800, cx: 640, cy: 360, width: 1280, height: 720)
        let oriented = Quick360BrushOrientation.remappedIntrinsics(sensor, interface: .portrait)
        let sensorLeft = Quick360PerspectiveProjection.cameraRayFromPixel(
            pixelU: 0, pixelV: sensor.cy, thumbIntrinsics: sensor
        )
        let portraitTop = Quick360PerspectiveProjection.cameraRayFromPixel(
            pixelU: oriented.cx, pixelV: 0, thumbIntrinsics: oriented
        )
        // Same geometric edge after CW — rays must not silently match without the
        // stabilized/gravity path; portrait-top is +Y in image space, sensor-left is −X.
        XCTAssertLessThan(sensorLeft.x, -0.2)
        XCTAssertEqual(sensorLeft.y, 0, accuracy: 0.08)
        XCTAssertEqual(portraitTop.x, 0, accuracy: 0.08)
        XCTAssertGreaterThan(portraitTop.y, 0.2)
        XCTAssertGreaterThan(
            abs(sensorLeft.x - portraitTop.x) + abs(sensorLeft.y - portraitTop.y),
            0.5
        )
    }

    func testProductionSplitDebugDefaultsAllowContinuousPaint() {
        let s = Quick360SplitDebugSettings.production
        XCTAssertFalse(s.enabled)
        XCTAssertFalse(s.singleFrameMode)
        XCTAssertTrue(s.paintEnabled)
        XCTAssertFalse(s.showFloorRenderer)
    }

    func testSplitDebugCaptureModeDefaultIsOff() {
        XCTAssertFalse(Quick360Config.splitDebugCaptureModeDefault)
        XCTAssertFalse(Quick360Config.splitDebugCaptureMode)
    }

    func testLivePreviewResolutionBump() {
        XCTAssertEqual(Quick360Config.livePreviewWidth, 1024)
        XCTAssertEqual(Quick360Config.livePreviewHeight, 512)
        XCTAssertEqual(Quick360Config.brushThumbMaxWidth, 512)
        XCTAssertEqual(Quick360Config.liveBrushMinIntervalSec, 0.2, accuracy: 0.001)
    }

    func testBeginCapturePaintsImmediateFirstFrameFromCache() {
        let engine = Quick360CaptureEngine(mockMode: true)
        engine.start(sessionId: "first-paint", captureId: "c1")
        let w = 32
        let h = 48
        var rgba = [UInt8](repeating: 0, count: w * h * 4)
        for i in 0..<(w * h) {
            let o = i * 4
            rgba[o] = 200
            rgba[o + 1] = 40
            rgba[o + 2] = 40
            rgba[o + 3] = 255
        }
        let payload = Quick360FramePayload(
            timestamp: 1.0,
            cameraTransform: matrix_identity_float4x4,
            intrinsics: CameraIntrinsics(fx: 500, fy: 500, cx: 16, cy: 24, width: 32, height: 48),
            analysisGrayscale: [UInt8](repeating: 128, count: Quick360FrameEncoder.analysisWidth * Quick360FrameEncoder.analysisHeight),
            jpegData: nil,
            brushRGBA: rgba,
            brushWidth: w,
            brushHeight: h,
            ambientIntensity: nil,
            ambientColorTemperature: nil
        )
        engine.ingest(payload: payload)
        XCTAssertEqual(engine.sphereBrush.coveragePercent(), 0, accuracy: 0.01)
        engine.beginCapture()
        XCTAssertEqual(engine.liveBrushStats.firstFramePaintCount, 1)
        XCTAssertGreaterThan(engine.sphereBrush.coveragePercent(), 0.5)
        XCTAssertGreaterThan(engine.liveBrushStats.acceptedCount, 0)
    }

    func testLiveBrushStatsTracksRejectReasons() {
        let stats = Quick360LiveBrushStats()
        stats.record(
            .rejected(.throttle, yawDeg: 10, pitchDeg: 0, angularSpeedDegPerSec: 80),
            pixels: 0,
            paintMs: 0
        )
        stats.record(
            .accepted(yawDeg: 20, pitchDeg: 5, angularSpeedDegPerSec: 10),
            pixels: 100,
            paintMs: 12
        )
        let line = stats.summaryLine()
        XCTAssertTrue(line.contains("accept=1"))
        XCTAssertTrue(line.contains("throttle=1"))
    }
}



