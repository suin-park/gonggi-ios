import Foundation
import simd

/// Gravity-aligned capture frame for sphere yaw/pitch (ARKit `worldAlignment = .gravity`).
///
/// Locks horizontal heading at START so subsequent body yaw does not mix into pitch/roll
/// the way `inverse(start) * current` does when the start camera is pitched.
struct Quick360CaptureBasis: Equatable, Sendable {
    /// ARKit gravity up.
    var worldUp: simd_float3
    /// Start optical forward projected onto the horizontal plane (unit).
    var referenceForward: simd_float3
    /// Horizontal right: `normalize(cross(referenceForward, worldUp))` (right-handed).
    var referenceRight: simd_float3

    static let gravityUp = simd_float3(0, 1, 0)

    /// Build fixed basis from the START camera pose. Fails if forward is parallel to up.
    static func make(fromStartCamera startTransform: simd_float4x4) -> Quick360CaptureBasis? {
        let worldUp = gravityUp
        let startForward = SphericalMath.forwardVector(from: startTransform)
        let horizontal = startForward - simd_dot(startForward, worldUp) * worldUp
        let horizLen = simd_length(horizontal)
        guard horizLen > 1e-4 else { return nil }
        let referenceForward = horizontal / horizLen
        let right = simd_cross(referenceForward, worldUp)
        let rightLen = simd_length(right)
        guard rightLen > 1e-4 else { return nil }
        return Quick360CaptureBasis(
            worldUp: worldUp,
            referenceForward: referenceForward,
            referenceRight: right / rightLen
        )
    }

    /// Camera optical forward → gravity yaw/pitch in this basis.
    func centerYawPitch(cameraTransform: simd_float4x4) -> (yaw: Float, pitch: Float) {
        yawPitch(fromWorldDirection: SphericalMath.forwardVector(from: cameraTransform))
    }

    /// World-space unit direction → sphere yaw/pitch.
    /// `yaw = atan2(dot(h, right), dot(h, forward))`, `pitch = asin(dot(dir, up))`.
    func yawPitch(fromWorldDirection direction: simd_float3) -> (yaw: Float, pitch: Float) {
        let dir = simd_normalize(direction)
        let pitch = asin(simd_clamp(simd_dot(dir, worldUp), -1, 1))
        let horizontal = dir - simd_dot(dir, worldUp) * worldUp
        let hLen = simd_length(horizontal)
        if hLen < 1e-5 {
            return (0, pitch)
        }
        let h = horizontal / hLen
        let yaw = atan2(simd_dot(h, referenceRight), simd_dot(h, referenceForward))
        return (yaw, pitch)
    }

    /// Sphere yaw/pitch → world direction (equirect reverse mapping in this basis).
    func worldDirection(yawRad: Float, pitchRad: Float) -> simd_float3 {
        let cosPitch = cos(pitchRad)
        let sinPitch = sin(pitchRad)
        let cosYaw = cos(yawRad)
        let sinYaw = sin(yawRad)
        return simd_normalize(
            referenceRight * (sinYaw * cosPitch)
                + worldUp * sinPitch
                + referenceForward * (cosYaw * cosPitch)
        )
    }

    /// 3×3 camera rotation (columns = camera axes in world).
    static func cameraRotation(from transform: simd_float4x4) -> simd_float3x3 {
        simd_float3x3(
            SIMD3(transform.columns.0.x, transform.columns.0.y, transform.columns.0.z),
            SIMD3(transform.columns.1.x, transform.columns.1.y, transform.columns.1.z),
            SIMD3(transform.columns.2.x, transform.columns.2.y, transform.columns.2.z)
        )
    }

    /// Portrait camera-local ray → world ray via current camera rotation.
    func worldRay(cameraRay: simd_float3, cameraTransform: simd_float4x4) -> simd_float3 {
        let R = Self.cameraRotation(from: cameraTransform)
        return simd_normalize(R * cameraRay)
    }

    /// Pixel → camera ray → world → gravity yaw/pitch.
    func sphereYawPitchFromPixel(
        pixelU: Float,
        pixelV: Float,
        thumbIntrinsics: CameraIntrinsics,
        cameraTransform: simd_float4x4
    ) -> (yaw: Float, pitch: Float) {
        let ray = Quick360PerspectiveProjection.cameraRayFromPixel(
            pixelU: pixelU,
            pixelV: pixelV,
            thumbIntrinsics: thumbIntrinsics
        )
        return yawPitch(fromWorldDirection: worldRay(cameraRay: ray, cameraTransform: cameraTransform))
    }

    /// Reverse: sphere (equirect) direction in this basis → camera pixel.
    func projectSphereDirectionToPixel(
        yawRad: Float,
        pitchRad: Float,
        cameraTransform: simd_float4x4,
        thumbIntrinsics: CameraIntrinsics,
        edgePad: Float = 0.5
    ) -> SIMD2<Float>? {
        let worldDir = worldDirection(yawRad: yawRad, pitchRad: pitchRad)
        let R = Self.cameraRotation(from: cameraTransform)
        let dirCam = simd_normalize(simd_transpose(R) * worldDir)
        let depth = -dirCam.z
        guard depth > 1e-5 else { return nil }
        let u = thumbIntrinsics.fx * (dirCam.x / depth) + thumbIntrinsics.cx
        let v = thumbIntrinsics.fy * (-dirCam.y / depth) + thumbIntrinsics.cy
        let maxU = Float(thumbIntrinsics.width - 1) + edgePad
        let maxV = Float(thumbIntrinsics.height - 1) + edgePad
        guard u >= -edgePad, v >= -edgePad, u <= maxU, v <= maxV else { return nil }
        return SIMD2(u, v)
    }

    /// Debug-only: previous `inverse(start)*current` yaw/pitch (not used for paint).
    static func rawRelativeYawPitch(
        cameraTransform: simd_float4x4,
        originTransform: simd_float4x4
    ) -> (yaw: Float, pitch: Float) {
        SphericalMath.relativeYawPitchRad(
            cameraTransform: cameraTransform,
            originTransform: originTransform
        )
    }
}
