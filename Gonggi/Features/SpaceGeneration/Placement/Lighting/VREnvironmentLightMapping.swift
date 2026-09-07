import Foundation
import simd

/// Equirect yaw/pitch → SceneKit world light direction.
/// Uses Gonggi VR equirect convention (front 0, right +90, left −90, pitch up +).
/// Does **not** modify camera / repair bridge.
enum VREnvironmentLightMapping {
    /// Direction **from** the scene **toward** the light (SceneKit directional light points −Z in light local; we set `simdWorldFront`).
    /// Returns a unit vector pointing **toward** the light source from origin (where light comes from).
    static func lightIncomingDirection(
        yawDeg: Float,
        pitchDeg: Float
    ) -> SIMD3<Float> {
        // Same spherical mapping as equirect look: yaw around +Y, pitch up positive.
        let yaw = yawDeg * .pi / 180
        let pitch = pitchDeg * .pi / 180
        let cosP = cos(pitch)
        // Toward light in world: +Z is behind camera "front" in some conventions —
        // Match inside-out sphere: front equirect 0 → −Z (camera looks −Z into sphere).
        let x = sin(yaw) * cosP
        let y = sin(pitch)
        let z = -cos(yaw) * cosP
        let v = SIMD3(x, y, z)
        let len = simd_length(v)
        return len > 1e-6 ? v / len : SIMD3(0, 1, 0)
    }

    /// SceneKit directional light looks along −Z of its node; orient node so −Z aligns with light travel (from light to scene = −incoming).
    static func directionalNodeEulerYXZ(yawDeg: Float, pitchDeg: Float) -> SIMD3<Float> {
        let incoming = lightIncomingDirection(yawDeg: yawDeg, pitchDeg: pitchDeg)
        let travel = -incoming // light rays travel toward scene
        // yaw from XZ, pitch from Y
        let yaw = atan2(travel.x, -travel.z)
        let horizontal = simd_length(SIMD2(travel.x, travel.z))
        let pitch = atan2(travel.y, max(horizontal, 1e-6))
        return SIMD3(pitch, yaw, 0)
    }

    /// Opposite yaw for contact blob offset (light comes from yaw → shadow stretches opposite).
    static func oppositeYawDeg(_ yawDeg: Float) -> Float {
        var v = yawDeg + 180
        while v > 180 { v -= 360 }
        while v < -180 { v += 360 }
        return v
    }
}
