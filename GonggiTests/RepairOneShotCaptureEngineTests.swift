import XCTest
@testable import Gonggi

/// Manual shutter engine — no auto-align gate; cancel ignores in-flight photo.
final class RepairOneShotCaptureEngineTests: XCTestCase {
    func testManualCaptureDoesNotRequireAlignment() {
        let engine = RepairOneShotCaptureEngine()
        engine.targetEquirectYawDeg = 90
        engine.targetPitchDeg = 0
        try? engine.prepareCamera(mockMode: true)
        engine.start()

        var captured = false
        engine.onCaptured = { _, _, _, _, _ in captured = true }
        engine.captureNow()
        XCTAssertTrue(captured)
        XCTAssertTrue(engine.didCapture)
    }

    func testCancelIgnoresPendingCaptureGeneration() {
        let engine = RepairOneShotCaptureEngine()
        try? engine.prepareCamera(mockMode: true)
        engine.start()
        engine.cancelPendingPhoto()
        XCTAssertFalse(engine.didCapture)
        XCTAssertNil(engine.capturedImage)
    }

    func testRetakeClearsPreviousCapture() {
        let engine = RepairOneShotCaptureEngine()
        try? engine.prepareCamera(mockMode: true)
        engine.start()
        engine.captureNow()
        XCTAssertTrue(engine.didCapture)
        engine.resetForRetake()
        XCTAssertFalse(engine.didCapture)
        XCTAssertNil(engine.capturedImage)
    }
}
