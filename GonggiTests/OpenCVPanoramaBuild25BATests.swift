import Foundation
import simd
import XCTest
@testable import Gonggi

/// Build 25 — BundleAdjusterRay N×N pairwise contract + ARKit fallback safety.
final class OpenCVPanoramaBuild25BATests: XCTestCase {

    func testOrientationAndStreamingContractsStillHold() {
        XCTAssertEqual(Quick360Config.outputWidth, 4096)
        XCTAssertEqual(Quick360Config.outputHeight, 2048)
        XCTAssertEqual(PanoramaEngineSelection.productionDefault, .legacy)
    }

    func testBAContractValid3NoCrash() {
        let r = OpenCVPanoramaBridge.runBAContractTestScenario("valid3")
        XCTAssertTrue(r.success, r.metricsJSON ?? r.errorMessage ?? "nil")
        XCTAssertTrue((r.metricsJSON ?? "").contains("\"baCalled\":true") || (r.metricsJSON ?? "").contains("ok\":true"))
    }

    func testBAContractSparseSkipsSafely() {
        let r = OpenCVPanoramaBridge.runBAContractTestScenario("sparse")
        XCTAssertTrue(r.success, r.metricsJSON ?? r.errorMessage ?? "nil")
        let json = r.metricsJSON ?? ""
        XCTAssertTrue(json.contains("\"baCalled\":false") || json.contains("disconnected") || json.contains("skip"))
    }

    func testBAContractInvalidIdxCaught() {
        let r = OpenCVPanoramaBridge.runBAContractTestScenario("invalidIdx")
        XCTAssertTrue(r.success, r.metricsJSON ?? r.errorMessage ?? "nil")
        let json = r.metricsJSON ?? ""
        XCTAssertTrue(json.contains("\"validationOk\":false") || json.contains("out of range"))
    }

    func testBAContractDisconnectedFallback() {
        let r = OpenCVPanoramaBridge.runBAContractTestScenario("disconnected")
        XCTAssertTrue(r.success, r.metricsJSON ?? r.errorMessage ?? "nil")
        XCTAssertTrue((r.metricsJSON ?? "").contains("\"baCalled\":false"))
    }

    func testBAContractZeroEdgesFallback() {
        let r = OpenCVPanoramaBridge.runBAContractTestScenario("zeroEdges")
        XCTAssertTrue(r.success, r.metricsJSON ?? r.errorMessage ?? "nil")
        XCTAssertTrue((r.metricsJSON ?? "").contains("\"baCalled\":false"))
    }

    func testBAContractLarge40NoCrash() {
        let r = OpenCVPanoramaBridge.runBAContractTestScenario("large40")
        XCTAssertTrue(r.success, r.metricsJSON ?? r.errorMessage ?? "nil")
        let json = r.metricsJSON ?? ""
        XCTAssertTrue(json.contains("\"n\":40"))
        XCTAssertTrue(json.contains("\"pairwiseSize\":1600")) // 40*40
    }

    func testOpenCVFailureLeavesLegacyValid() async throws {
        let rgba = [UInt8](repeating: 140, count: 16 * 16 * 4)
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
        let sessionId = "b25-ab-\(UUID().uuidString)"
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
        XCTAssertTrue(FileManager.default.fileExists(atPath: legacyURL.path))
    }
}
