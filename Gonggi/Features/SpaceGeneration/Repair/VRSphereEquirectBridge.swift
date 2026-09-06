import Foundation
import simd

/// Bridge SceneKit VR viewer camera ↔ equirectangular / backend projector convention.
///
/// ## Conventions
/// - **SCNHostView** stores `yaw`/`pitch` radians used as `eulerAngles = (pitch, yaw, 0)`.
/// - Pan: `yaw += dx * sens` (finger right → yaw↑), `pitch += dy * sens` (finger down → pitch↑).
/// - Sphere uses `insideOutScale = (-1, 1, 1)` — horizontal mirror vs optical space.
/// - **Equirect / projector**: front=0, **right-positive**, elevation +up (matches backend).
///
/// Because of inside-out −X, viewer camera yaw is negated when mapping to equirect longitude.
enum VRSphereEquirectBridge {
    static let defaultYawRadiusDeg: Float = 20
    static let defaultPitchRadiusDeg: Float = 15

    /// Normalize to (−180, 180].
    static func normalizeYawDeg(_ deg: Float) -> Float {
        var d = deg.truncatingRemainder(dividingBy: 360)
        if d <= -180 { d += 360 }
        if d > 180 { d -= 360 }
        return d
    }

    /// Map SCNHostView camera angles (radians) at screen center → equirect degrees.
    static func equirectDegreesFromCamera(
        cameraYawRad: Float,
        cameraPitchRad: Float
    ) -> (yawDeg: Float, pitchDeg: Float) {
        let yawDeg = normalizeYawDeg(-cameraYawRad * 180 / .pi)
        // Finger-down increases stored pitch; SceneKit +X rotation looks downward → negate for +elev up.
        let pitchDeg = -cameraPitchRad * 180 / .pi
        return (yawDeg, pitchDeg)
    }

    /// Include off-center long-press using approximate perspective offset (FOV degrees).
    static func equirectDegreesFromScreenPoint(
        point: CGPoint,
        viewSize: CGSize,
        cameraYawRad: Float,
        cameraPitchRad: Float,
        fieldOfViewDeg: Float = 70
    ) -> (yawDeg: Float, pitchDeg: Float) {
        let (baseYaw, basePitch) = equirectDegreesFromCamera(
            cameraYawRad: cameraYawRad,
            cameraPitchRad: cameraPitchRad
        )
        guard viewSize.width > 1, viewSize.height > 1 else {
            return (baseYaw, basePitch)
        }

        let ndcX = Float((point.x / viewSize.width) - 0.5) * 2 // −1…1 left→right
        let ndcY = Float(0.5 - (point.y / viewSize.height)) * 2 // −1…1 bottom→top
        let halfFov = fieldOfViewDeg * .pi / 360
        let aspect = Float(viewSize.width / viewSize.height)
        // Horizontal FOV derived from vertical FOV + aspect (SCNCamera.fieldOfView is vertical by default on iOS).
        let offsetYawDeg = atan(ndcX * aspect * tan(halfFov)) * 180 / .pi
        let offsetPitchDeg = atan(ndcY * tan(halfFov)) * 180 / .pi

        // Screen-right → look toward +equirect yaw (right-positive) after inside-out bridge.
        return (
            normalizeYawDeg(baseYaw + offsetYawDeg),
            max(-89, min(89, basePitch + offsetPitchDeg))
        )
    }

    /// Convert equirect target yaw (right-positive) → iOS capture yaw (right-turn negative) for alignment.
    static func iosCaptureYaw(fromEquirectYawDeg equirectYawDeg: Float) -> Float {
        normalizeYawDeg(-equirectYawDeg)
    }

    static func shortestDeltaDeg(from: Float, to: Float) -> Float {
        normalizeYawDeg(to - from)
    }

    /// Soft warning thresholds — never block shutter.
    static let softWarnYawDeltaDeg: Float = 35
    static let softWarnPitchDeltaDeg: Float = 28

    static func shouldSoftWarnMisalignment(yawDeltaDeg: Float, pitchDeltaDeg: Float) -> Bool {
        abs(yawDeltaDeg) > softWarnYawDeltaDeg || abs(pitchDeltaDeg) > softWarnPitchDeltaDeg
    }
}
