import Foundation
import XCTest
@testable import Gonggi

/// Phase 2A: OpenCV xcframework linked + ObjC++ bridge smoke.
final class OpenCVPanoramaBridgePhase2ATests: XCTestCase {

    func testBridgeIsAvailable() {
        XCTAssertTrue(OpenCVPanoramaBridge.isAvailable())
        XCTAssertTrue(OpenCVPanoramaEngine().isAvailable)
    }

    func testOpenCVVersionPinnedMajorMinor() {
        let version = OpenCVPanoramaBridge.openCVVersionString()
        XCTAssertFalse(version.isEmpty)
        // Pinned Vendor/OpenCV/VERSION = 4.10.0
        XCTAssertTrue(
            version.hasPrefix("4.10"),
            "Expected OpenCV 4.10.x, got \(version)"
        )
        XCTAssertEqual(OpenCVPanoramaEngine.linkedOpenCVVersion, version)
    }

    func testSmokeTestAddViaOpenCVMat() {
        XCTAssertEqual(OpenCVPanoramaBridge.smokeTestAddLeft(40, right: 2), 42)
        XCTAssertEqual(OpenCVPanoramaEngine.smokeTestAdd(-3, 10), 7)
    }

    func testStitchNotYetImplementedReturnsStructuredFailure() async throws {
        // Replaced in Phase 2B/2C — keep smoke + version tests; stitch covered elsewhere.
        XCTAssertTrue(OpenCVPanoramaBridge.isAvailable())
    }

    func testLegacyUnaffectedWhenOpenCVFails() async throws {
        let rgba = [UInt8](repeating: 140, count: 16 * 16 * 4)
        let k = CameraIntrinsics(fx: 10, fy: 10, cx: 8, cy: 8, width: 16, height: 16)
        let kf = PanoramaStitcher.InputKeyframe(
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
        let legacyURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("legacy-phase2a-\(UUID().uuidString).jpg")
        defer { try? FileManager.default.removeItem(at: legacyURL) }

        let input = PanoramaEngineInput(
            sessionId: "phase2a-legacy-\(UUID().uuidString)",
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

        let legacy = try await GonggiLegacyPanoramaEngine().stitch(input: input)
        XCTAssertTrue(legacy.success)
        XCTAssertEqual(legacy.width, 64)
        XCTAssertEqual(legacy.height, 32)
        XCTAssertEqual(PanoramaEngineSelection.productionDefault, .legacy)
        XCTAssertEqual(PanoramaEngineSelection.resolved(), .legacy)
    }

    func testOrientationContractUnchanged() {
        XCTAssertTrue(PanoramaEquirectOrientationContract.isValidResolution(
            width: Quick360Config.outputWidth,
            height: Quick360Config.outputHeight
        ))
        XCTAssertEqual(PanoramaEquirectOrientationContract.forwardU, 0.5, accuracy: 0.0001)
        XCTAssertEqual(PanoramaEquirectOrientationContract.aspectRatio, 2.0, accuracy: 0.0001)
    }
}
