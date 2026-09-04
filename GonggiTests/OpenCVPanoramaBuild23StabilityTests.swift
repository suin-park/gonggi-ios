import Foundation
import simd
import XCTest
@testable import Gonggi

/// Build 23 — OpenCV memory / exception stabilization contracts.
final class OpenCVPanoramaBuild23StabilityTests: XCTestCase {

    private func solidRGBA(width: Int, height: Int, rgb: (UInt8, UInt8, UInt8)) -> [UInt8] {
        var out = [UInt8](repeating: 255, count: width * height * 4)
        for i in 0..<(width * height) {
            out[i * 4] = rgb.0
            out[i * 4 + 1] = rgb.1
            out[i * 4 + 2] = rgb.2
        }
        return out
    }

    func testOrientationAnd4KContractUnchanged() {
        XCTAssertEqual(Quick360Config.outputWidth, 4096)
        XCTAssertEqual(Quick360Config.outputHeight, 2048)
        XCTAssertTrue(PanoramaEquirectOrientationContract.isValidResolution(
            width: 4096, height: 2048
        ))
        XCTAssertEqual(PanoramaEquirectOrientationContract.forwardU, 0.5, accuracy: 1e-5)
        XCTAssertEqual(PanoramaEngineSelection.productionDefault, .legacy)
    }

    func testEmptyKeyframesStructuredFailureNoCrash() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("b23-empty-\(UUID().uuidString).jpg")
        defer { try? FileManager.default.removeItem(at: url) }
        let input = PanoramaEngineInput(
            sessionId: "b23-empty-\(UUID().uuidString)",
            keyframes: [],
            originTransform: matrix_identity_float4x4,
            captureBasis: nil,
            selectedKeyframeMeta: [],
            targets: [],
            coverageReport: nil,
            outputWidth: 512,
            outputHeight: 256,
            outputPanoramaURL: url
        )
        let out = try await OpenCVPanoramaEngine().stitch(input: input)
        XCTAssertFalse(out.success)
        XCTAssertNotNil(out.failureReason)
        XCTAssertEqual(out.report.engine, PanoramaEngineID.openCV)
    }

    func testInvalidAspectStructuredFailure() async throws {
        let rgba = solidRGBA(width: 16, height: 16, rgb: (128, 128, 128))
        let k = CameraIntrinsics(fx: 10, fy: 10, cx: 8, cy: 8, width: 16, height: 16)
        let kf = PanoramaStitcher.InputKeyframe(
            index: 0,
            rgba: rgba,
            width: 16,
            height: 16,
            cameraTransform: matrix_identity_float4x4,
            intrinsics: k,
            dynamicRatio: 0
        )
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("b23-aspect-\(UUID().uuidString).jpg")
        defer { try? FileManager.default.removeItem(at: url) }
        // Non 2:1 — reconstructor must fail structured, not crash.
        let input = PanoramaEngineInput(
            sessionId: "b23-aspect-\(UUID().uuidString)",
            keyframes: [kf],
            originTransform: matrix_identity_float4x4,
            captureBasis: Quick360CaptureBasis.make(fromStartCamera: matrix_identity_float4x4),
            selectedKeyframeMeta: [],
            targets: [],
            coverageReport: nil,
            outputWidth: 300,
            outputHeight: 200,
            outputPanoramaURL: url
        )
        let out = try await OpenCVPanoramaEngine().stitch(input: input)
        XCTAssertFalse(out.success)
        XCTAssertNotNil(out.failureReason)
    }

    func testOpenCVFailureLeavesLegacyValid() async throws {
        let rgba = solidRGBA(width: 16, height: 16, rgb: (140, 140, 140))
        let k = CameraIntrinsics(fx: 10, fy: 10, cx: 8, cy: 8, width: 16, height: 16)
        let kf = PanoramaStitcher.InputKeyframe(
            index: 0,
            rgba: rgba,
            width: 16,
            height: 16,
            cameraTransform: matrix_identity_float4x4,
            intrinsics: k,
            dynamicRatio: 0
        )
        let sessionId = "b23-ab-\(UUID().uuidString)"
        defer { CaptureSessionStore.deleteSession(sessionId: sessionId) }
        let legacyURL = try CaptureSessionStore.quick360EquirectangularURL(sessionId: sessionId)
        let input = PanoramaEngineInput(
            sessionId: sessionId,
            keyframes: [kf],
            originTransform: matrix_identity_float4x4,
            captureBasis: Quick360CaptureBasis.make(fromStartCamera: matrix_identity_float4x4),
            selectedKeyframeMeta: [],
            targets: [],
            coverageReport: nil,
            outputWidth: 64,
            outputHeight: 32,
            outputPanoramaURL: legacyURL
        )
        let stitch = try await Quick360Reconstruction.runSelectedEngine(
            input: input,
            selection: .abCompare
        )
        XCTAssertEqual(stitch.width, 64)
        XCTAssertEqual(stitch.height, 32)
        XCTAssertTrue(FileManager.default.fileExists(atPath: legacyURL.path))
        let ab = try PanoramaABPaths.directory(sessionId: sessionId)
            .appendingPathComponent(PanoramaABPaths.abReport)
        XCTAssertTrue(FileManager.default.fileExists(atPath: ab.path))
    }

    func testBridgeSmokeStillWorks() {
        XCTAssertTrue(OpenCVPanoramaBridge.isAvailable())
        XCTAssertEqual(OpenCVPanoramaBridge.smokeTestAddLeft(1, right: 2), 3)
        XCTAssertTrue(OpenCVPanoramaBridge.openCVVersionString().hasPrefix("4.10"))
    }

    /// Architecture: exposure analysis must not require full-res UMat duplicate feed.
    /// When metrics JSON is present after a stitch attempt, mode must be Gain (not BlocksGain).
    func testExposureModePreferenceIsGainNotBlocks() async throws {
        var patterned = solidRGBA(width: 32, height: 24, rgb: (100, 100, 100))
        for y in 0..<24 {
            for x in 0..<32 where (x + y) % 4 == 0 {
                let i = (y * 32 + x) * 4
                patterned[i] = 220
                patterned[i + 1] = 40
                patterned[i + 2] = 40
            }
        }
        let k = CameraIntrinsics(fx: 20, fy: 20, cx: 16, cy: 12, width: 32, height: 24)
        let kf = PanoramaStitcher.InputKeyframe(
            index: 0,
            rgba: patterned,
            width: 32,
            height: 24,
            cameraTransform: matrix_identity_float4x4,
            intrinsics: k,
            dynamicRatio: 0,
            yawRad: 0,
            pitchRad: 0
        )
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("b23-gain-\(UUID().uuidString).jpg")
        defer { try? FileManager.default.removeItem(at: url) }
        let input = PanoramaEngineInput(
            sessionId: "b23-gain-\(UUID().uuidString)",
            keyframes: [kf],
            originTransform: matrix_identity_float4x4,
            captureBasis: Quick360CaptureBasis.make(fromStartCamera: matrix_identity_float4x4),
            selectedKeyframeMeta: [],
            targets: [],
            coverageReport: nil,
            outputWidth: 256,
            outputHeight: 128,
            outputPanoramaURL: url
        )
        let out = try await OpenCVPanoramaEngine().stitch(input: input)
        if let json = out.report.openCVMetricsJSON {
            XCTAssertFalse(json.contains("BlocksGain"), "Build 23 must not use BlocksGain: \(json)")
            XCTAssertTrue(
                json.contains("\"exposureMode\":\"Gain\"") || json.contains("Gain"),
                "Expected Gain exposure mode in metrics"
            )
            // Memory telemetry keys present when stitch reached metrics serialization.
            if json.contains("memoryStartMB") {
                XCTAssertTrue(json.contains("memoryBeforeExposureMB"))
                XCTAssertTrue(json.contains("memoryBeforeSeamMB"))
            }
        } else if !out.success {
            XCTAssertNotNil(out.failureReason)
        }
    }
}
