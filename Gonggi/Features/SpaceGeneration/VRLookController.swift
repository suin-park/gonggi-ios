import CoreMotion
import Foundation
import simd

/// Pure look math for Build 64 motion-first VR (equirect space).
/// Does not touch `VRSphereEquirectBridge` formulas — only composes look + SceneKit euler.
enum VRLookMath {
    /// Pitch clamp in equirect degrees (±85° ≈ ±1.48 rad legacy clamp).
    static let pitchClampDeg: Float = 85

    /// Legacy pan sensitivity: 0.005 rad / point → degrees / point.
    static let touchDegreesPerPoint: Float = 0.005 * 180 / .pi

    /// Sign flips only — verify on device; do not change bridge.
    static var motionYawSign: Float = 1
    static var motionPitchSign: Float = 1

    static func normalizeYawDeg(_ deg: Float) -> Float {
        var d = deg.truncatingRemainder(dividingBy: 360)
        if d <= -180 { d += 360 }
        if d > 180 { d -= 360 }
        return d
    }

    static func clampPitchDeg(_ deg: Float) -> Float {
        max(-pitchClampDeg, min(pitchClampDeg, deg))
    }

    static func finalYawDeg(base: Float, motion: Float, touch: Float) -> Float {
        normalizeYawDeg(base + motion + touch)
    }

    static func finalPitchDeg(base: Float, motion: Float, touch: Float) -> Float {
        clampPitchDeg(base + motion + touch)
    }

    /// Equirect degrees → SceneKit camera euler (radians). Matches existing bridge:
    /// `equirectYaw = +cameraYaw`, `equirectPitch = -cameraPitch`.
    static func cameraEulerRad(equirectYawDeg: Float, equirectPitchDeg: Float) -> (yaw: Float, pitch: Float) {
        let yaw = equirectYawDeg * .pi / 180
        let pitch = -equirectPitchDeg * .pi / 180
        return (yaw, pitch)
    }

    /// Inverse of `cameraEulerRad` (for tests / fallback sanity).
    static func equirectFromCameraEulerRad(cameraYawRad: Float, cameraPitchRad: Float) -> (yawDeg: Float, pitchDeg: Float) {
        let yawDeg = normalizeYawDeg(cameraYawRad * 180 / .pi)
        let pitchDeg = clampPitchDeg(-cameraPitchRad * 180 / .pi)
        return (yawDeg, pitchDeg)
    }

    /// Relative device rotation → equirect look delta (degrees).
    /// Uses forward vector (−Z in device frame) mapped through `CMRotationMatrix`.
    static func equirectDeltaFromRelativeRotationMatrix(
        _ m: CMRotationMatrix,
        yawSign: Float = motionYawSign,
        pitchSign: Float = motionPitchSign
    ) -> (yawDeg: Float, pitchDeg: Float) {
        // v_ref = R * v_device; look = R * (0,0,-1) = (−m13, −m23, −m33)
        let lx = -Float(m.m13)
        let ly = -Float(m.m23)
        let lz = -Float(m.m33)
        let yawRad = atan2(lx, -lz)
        let horiz = max(1e-6, sqrt(lx * lx + lz * lz))
        let pitchRad = atan2(ly, horiz)
        return (
            normalizeYawDeg(yawSign * yawRad * 180 / .pi),
            clampPitchDeg(pitchSign * pitchRad * 180 / .pi)
        )
    }

    /// Touch pan translation (points) → equirect offset deltas (degrees).
    /// Finger right → +yaw; finger down → −pitch (look down), matching legacy euler path.
    static func touchOffsetDeltaDeg(translationX: CGFloat, translationY: CGFloat) -> (yaw: Float, pitch: Float) {
        let yaw = Float(translationX) * touchDegreesPerPoint
        let pitch = -Float(translationY) * touchDegreesPerPoint
        return (yaw, pitch)
    }
}

/// Mutable look composition for one VR session.
struct VRLookComposer: Equatable {
    var baseLookYawDeg: Float = 0
    var baseLookPitchDeg: Float = 0
    var motionYawDeg: Float = 0
    var motionPitchDeg: Float = 0
    var touchYawOffsetDeg: Float = 0
    var touchPitchOffsetDeg: Float = 0

    var finalYawDeg: Float {
        VRLookMath.finalYawDeg(base: baseLookYawDeg, motion: motionYawDeg, touch: touchYawOffsetDeg)
    }

    var finalPitchDeg: Float {
        VRLookMath.finalPitchDeg(base: baseLookPitchDeg, motion: motionPitchDeg, touch: touchPitchOffsetDeg)
    }

    var cameraEulerRad: (yaw: Float, pitch: Float) {
        VRLookMath.cameraEulerRad(equirectYawDeg: finalYawDeg, equirectPitchDeg: finalPitchDeg)
    }

    /// Bake motion into base and zero motion (visual unchanged). Touch kept.
    mutating func bakeMotionIntoBase() {
        baseLookYawDeg = VRLookMath.normalizeYawDeg(baseLookYawDeg + motionYawDeg)
        baseLookPitchDeg = VRLookMath.clampPitchDeg(baseLookPitchDeg + motionPitchDeg)
        motionYawDeg = 0
        motionPitchDeg = 0
    }

    /// Bake motion + touch into base; zero both (visual unchanged). Useful for recenter tidy.
    mutating func bakeAllIntoBase() {
        baseLookYawDeg = finalYawDeg
        baseLookPitchDeg = finalPitchDeg
        motionYawDeg = 0
        motionPitchDeg = 0
        touchYawOffsetDeg = 0
        touchPitchOffsetDeg = 0
    }

    mutating func applyTouchTranslation(dx: CGFloat, dy: CGFloat) {
        let d = VRLookMath.touchOffsetDeltaDeg(translationX: dx, translationY: dy)
        touchYawOffsetDeg = VRLookMath.normalizeYawDeg(touchYawOffsetDeg + d.yaw)
        let proposed = baseLookPitchDeg + motionPitchDeg + touchPitchOffsetDeg + d.pitch
        let clamped = VRLookMath.clampPitchDeg(proposed)
        touchPitchOffsetDeg = clamped - baseLookPitchDeg - motionPitchDeg
    }

    mutating func setMotionLook(yawDeg: Float, pitchDeg: Float) {
        motionYawDeg = VRLookMath.normalizeYawDeg(yawDeg)
        motionPitchDeg = VRLookMath.clampPitchDeg(pitchDeg)
    }
}

enum VRMotionPreferences {
    static let storageKey = "gonggi.vrMotionEnabled"
    static let motionHintSeenKey = "gonggi.vrMotionHintSeen.v1"

    static let motionHintPrimary = "휴대폰을 움직여 공간을 둘러보세요"
    static let motionHintSecondary = "화면을 밀어 시점을 조정할 수도 있어요"

    /// Resolved default for a new VR session.
    static func resolvedMotionEnabled(
        reduceMotion: Bool,
        defaults: UserDefaults = .standard
    ) -> Bool {
        if reduceMotion { return false }
        if defaults.object(forKey: storageKey) == nil { return true }
        return defaults.bool(forKey: storageKey)
    }

    static func setMotionEnabled(_ enabled: Bool, defaults: UserDefaults = .standard) {
        defaults.set(enabled, forKey: storageKey)
    }

    static func hasSeenMotionHint(defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: motionHintSeenKey)
    }

    static func markMotionHintSeen(defaults: UserDefaults = .standard) {
        defaults.set(true, forKey: motionHintSeenKey)
    }

    static func resetForTesting(defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: storageKey)
        defaults.removeObject(forKey: motionHintSeenKey)
    }
}
