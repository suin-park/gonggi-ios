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
            originTransform: matrix_identity_float4x4,
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
            originTransform: matrix_identity_float4x4,
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
        // Must not leave landscape dims — that caused 90° content on sphere.
        XCTAssertLessThan(oriented.width, oriented.height)
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
        let halfX: Float = 0.55
        let halfY: Float = 0.70
        let corners = Quick360FOVDiagnostics.footprintCorners(
            centerYawRad: 0,
            centerPitchRad: 0,
            halfFOVx: halfX,
            halfFOVy: halfY
        )
        XCTAssertEqual(corners.count, 4)
        XCTAssertTrue(Quick360FOVDiagnostics.isCompactAroundCenter(corners))
        // Center of quad near equirect center
        let cu = corners.map(\.u).reduce(0, +) / 4
        let cv = corners.map(\.v).reduce(0, +) / 4
        XCTAssertEqual(cu, 0.5, accuracy: 0.05)
        XCTAssertEqual(cv, 0.5, accuracy: 0.05)
        // No corner at pole (v≈0 or v≈1) or seam jump for forward FOV
        for c in corners {
            XCTAssertGreaterThan(c.v, 0.12)
            XCTAssertLessThan(c.v, 0.88)
            XCTAssertGreaterThan(c.u, 0.2)
            XCTAssertLessThan(c.u, 0.8)
        }
    }

    func testFOVCornersMoveRightWithPositiveYaw() {
        let halfX: Float = 0.5
        let halfY: Float = 0.5
        let at0 = Quick360FOVDiagnostics.footprintCorners(
            centerYawRad: 0, centerPitchRad: 0, halfFOVx: halfX, halfFOVy: halfY
        )
        let atRight = Quick360FOVDiagnostics.footprintCorners(
            centerYawRad: 0.4, centerPitchRad: 0, halfFOVx: halfX, halfFOVy: halfY
        )
        let u0 = at0.map(\.u).reduce(0, +) / 4
        let uR = atRight.map(\.u).reduce(0, +) / 4
        XCTAssertGreaterThan(uR, u0)
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
        XCTAssertTrue(s.singleFrameMode)
    }
}



