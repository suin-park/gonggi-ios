import Foundation
import simd
import XCTest
@testable import Gonggi

final class PanoramaEnginePhase1Tests: XCTestCase {

    private func makeTinyKeyframes() -> [PanoramaStitcher.InputKeyframe] {
        let rgba = [UInt8](repeating: 140, count: 16 * 16 * 4)
        let k = CameraIntrinsics(fx: 10, fy: 10, cx: 8, cy: 8, width: 16, height: 16)
        let a = PanoramaStitcher.InputKeyframe(
            index: 0,
            rgba: rgba,
            width: 16,
            height: 16,
            cameraTransform: matrix_identity_float4x4,
            intrinsics: k,
            dynamicRatio: 0,
            yawRad: 0,
            pitchRad: 0
        )
        var cam = matrix_identity_float4x4
        let t: Float = 0.4
        cam.columns.0 = SIMD4(cos(t), 0, -sin(t), 0)
        cam.columns.2 = SIMD4(sin(t), 0, cos(t), 0)
        let b = PanoramaStitcher.InputKeyframe(
            index: 1,
            rgba: rgba,
            width: 16,
            height: 16,
            cameraTransform: cam,
            intrinsics: k,
            dynamicRatio: 0,
            yawRad: t,
            pitchRad: 0
        )
        return [a, b]
    }

    private func tempPanoramaURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("engine-phase1-\(UUID().uuidString).jpg")
    }

    private func makeInput(
        keyframes: [PanoramaStitcher.InputKeyframe],
        outURL: URL,
        width: Int = 64,
        height: Int = 32
    ) -> PanoramaEngineInput {
        PanoramaEngineInput(
            sessionId: "phase1-\(UUID().uuidString)",
            keyframes: keyframes,
            originTransform: matrix_identity_float4x4,
            captureBasis: Quick360CaptureBasis.make(fromStartCamera: matrix_identity_float4x4),
            selectedKeyframeMeta: [],
            targets: [],
            coverageReport: nil,
            outputWidth: width,
            outputHeight: height,
            outputPanoramaURL: outURL
        )
    }

    func testLegacyWrapperMatchesDirectStitcher() async throws {
        let keyframes = makeTinyKeyframes()
        let origin = matrix_identity_float4x4
        let basis = Quick360CaptureBasis.make(fromStartCamera: origin)
        let w = 64
        let h = 32

        let direct = PanoramaStitcher.stitch(
            keyframes: keyframes,
            originTransform: origin,
            captureBasis: basis,
            outWidth: w,
            outHeight: h
        )

        let url = tempPanoramaURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let out = try await GonggiLegacyPanoramaEngine().stitch(
            input: makeInput(keyframes: keyframes, outURL: url, width: w, height: h)
        )

        XCTAssertTrue(out.success)
        XCTAssertEqual(out.engineIdentifier, PanoramaEngineID.legacy)
        XCTAssertEqual(out.width, direct.width)
        XCTAssertEqual(out.height, direct.height)
        XCTAssertEqual(out.rgba, direct.rgba)
        XCTAssertEqual(out.coverageFlags, direct.coverageFlags)
        XCTAssertEqual(out.stitchOutput?.acceptedKeyframeCount, direct.acceptedKeyframeCount)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        XCTAssertTrue(PanoramaEquirectOrientationContract.isValidResolution(
            width: Quick360Config.outputWidth,
            height: Quick360Config.outputHeight
        ))
    }

    func testEngineInputOutputContract() async throws {
        let url = tempPanoramaURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let input = makeInput(keyframes: makeTinyKeyframes(), outURL: url)
        XCTAssertEqual(input.firstForwardYawRad, 0)
        XCTAssertEqual(input.firstForwardPitchRad, 0)
        XCTAssertEqual(input.outputWidth, 64)
        XCTAssertEqual(input.outputHeight, 32)

        let out = try await GonggiLegacyPanoramaEngine().stitch(input: input)
        XCTAssertTrue(out.success)
        XCTAssertNotNil(out.panoramaURL)
        XCTAssertNotNil(out.report.finalResolution)
        XCTAssertEqual(out.report.engine, PanoramaEngineID.legacy)
        XCTAssertGreaterThan(out.report.processingTimeMs, 0)
        XCTAssertNil(out.report.seamMetric) // Phase 1 nullable
    }

    func testFirstForwardOrientationContract() {
        let uv = SphericalMath.equirectangularUV(yawRad: 0, pitchRad: 0)
        XCTAssertEqual(uv.x, PanoramaEquirectOrientationContract.forwardU, accuracy: 1e-5)
        XCTAssertEqual(uv.y, 0.5, accuracy: 1e-5)

        let top = SphericalMath.equirectangularUV(yawRad: 0, pitchRad: .pi / 2)
        XCTAssertLessThan(top.y, 0.1)

        let bottom = SphericalMath.equirectangularUV(yawRad: 0, pitchRad: -.pi / 2)
        XCTAssertGreaterThan(bottom.y, 0.9)

        let px = PanoramaEquirectOrientationContract.forwardPixel()
        XCTAssertEqual(px.x, Int((0.5 * Float(4095)).rounded()))
        XCTAssertEqual(px.y, 1024)

        // Viewer must not apply ±90° / mirror — prepare is identity.
        XCTAssertEqual(
            Quick360SphereCoordinateConvention.insideOutScale,
            SIMD3<Float>(-1, 1, 1)
        )
    }

    func testEquirect4096x2048Contract() {
        XCTAssertEqual(PanoramaEquirectOrientationContract.defaultWidth, 4096)
        XCTAssertEqual(PanoramaEquirectOrientationContract.defaultHeight, 2048)
        XCTAssertEqual(PanoramaEquirectOrientationContract.aspectRatio, 2.0)
        XCTAssertTrue(PanoramaEquirectOrientationContract.isValidResolution(width: 4096, height: 2048))
        XCTAssertFalse(PanoramaEquirectOrientationContract.isValidResolution(width: 2048, height: 2048))
        XCTAssertEqual(Quick360Config.outputWidth, 4096)
        XCTAssertEqual(Quick360Config.outputHeight, 2048)
    }

    func testABDirectoryAndReportGeneration() throws {
        let sessionId = "ab-phase1-\(UUID().uuidString)"
        defer { CaptureSessionStore.deleteSession(sessionId: sessionId) }

        let legacyURL = tempPanoramaURL()
        defer { try? FileManager.default.removeItem(at: legacyURL) }
        let mock = PanoramaStitcher.mockPanorama(width: 32, height: 16)
        try PanoramaExporter.writeJPEG(
            rgba: mock.rgba,
            width: mock.width,
            height: mock.height,
            to: legacyURL
        )

        let legacy = PanoramaEngineOutput(
            engineIdentifier: PanoramaEngineID.legacy,
            success: true,
            panoramaURL: legacyURL,
            width: mock.width,
            height: mock.height,
            rgba: mock.rgba,
            coverageFlags: mock.coverageFlags,
            processingTimeSec: 0.01,
            stitchOutput: mock,
            failureReason: nil,
            report: PanoramaEngineRunReport(
                engine: PanoramaEngineID.legacy,
                success: true,
                finalResolution: "32x16",
                selectedKeyframeCount: 2,
                processingTimeMs: 10,
                peakMemoryMB: 1.2,
                coveragePercent: 100,
                seamMetric: nil,
                alignmentRefinementSuccess: false,
                visualRefinementAttempts: 0,
                successfulRefinements: 0,
                fallbackCount: 0,
                highParallaxCount: 0,
                outputFilePath: legacyURL.path,
                failureReason: nil
            )
        )
        let openCV = PanoramaEngineOutput.failure(
            engine: PanoramaEngineID.openCV,
            reason: "OpenCV panorama engine not linked (Phase 1 stub)"
        )

        try PanoramaABTestWriter.write(sessionId: sessionId, legacy: legacy, openCV: openCV)

        let dir = try PanoramaABPaths.directory(sessionId: sessionId)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: dir.appendingPathComponent(PanoramaABPaths.legacyPanorama).path
        ))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: dir.appendingPathComponent(PanoramaABPaths.openCVPanorama).path
        ))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: dir.appendingPathComponent(PanoramaABPaths.legacyReport).path
        ))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: dir.appendingPathComponent(PanoramaABPaths.openCVReport).path
        ))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: dir.appendingPathComponent(PanoramaABPaths.abReport).path
        ))

        let data = try Data(contentsOf: dir.appendingPathComponent(PanoramaABPaths.abReport))
        let ab = try JSONDecoder().decode(PanoramaABComparisonReport.self, from: data)
        XCTAssertEqual(ab.sessionId, sessionId)
        XCTAssertTrue(ab.legacy.success)
        XCTAssertFalse(ab.openCV.success)
        XCTAssertNil(ab.legacy.seamMetric)
        XCTAssertNil(ab.openCV.peakMemoryMB)
    }

    func testOpenCVBridgeAvailableButStitchDeferredGraceful() async throws {
        let url = tempPanoramaURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let engine = OpenCVPanoramaEngine()
        // Phase 2A: xcframework + bridge linked; full stitch is Phase 2B/2C.
        XCTAssertTrue(engine.isAvailable)
        XCTAssertEqual(engine.identifier, PanoramaEngineID.openCV)

        let out = try await engine.stitch(input: makeInput(keyframes: makeTinyKeyframes(), outURL: url))
        XCTAssertFalse(out.success)
        XCTAssertNil(out.panoramaURL)
        XCTAssertNil(out.rgba)
        XCTAssertNotNil(out.failureReason)
        XCTAssertEqual(out.report.engine, PanoramaEngineID.openCV)
        XCTAssertFalse(out.report.success)
    }

    func testReleaseDefaultEngineIsLegacy() {
        XCTAssertEqual(PanoramaEngineSelection.productionDefault, .legacy)
        XCTAssertEqual(PanoramaEngineSelection.resolved(), .legacy)

        #if DEBUG
        PanoramaEngineSelection.debugOverride = .openCV
        XCTAssertEqual(PanoramaEngineSelection.resolved(), .openCV)
        PanoramaEngineSelection.debugOverride = .abCompare
        XCTAssertEqual(PanoramaEngineSelection.resolved(), .abCompare)
        PanoramaEngineSelection.debugOverride = nil
        XCTAssertEqual(PanoramaEngineSelection.resolved(), .legacy)
        #endif

        let primary = PanoramaEngineSelection.legacy.makePrimaryEngine()
        XCTAssertEqual(primary.identifier, PanoramaEngineID.legacy)
    }

    func testOpenCVBridgeBoundaryIsPODOnly() {
        let req = OpenCVPanoramaBridgeContract.PlannedRequest(
            keyframeJPEGPaths: ["/tmp/a.jpg"],
            rotationsRowMajor9: [[Float](repeating: 0, count: 9)],
            fx: [500],
            fy: [500],
            cx: [320],
            cy: [240],
            imageWidths: [640],
            imageHeights: [480],
            outputPath: "/tmp/out.jpg",
            outputWidth: 4096,
            outputHeight: 2048,
            firstForwardYawDeg: 0,
            firstForwardPitchDeg: 0
        )
        XCTAssertEqual(req.outputWidth, 4096)
        XCTAssertEqual(req.outputHeight, 2048)
        XCTAssertFalse(OpenCVPanoramaBridgeContract.documentedBoundary.isEmpty)
    }

    func testRunSelectedEngineABUsesLegacyOutput() async throws {
        let sessionId = "ab-run-\(UUID().uuidString)"
        defer { CaptureSessionStore.deleteSession(sessionId: sessionId) }
        let url = try CaptureSessionStore.quick360EquirectangularURL(sessionId: sessionId)
        let input = PanoramaEngineInput(
            sessionId: sessionId,
            keyframes: makeTinyKeyframes(),
            originTransform: matrix_identity_float4x4,
            captureBasis: nil,
            selectedKeyframeMeta: [],
            targets: [],
            coverageReport: nil,
            outputWidth: 64,
            outputHeight: 32,
            outputPanoramaURL: url
        )
        let stitch = try await Quick360Reconstruction.runSelectedEngine(
            input: input,
            selection: .abCompare
        )
        XCTAssertEqual(stitch.width, 64)
        XCTAssertEqual(stitch.height, 32)
        let dir = try PanoramaABPaths.directory(sessionId: sessionId)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: dir.appendingPathComponent(PanoramaABPaths.abReport).path
        ))
    }
}
