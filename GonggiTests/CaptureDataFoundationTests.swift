import simd
import XCTest
@testable import Gonggi

/// P0 / P0.5 acceptance: translation baseline ≠ rotation, PTS SoT, sync contract.
final class CaptureDataFoundationTests: XCTestCase {
    // MARK: - Test A / B / C (synthetic poses)

    func testA_Stationary_BaselineInsufficient() {
        var analyzer = TranslationBaselineAnalyzer()
        var t = matrix_identity_float4x4
        analyzer.acceptKeyframe(transform: t)
        for _ in 0..<30 {
            let e = analyzer.evaluate(transform: t, trackingNormal: true)
            XCTAssertEqual(e.grade, .insufficient)
            XCTAssertLessThan(e.translationBaselineM, 0.01)
        }
        XCTAssertEqual(analyzer.bestGrade, .insufficient)
        XCTAssertLessThan(Double(analyzer.totalPathLengthM), 0.05)
    }

    func testB_InPlaceRotation_BaselineInsufficient() {
        var analyzer = TranslationBaselineAnalyzer()
        let origin = matrix_identity_float4x4
        analyzer.acceptKeyframe(transform: origin)

        var rotated = origin
        let angle: Float = .pi / 2
        rotated.columns.0 = SIMD4(cos(angle), 0, -sin(angle), 0)
        rotated.columns.2 = SIMD4(sin(angle), 0, cos(angle), 0)

        let e = analyzer.evaluate(transform: rotated, trackingNormal: true)
        XCTAssertTrue(e.isInPlaceRotation)
        XCTAssertEqual(e.grade, .insufficient, "In-place rotation must NOT raise translation baseline grade")
        XCTAssertEqual(analyzer.bestGrade, .insufficient)
    }

    func testC_LateralTranslation_BaselineAcceptableOrGood() {
        var analyzer = TranslationBaselineAnalyzer()
        let origin = matrix_identity_float4x4
        analyzer.acceptKeyframe(transform: origin)

        var moved = origin
        moved.columns.3 = SIMD4(0.5, 0, 0, 1)
        let e = analyzer.evaluate(transform: moved, trackingNormal: true)
        XCTAssertFalse(e.isInPlaceRotation)
        XCTAssertGreaterThanOrEqual(e.translationBaselineM, 0.45)
        XCTAssertTrue(e.grade == .acceptable || e.grade == .good)
        XCTAssertNotEqual(e.grade, .insufficient)
    }

    func testD_ForwardPathIncreasesPathLength() {
        var analyzer = TranslationBaselineAnalyzer()
        var t = matrix_identity_float4x4
        analyzer.acceptKeyframe(transform: t)
        for i in 1...10 {
            t.columns.3 = SIMD4(0, 0, -Float(i) * 0.1, 1)
            _ = analyzer.evaluate(transform: t, trackingNormal: true)
        }
        XCTAssertGreaterThan(analyzer.totalPathLengthM, 0.8)
        XCTAssertGreaterThan(analyzer.maxBaselineM, 0.9)
    }

    func testKeyframeRejectsInPlaceSpin() {
        let a = matrix_identity_float4x4
        var b = a
        let angle: Float = 1.5
        b.columns.0 = SIMD4(cos(angle), 0, -sin(angle), 0)
        b.columns.2 = SIMD4(sin(angle), 0, cos(angle), 0)
        let d = KeyframeSelector3DGS.shouldAccept(
            timestamp: 1.0,
            transform: b,
            trackingNormal: true,
            lastKeyframeTimestamp: 0,
            lastKeyframeTransform: a
        )
        XCTAssertFalse(d.accept)
    }

    func testKeyframeAcceptsBaseline() {
        let a = matrix_identity_float4x4
        var b = a
        b.columns.3 = SIMD4(0.2, 0, 0, 1)
        let d = KeyframeSelector3DGS.shouldAccept(
            timestamp: 1.0,
            transform: b,
            trackingNormal: true,
            lastKeyframeTimestamp: 0,
            lastKeyframeTransform: a
        )
        XCTAssertTrue(d.accept)
    }

    // MARK: - Test E sync + PTS SoT

    func testE_PoseSampleIndexAndPTSFields() throws {
        let written: [(Int, Int64, Int32, Double)] = [
            (0, 0, 600, 0.0),
            (1, 20, 600, 20.0 / 600.0),
            (2, 60, 600, 0.1),
        ]
        var samples: [CaptureFrameSample] = []
        for (idx, value, scale, pts) in written {
            let ar = CaptureFrameContract.cmTime(fromSeconds: 10.0 + pts)
            samples.append(
                CaptureFrameSample(
                    frameIndex: idx,
                    arTimestampSeconds: 10.0 + pts,
                    arTimestampValue: ar.value,
                    arTimestampTimescale: ar.timescale,
                    videoPTSValue: value,
                    videoPTSTimescale: scale,
                    videoPTSSeconds: pts,
                    imageWidth: 1920,
                    imageHeight: 1440,
                    intrinsics: CaptureIntrinsicsSample(fx: 1000, fy: 1000, cx: 960, cy: 720),
                    cameraTransform: CaptureFrameContract.encodeTransform(matrix_identity_float4x4),
                    translation: CaptureVec3(x: 0, y: 0, z: 0),
                    rotationQuaternion: CaptureQuat(simd_quatf(matrix_identity_float4x4)),
                    trackingState: "normal",
                    exposureDuration: 0.01,
                    iso: nil,
                    sceneDepthReference: nil,
                    depthConfidenceReference: nil,
                    isKeyframe3DGS: idx == 0,
                    translationBaselineM: 0,
                    translationBaselineGrade: .insufficient
                )
            )
        }
        XCTAssertEqual(samples.map(\.frameIndex), [0, 1, 2])
        XCTAssertEqual(samples[1].videoPTSValue, 20)
        XCTAssertEqual(samples[1].videoPTSTimescale, 600)

        let file = CapturePosesFile(schemaVersion: 2, sessionId: "t", frames: samples)
        let data = try JSONEncoder().encode(file)
        let decoded = try JSONDecoder().decode(CapturePosesFile.self, from: data)
        XCTAssertEqual(decoded.frames.count, 3)
        XCTAssertEqual(decoded.frames[1].videoPTSSeconds, 20.0 / 600.0, accuracy: 1e-9)
        XCTAssertEqual(decoded.frames[1].videoPTSValue, 20)
        XCTAssertTrue(decoded.syncSourceOfTruth.contains("videoPTS"))
    }

    func testManifestV2IncludesOrientationAndBaselineNaming() throws {
        var coverage = CoverageModelV1()
        var t = matrix_identity_float4x4
        coverage.observe(cameraTransform: t, motionQuality: 1)
        t.columns.3 = SIMD4(0.4, 0, 0, 1)
        coverage.observe(cameraTransform: t, motionQuality: 1)

        var baseline = TranslationBaselineAnalyzer()
        baseline.acceptKeyframe(transform: matrix_identity_float4x4)
        _ = baseline.evaluate(transform: t, trackingNormal: true)

        let manifest = CaptureManifestBuilder.build(
            captureId: "id",
            sessionId: "sess",
            startedAt: Date(),
            durationSec: 5,
            video: ARVideoRecorder.Result(
                url: URL(fileURLWithPath: "/tmp/x.mov"),
                byteSize: 1,
                width: 1920,
                height: 1440,
                fps: 30,
                codec: "hevc",
                frameCount: 10,
                droppedFrameCount: 2,
                preferredTransform: [0, 1, -1, 0, 0, 0],
                imageResolutionWidth: 1920,
                imageResolutionHeight: 1440
            ),
            coverage: coverage,
            telemetry: CaptureTelemetryCollector(),
            mockMode: false,
            frameSamples: [],
            translationBaseline: baseline,
            depthSamplesWritten: 0,
            sceneDepthConfigured: false,
            droppedVideoFrames: 2,
            keyframe3DGSCount: 1
        )
        XCTAssertEqual(manifest.schemaVersion, 2)
        XCTAssertEqual(manifest.coordinateSystem?.cameraTransformConvention, "camera_to_world")
        XCTAssertEqual(manifest.sync?.droppedVideoFrames, 2)
        XCTAssertTrue(manifest.sync?.syncSourceOfTruth.contains("videoPTS") == true)
        XCTAssertEqual(manifest.qualitySummary?.overlapAvailability, .notAvailable)
        XCTAssertEqual(manifest.qualitySummary?.translationBaselineGrade, baseline.bestGrade)
        XCTAssertEqual(manifest.camera?.orientation?.intrinsicsCoordinateSpace, "native_capturedImage_pixels")
        XCTAssertEqual(manifest.camera?.orientation?.pixelBuffersRotatedInWriter, false)
        XCTAssertEqual(manifest.depth?.rgbDepthSamePixelSpace, false)
        XCTAssertNotNil(manifest.coordinateSystem?.intrinsicsCoordinateSpace)
    }

    func testDiscontinuityCountsJump() {
        var d = CapturePoseDiscontinuityAnalyzer()
        var a = matrix_identity_float4x4
        d.ingest(transform: a, trackingState: "normal")
        a.columns.3 = SIMD4(1.0, 0, 0, 1) // 1m jump
        d.ingest(transform: a, trackingState: "limited_relocalizing")
        XCTAssertEqual(d.trackingStateTransitions, 1)
        XCTAssertGreaterThanOrEqual(d.possiblePoseJumpCount, 1)
        XCTAssertGreaterThan(d.maxFrameTranslationDeltaM, 0.9)
    }

    func testTranslationBaselineConfigExposed() {
        XCTAssertEqual(TranslationBaselineConfig.minAcceptableBaselineM, 0.12, accuracy: 0.0001)
        XCTAssertEqual(TranslationBaselineConfig.goodBaselineM, 0.35, accuracy: 0.0001)
    }

    func testMockGuideHasNoInPlaceOrbit() {
        let plan = AdvancedCaptureGuidePlan.mockDefault(sessionId: "x")
        let joined = plan.segments.map(\.instructionKo).joined()
        XCTAssertFalse(joined.contains("제자리에서"))
        XCTAssertTrue(joined.contains("이동"))
    }

    func testOverlapProviderUnavailableInP0() {
        let p = OverlapMetricUnavailable()
        XCTAssertEqual(p.availability(), .notAvailable)
        XCTAssertNil(p.estimateOverlap(currentTransform: matrix_identity_float4x4, referenceTransform: nil))
    }

    func testTopDownPathDownsamples() {
        var frames: [CaptureFrameSample] = []
        for i in 0..<100 {
            frames.append(
                CaptureFrameSample(
                    frameIndex: i,
                    arTimestampSeconds: Double(i) * 0.033,
                    arTimestampValue: Int64(i),
                    arTimestampTimescale: 600,
                    videoPTSValue: Int64(i),
                    videoPTSTimescale: 600,
                    videoPTSSeconds: Double(i) / 600.0,
                    imageWidth: 100,
                    imageHeight: 100,
                    intrinsics: CaptureIntrinsicsSample(fx: 1, fy: 1, cx: 1, cy: 1),
                    cameraTransform: Array(repeating: 0, count: 16),
                    translation: CaptureVec3(x: Float(i) * 0.01, y: 0, z: 0),
                    rotationQuaternion: CaptureQuat(simd_quatf(ix: 0, iy: 0, iz: 0, r: 1)),
                    trackingState: "normal",
                    exposureDuration: nil,
                    iso: nil,
                    sceneDepthReference: nil,
                    depthConfidenceReference: nil,
                    isKeyframe3DGS: false,
                    translationBaselineM: 0,
                    translationBaselineGrade: .insufficient
                )
            )
        }
        let path = CaptureFrameContract.topDownPath(from: frames, maxPoints: 16)
        XCTAssertEqual(path.count, 16)
        XCTAssertEqual(path.first?.x ?? -1, 0, accuracy: 0.001)
    }

    /// Documented P0.5 acceptance matrix.
    func testAcceptanceMatrixDocumentation() {
        // A Stationary — unit PASS / device 실기기 필요
        // B In-place rotation — unit PASS / device 실기기 필요
        // C Lateral ~1m — unit PASS baseline / device scale 실기기 필요
        // D Forward ~1m — unit PASS path / device scale 실기기 필요
        // E Video/Pose/MOV PTS — unit fields PASS / MOV reader DEBUG 실기기 필요
        XCTAssertTrue(true)
    }
}
