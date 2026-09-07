import CoreMotion
import XCTest
@testable import Gonggi

final class VRLookControllerTests: XCTestCase {
    override func tearDown() {
        VRLookMath.motionYawSign = 1
        VRLookMath.motionPitchSign = 1
        VRMotionPreferences.resetForTesting()
        super.tearDown()
    }

    /// A: relative yaw +90 → final equirect yaw +90
    func testA_RelativeYawPlus90() {
        var look = VRLookComposer()
        look.setMotionLook(yawDeg: 90, pitchDeg: 0)
        XCTAssertEqual(look.finalYawDeg, 90, accuracy: 0.01)
    }

    /// B: relative pitch up → positive equirect pitch
    func testB_RelativePitchUpPositive() {
        var look = VRLookComposer()
        look.setMotionLook(yawDeg: 0, pitchDeg: 30)
        XCTAssertEqual(look.finalPitchDeg, 30, accuracy: 0.01)
        XCTAssertGreaterThan(look.finalPitchDeg, 0)
    }

    /// C: equirect +pitch → camera negative pitch
    func testC_SceneKitMappingEquirectPitchToCamera() {
        let e = VRLookMath.cameraEulerRad(equirectYawDeg: 0, equirectPitchDeg: 40)
        XCTAssertEqual(e.yaw, 0, accuracy: 0.0001)
        XCTAssertLessThan(e.pitch, 0)
        XCTAssertEqual(e.pitch, -40 * .pi / 180, accuracy: 0.0001)
        let back = VRLookMath.equirectFromCameraEulerRad(cameraYawRad: e.yaw, cameraPitchRad: e.pitch)
        XCTAssertEqual(back.pitchDeg, 40, accuracy: 0.01)
    }

    /// D: touch + motion composition
    func testD_TouchPlusMotionComposition() {
        var look = VRLookComposer()
        look.setMotionLook(yawDeg: 20, pitchDeg: 10)
        look.touchYawOffsetDeg = 15
        look.touchPitchOffsetDeg = -5
        XCTAssertEqual(look.finalYawDeg, 35, accuracy: 0.01)
        XCTAssertEqual(look.finalPitchDeg, 5, accuracy: 0.01)
    }

    /// E: pitch clamp ±85
    func testE_PitchClamp() {
        var look = VRLookComposer()
        look.setMotionLook(yawDeg: 0, pitchDeg: 120)
        XCTAssertEqual(look.finalPitchDeg, 85, accuracy: 0.01)
        look.setMotionLook(yawDeg: 0, pitchDeg: -120)
        XCTAssertEqual(look.finalPitchDeg, -85, accuracy: 0.01)
    }

    /// F: freeze/unfreeze bake keeps visual pose
    func testF_BakeMotionKeepsVisual() {
        var look = VRLookComposer()
        look.baseLookYawDeg = 10
        look.setMotionLook(yawDeg: 25, pitchDeg: 12)
        look.touchYawOffsetDeg = 5
        let beforeYaw = look.finalYawDeg
        let beforePitch = look.finalPitchDeg
        look.bakeMotionIntoBase()
        XCTAssertEqual(look.motionYawDeg, 0, accuracy: 0.001)
        XCTAssertEqual(look.motionPitchDeg, 0, accuracy: 0.001)
        XCTAssertEqual(look.finalYawDeg, beforeYaw, accuracy: 0.01)
        XCTAssertEqual(look.finalPitchDeg, beforePitch, accuracy: 0.01)
        XCTAssertEqual(look.touchYawOffsetDeg, 5, accuracy: 0.01)
    }

    /// G: motion OFF bake keeps visual
    func testG_MotionOffBakeSameAsF() {
        var look = VRLookComposer()
        look.setMotionLook(yawDeg: -40, pitchDeg: 8)
        let y = look.finalYawDeg
        let p = look.finalPitchDeg
        look.bakeMotionIntoBase()
        XCTAssertEqual(look.finalYawDeg, y, accuracy: 0.01)
        XCTAssertEqual(look.finalPitchDeg, p, accuracy: 0.01)
    }

    /// H: motion ON starts relative at zero (composer)
    func testH_MotionOnRelativeStartsZero() {
        var look = VRLookComposer()
        look.baseLookYawDeg = 50
        look.touchYawOffsetDeg = 10
        look.setMotionLook(yawDeg: 33, pitchDeg: 11)
        look.bakeMotionIntoBase()
        look.setMotionLook(yawDeg: 0, pitchDeg: 0)
        XCTAssertEqual(look.motionYawDeg, 0, accuracy: 0.001)
        XCTAssertEqual(look.finalYawDeg, VRLookMath.normalizeYawDeg(50 + 33 + 10), accuracy: 0.02)
    }

    /// I: recenter bakes all, visual stable then relative zero
    func testI_RecenterKeepsVisual() {
        var look = VRLookComposer()
        look.baseLookYawDeg = 12
        look.setMotionLook(yawDeg: 8, pitchDeg: -6)
        look.touchYawOffsetDeg = 4
        look.touchPitchOffsetDeg = 3
        let y = look.finalYawDeg
        let p = look.finalPitchDeg
        look.bakeAllIntoBase()
        XCTAssertEqual(look.finalYawDeg, y, accuracy: 0.01)
        XCTAssertEqual(look.finalPitchDeg, p, accuracy: 0.01)
        XCTAssertEqual(look.touchYawOffsetDeg, 0, accuracy: 0.001)
        XCTAssertEqual(look.motionYawDeg, 0, accuracy: 0.001)
    }

    /// J: fallback uses composed camera euler (= bridge inputs)
    func testJ_ComposedCameraForFallback() {
        var look = VRLookComposer()
        look.baseLookYawDeg = 30
        look.setMotionLook(yawDeg: 15, pitchDeg: 20)
        look.touchYawOffsetDeg = -5
        let cam = look.cameraEulerRad
        let eq = VRSphereEquirectBridge.equirectDegreesFromCamera(
            cameraYawRad: cam.yaw,
            cameraPitchRad: cam.pitch
        )
        XCTAssertEqual(eq.yawDeg, look.finalYawDeg, accuracy: 0.5)
        XCTAssertEqual(eq.pitchDeg, look.finalPitchDeg, accuracy: 0.5)
    }

    func testTouchPanFingerRightIncreasesYaw() {
        var look = VRLookComposer()
        look.applyTouchTranslation(dx: 100, dy: 0)
        XCTAssertGreaterThan(look.touchYawOffsetDeg, 0)
    }

    func testTouchPanFingerDownDecreasesPitch() {
        var look = VRLookComposer()
        look.applyTouchTranslation(dx: 0, dy: 100)
        XCTAssertLessThan(look.touchPitchOffsetDeg, 0)
    }

    func testPreferencesReduceMotionForcesOff() {
        VRMotionPreferences.setMotionEnabled(true)
        XCTAssertFalse(VRMotionPreferences.resolvedMotionEnabled(reduceMotion: true))
        XCTAssertTrue(VRMotionPreferences.resolvedMotionEnabled(reduceMotion: false))
    }

    func testIdentityMatrixGivesNearZeroLook() {
        let m = CMRotationMatrix(
            m11: 1, m12: 0, m13: 0,
            m21: 0, m22: 1, m23: 0,
            m31: 0, m32: 0, m33: 1
        )
        let d = VRLookMath.equirectDeltaFromRelativeRotationMatrix(m)
        XCTAssertEqual(d.yawDeg, 0, accuracy: 0.5)
        XCTAssertEqual(d.pitchDeg, 0, accuracy: 0.5)
    }

    func testEquirectYawEqualsCameraYawBridgeLock() {
        let camYaw: Float = 45 * .pi / 180
        let camPitch: Float = -20 * .pi / 180
        let eq = VRSphereEquirectBridge.equirectDegreesFromCamera(
            cameraYawRad: camYaw,
            cameraPitchRad: camPitch
        )
        XCTAssertEqual(eq.yawDeg, 45, accuracy: 0.01)
        XCTAssertEqual(eq.pitchDeg, 20, accuracy: 0.01)
    }
}
