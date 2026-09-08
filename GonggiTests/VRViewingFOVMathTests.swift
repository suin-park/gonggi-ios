import XCTest
@testable import Gonggi

final class VRViewingFOVMathTests: XCTestCase {
    func testPinchOutDecreasesFOV() {
        let fov = VRViewingFOVMath.fov(startFOV: 70, pinchScale: 2.0)
        XCTAssertEqual(fov, 35, accuracy: 0.01)
    }

    func testPinchInIncreasesFOV() {
        let fov = VRViewingFOVMath.fov(startFOV: 70, pinchScale: 0.5)
        XCTAssertEqual(fov, 82, accuracy: 0.01) // clamped to max
    }

    func testClampBounds() {
        XCTAssertEqual(VRViewingFOVMath.clamp(10), 35, accuracy: 0.01)
        XCTAssertEqual(VRViewingFOVMath.clamp(100), 82, accuracy: 0.01)
        XCTAssertEqual(VRViewingFOVMath.clamp(55), 55, accuracy: 0.01)
    }

    func testBeganBaselineNoDrift() {
        // Same began FOV + scale always yields same result (no cumulative multiply).
        let a = VRViewingFOVMath.fov(startFOV: 60, pinchScale: 1.25)
        let b = VRViewingFOVMath.fov(startFOV: 60, pinchScale: 1.25)
        XCTAssertEqual(a, b, accuracy: 1e-9)
        XCTAssertEqual(a, 48, accuracy: 0.01)
    }

    func testTransitionZoomTargetFromWide() {
        XCTAssertEqual(VRViewingFOVMath.transitionZoomTarget(fromCurrent: 70), 52, accuracy: 0.01)
        XCTAssertEqual(VRViewingFOVMath.transitionZoomTarget(fromCurrent: 60), 52, accuracy: 0.01)
    }

    func testTransitionZoomTargetFromTightDoesNotWiden() {
        XCTAssertEqual(VRViewingFOVMath.transitionZoomTarget(fromCurrent: 40), 40, accuracy: 0.01)
        XCTAssertEqual(VRViewingFOVMath.transitionZoomTarget(fromCurrent: 35), 35, accuracy: 0.01)
    }
}
