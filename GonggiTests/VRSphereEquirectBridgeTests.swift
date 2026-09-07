import XCTest
@testable import Gonggi

final class VRSphereEquirectBridgeTests: XCTestCase {

    // MARK: - Cardinal directions (inside-out: equirectYaw = +cameraYaw)

    func testCenterFrontMapsNearZero() {
        let (yaw, pitch) = VRSphereEquirectBridge.equirectDegreesFromCamera(
            cameraYawRad: 0,
            cameraPitchRad: 0
        )
        XCTAssertEqual(yaw, 0, accuracy: 0.01)
        XCTAssertEqual(pitch, 0, accuracy: 0.01)
    }

    func testRightSidePositiveEquirectYaw() {
        // Finger-right increases camera yaw → +equirect (right-positive) with inside-out −X.
        let (yaw, _) = VRSphereEquirectBridge.equirectDegreesFromCamera(
            cameraYawRad: .pi / 2,
            cameraPitchRad: 0
        )
        XCTAssertEqual(yaw, 90, accuracy: 0.5)
    }

    func testLeftSideNegativeEquirectYaw() {
        let (yaw, _) = VRSphereEquirectBridge.equirectDegreesFromCamera(
            cameraYawRad: -.pi / 2,
            cameraPitchRad: 0
        )
        XCTAssertEqual(yaw, -90, accuracy: 0.5)
    }

    func testBackNearSeam() {
        let (yaw, _) = VRSphereEquirectBridge.equirectDegreesFromCamera(
            cameraYawRad: .pi,
            cameraPitchRad: 0
        )
        XCTAssertEqual(abs(yaw), 180, accuracy: 0.5)
    }

    func testBackNegativeSeam() {
        let (yaw, _) = VRSphereEquirectBridge.equirectDegreesFromCamera(
            cameraYawRad: -.pi,
            cameraPitchRad: 0
        )
        XCTAssertEqual(abs(yaw), 180, accuracy: 0.5)
    }

    func testUpperPositivePitch() {
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

    // MARK: - Texture UV canonical

    func testTextureUVCenterIsFront() {
        let (yaw, pitch) = VRSphereEquirectBridge.equirectDegreesFromTextureUV(u: 0.5, v: 0.5)
        XCTAssertEqual(yaw, 0, accuracy: 0.01)
        XCTAssertEqual(pitch, 0, accuracy: 0.01)
    }

    func testTextureUVRightIsPlus90() {
        let (yaw, _) = VRSphereEquirectBridge.equirectDegreesFromTextureUV(u: 0.75, v: 0.5)
        XCTAssertEqual(yaw, 90, accuracy: 0.01)
    }

    func testTextureUVLeftIsMinus90() {
        let (yaw, _) = VRSphereEquirectBridge.equirectDegreesFromTextureUV(u: 0.25, v: 0.5)
        XCTAssertEqual(yaw, -90, accuracy: 0.01)
    }

    func testTextureUVRoundTrip() {
        for yaw in stride(from: Float(-180), through: 180, by: 45) {
            for pitch in stride(from: Float(-60), through: 60, by: 30) {
                let uv = VRSphereEquirectBridge.textureUVFromEquirectDegrees(yawDeg: yaw, pitchDeg: pitch)
                let back = VRSphereEquirectBridge.equirectDegreesFromTextureUV(u: uv.u, v: uv.v)
                let dy = abs(VRSphereEquirectBridge.shortestDeltaDeg(from: back.yawDeg, to: yaw))
                XCTAssertLessThan(dy, 0.05, "yaw round-trip failed for \(yaw)")
                XCTAssertEqual(back.pitchDeg, pitch, accuracy: 0.05)
            }
        }
    }

    func testPixelXToYawMatchesBackendFormula() {
        // front center
        XCTAssertEqual(
            VRSphereEquirectBridge.yawDegFromEquirectPixelX(x: 1919.5, width: 3840),
            0,
            accuracy: Float(0.05)
        )
        // right
        let rightX: Float = (0.75 * 3840) - 0.5
        XCTAssertEqual(
            VRSphereEquirectBridge.yawDegFromEquirectPixelX(x: rightX, width: 3840),
            90,
            accuracy: Float(0.2)
        )
    }

    // MARK: - Inside-out sphere points

    func testInsideOutFrontPointOnNegZ() {
        let p = VRSphereEquirectBridge.insideOutSpherePoint(yawDeg: 0, pitchDeg: 0, radius: 10)
        XCTAssertEqual(p.x, 0, accuracy: 1e-4)
        XCTAssertEqual(p.y, 0, accuracy: 1e-4)
        XCTAssertEqual(p.z, -10, accuracy: 1e-4)
    }

    func testInsideOutRightPointOnPlusX() {
        let p = VRSphereEquirectBridge.insideOutSpherePoint(yawDeg: 90, pitchDeg: 0, radius: 10)
        XCTAssertEqual(p.x, 10, accuracy: 1e-3)
        XCTAssertEqual(p.z, 0, accuracy: 1e-3)
    }

    func testInsideOutLeftPointOnMinusX() {
        let p = VRSphereEquirectBridge.insideOutSpherePoint(yawDeg: -90, pitchDeg: 0, radius: 10)
        XCTAssertEqual(p.x, -10, accuracy: 1e-3)
        XCTAssertEqual(p.z, 0, accuracy: 1e-3)
    }

    /// Old unscaled optical marker used negate; that put +90° on −X — must not regress.
    func testInsideOutDoesNotUseOpticalNegateForRight() {
        let p = VRSphereEquirectBridge.insideOutSpherePoint(yawDeg: 90, pitchDeg: 0, radius: 10)
        XCTAssertGreaterThan(p.x, 5, "right equirect must sit on +X after inside-out")
    }

    // MARK: - Capture pose (same convention as backend)

    func testIosCaptureYawNegatesEquirect() {
        XCTAssertEqual(VRSphereEquirectBridge.iosCaptureYaw(fromEquirectYawDeg: 90), -90, accuracy: 0.01)
        XCTAssertEqual(VRSphereEquirectBridge.iosCaptureYaw(fromEquirectYawDeg: 0), 0, accuracy: 0.01)
        XCTAssertEqual(VRSphereEquirectBridge.iosCaptureYaw(fromEquirectYawDeg: 126.73), -126.73, accuracy: 0.01)
    }

    func testNoDoubleNegateOnCaptureBridge() {
        // equirect → ios → (backend) iosYawToProjectionYaw = negate again → original.
        let equirect: Float = 126.73
        let ios = VRSphereEquirectBridge.iosCaptureYaw(fromEquirectYawDeg: equirect)
        let back = VRSphereEquirectBridge.normalizeYawDeg(-ios) // mirrors backend iosYawToProjectionYaw
        XCTAssertEqual(back, equirect, accuracy: 0.01)
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

    func testScreenRightIncreasesEquirectYaw() {
        let size = CGSize(width: 390, height: 844)
        let (yaw, _) = VRSphereEquirectBridge.equirectDegreesFromScreenPoint(
            point: CGPoint(x: 350, y: 422),
            viewSize: size,
            cameraYawRad: 0,
            cameraPitchRad: 0
        )
        XCTAssertGreaterThan(yaw, 5)
    }

    func testSoftWarnDoesNotTriggerNearTarget() {
        XCTAssertFalse(VRSphereEquirectBridge.shouldSoftWarnMisalignment(yawDeltaDeg: 10, pitchDeltaDeg: 8))
        XCTAssertFalse(VRSphereEquirectBridge.shouldSoftWarnMisalignment(yawDeltaDeg: 35, pitchDeltaDeg: 28))
    }

    func testSoftWarnTriggersFarFromTarget() {
        XCTAssertTrue(VRSphereEquirectBridge.shouldSoftWarnMisalignment(yawDeltaDeg: 36, pitchDeltaDeg: 0))
        XCTAssertTrue(VRSphereEquirectBridge.shouldSoftWarnMisalignment(yawDeltaDeg: 0, pitchDeltaDeg: 29))
        XCTAssertTrue(VRSphereEquirectBridge.shouldSoftWarnMisalignment(yawDeltaDeg: -40, pitchDeltaDeg: -30))
    }

    // MARK: - Doorway forensic fixture

    func testDoorwayPixelYawMatchesExpected() {
        let yaw = VRSphereEquirectBridge.yawDegFromEquirectPixelX(
            x: GonggiRepairCoordinateFixtures.doorwayPixelX,
            width: GonggiRepairCoordinateFixtures.equirectWidth
        )
        XCTAssertEqual(yaw, GonggiRepairCoordinateFixtures.doorwayExpectedYawDeg, accuracy: 0.5)
    }

    func testDoorwayCameraMapsToDoorwayNotTV() {
        let doorway = GonggiRepairCoordinateFixtures.doorwayExpectedYawDeg
        let (yaw, _) = VRSphereEquirectBridge.equirectDegreesFromCamera(
            cameraYawRad: doorway * .pi / 180,
            cameraPitchRad: 0
        )
        XCTAssertEqual(yaw, doorway, accuracy: 1)

        let deltaToBug = abs(
            VRSphereEquirectBridge.shortestDeltaDeg(
                from: yaw,
                to: GonggiRepairCoordinateFixtures.buggyRecordedTargetYawDeg
            )
        )
        XCTAssertGreaterThan(deltaToBug, 90, "must not land near old TV target −32.6°")

        let deltaToTV = abs(
            VRSphereEquirectBridge.shortestDeltaDeg(
                from: yaw,
                to: GonggiRepairCoordinateFixtures.tvRegionYawDeg
            )
        )
        XCTAssertGreaterThan(deltaToTV, 90)
    }

    func testDoorwayUVMapsNearExpectedYaw() {
        let u = GonggiRepairCoordinateFixtures.doorwayPixelX
            / GonggiRepairCoordinateFixtures.equirectWidth
        let (yaw, _) = VRSphereEquirectBridge.equirectDegreesFromTextureUV(u: u, v: 0.5)
        // pixel-center formula uses +0.5; uv from x/width is close within ~0.05°.
        XCTAssertEqual(yaw, GonggiRepairCoordinateFixtures.doorwayExpectedYawDeg, accuracy: 0.2)
    }

    func testOldNegateBridgeWouldFailDoorwayFixture() {
        let doorway = GonggiRepairCoordinateFixtures.doorwayExpectedYawDeg
        let oldBuggy = VRSphereEquirectBridge.normalizeYawDeg(-doorway)
        // Old inside-out-unaware negate: looking at doorway reports opposite sign.
        XCTAssertEqual(oldBuggy, -doorway, accuracy: 0.01)
        let deltaToExpected = abs(VRSphereEquirectBridge.shortestDeltaDeg(from: oldBuggy, to: doorway))
        XCTAssertGreaterThan(deltaToExpected, 90)
    }

    func testForensicBugPlus180NearWoodPeak() {
        // Diagnosis note: buggy −32.6° + 180° ≈ +147° (wood-slat peak cluster).
        let flipped = VRSphereEquirectBridge.normalizeYawDeg(
            GonggiRepairCoordinateFixtures.buggyRecordedTargetYawDeg + 180
        )
        XCTAssertEqual(flipped, 147.399, accuracy: 0.5)
        let deltaToDoor = abs(
            VRSphereEquirectBridge.shortestDeltaDeg(
                from: flipped,
                to: GonggiRepairCoordinateFixtures.doorwayExpectedYawDeg
            )
        )
        XCTAssertLessThan(deltaToDoor, 25, "180° flip of bug lands near doorway wood")
    }

    func testMaskOutlineSamplesCloseEllipse() {
        let pts = VRSphereEquirectBridge.maskOutlineEquirectPoints(
            centerYawDeg: 126.7,
            centerPitchDeg: 0,
            radiusYawDeg: 20,
            radiusPitchDeg: 15,
            samples: 48
        )
        XCTAssertEqual(pts.count, 48)
        let maxYawDelta = pts.map {
            abs(VRSphereEquirectBridge.shortestDeltaDeg(from: 126.7, to: $0.yawDeg))
        }.max() ?? 0
        XCTAssertEqual(maxYawDelta, 20, accuracy: 0.5)
    }

    func testMatchesSphericalMathFrontUV() {
        let uv = SphericalMath.equirectangularUV(yawRad: 0, pitchRad: 0)
        let (yaw, pitch) = VRSphereEquirectBridge.equirectDegreesFromTextureUV(u: uv.x, v: uv.y)
        XCTAssertEqual(yaw, 0, accuracy: 0.01)
        XCTAssertEqual(pitch, 0, accuracy: 0.01)
    }
}
