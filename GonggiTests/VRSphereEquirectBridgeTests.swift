import XCTest
@testable import Gonggi

final class VRSphereEquirectBridgeTests: XCTestCase {
    func testCenterFrontMapsNearZero() {
        let (yaw, pitch) = VRSphereEquirectBridge.equirectDegreesFromCamera(
            cameraYawRad: 0,
            cameraPitchRad: 0
        )
        XCTAssertEqual(yaw, 0, accuracy: 0.01)
        XCTAssertEqual(pitch, 0, accuracy: 0.01)
    }

    func testRightSidePositiveEquirectYaw() {
        // Camera yaw negative (after inside-out negate) → positive equirect (right).
        // cameraYawRad = +π/2 → equirect yaw = -90 (left). So for right, cameraYaw = -π/2.
        let (yaw, _) = VRSphereEquirectBridge.equirectDegreesFromCamera(
            cameraYawRad: -.pi / 2,
            cameraPitchRad: 0
        )
        XCTAssertEqual(yaw, 90, accuracy: 0.5)
    }

    func testBackNearSeam() {
        let (yaw, _) = VRSphereEquirectBridge.equirectDegreesFromCamera(
            cameraYawRad: .pi,
            cameraPitchRad: 0
        )
        XCTAssertEqual(abs(yaw), 180, accuracy: 0.5)
    }

    func testUpperPositivePitch() {
        // Finger-down increases camera pitch; we negate → looking up needs negative camera pitch.
        let (_, pitch) = VRSphereEquirectBridge.equirectDegreesFromCamera(
            cameraYawRad: 0,
            cameraPitchRad: -0.5
        )
        XCTAssertGreaterThan(pitch, 0)
    }

    func testLowerNegativePitch() {
        let (_, pitch) = VRSphereEquirectBridge.equirectDegreesFromCamera(
            cameraYawRad: 0,
            cameraPitchRad: 0.5
        )
        XCTAssertLessThan(pitch, 0)
    }

    func testIosCaptureYawNegatesEquirect() {
        XCTAssertEqual(VRSphereEquirectBridge.iosCaptureYaw(fromEquirectYawDeg: 90), -90, accuracy: 0.01)
        XCTAssertEqual(VRSphereEquirectBridge.iosCaptureYaw(fromEquirectYawDeg: 0), 0, accuracy: 0.01)
    }

    func testScreenCenterMatchesCamera() {
        let size = CGSize(width: 390, height: 844)
        let (yaw, pitch) = VRSphereEquirectBridge.equirectDegreesFromScreenPoint(
            point: CGPoint(x: 195, y: 422),
            viewSize: size,
            cameraYawRad: 0,
            cameraPitchRad: 0
        )
        XCTAssertEqual(yaw, 0, accuracy: 1)
        XCTAssertEqual(pitch, 0, accuracy: 1)
    }
}
