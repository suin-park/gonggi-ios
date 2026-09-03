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

    /// Raw ARKit 3×3 (includes roll). Debug / comparison only — not used for patch paint.
    static func cameraRotation(from transform: simd_float4x4) -> simd_float3x3 {
        simd_float3x3(
            SIMD3(transform.columns.0.x, transform.columns.0.y, transform.columns.0.z),
            SIMD3(transform.columns.1.x, transform.columns.1.y, transform.columns.1.z),
            SIMD3(transform.columns.2.x, transform.columns.2.y, transform.columns.2.z)
        )
    }

    /// Portrait camera-local ray → world via **gravity-stabilized** (roll-free) frame.
    func worldRay(cameraRay: simd_float3, cameraTransform: simd_float4x4) -> simd_float3 {
        guard let frame = Quick360StabilizedCameraFrame.make(
            fromCamera: cameraTransform,
            worldUp: worldUp
        ) else {
            let R = Self.cameraRotation(from: cameraTransform)
            return simd_normalize(R * cameraRay)
        }
        return frame.worldRay(fromCameraRay: cameraRay)
    }

    /// Pixel → camera ray → roll-free world → gravity yaw/pitch.
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

    /// Reverse: sphere direction → pixel using roll-free camera frame (matches paint).
    func projectSphereDirectionToPixel(
        yawRad: Float,
        pitchRad: Float,
        cameraTransform: simd_float4x4,
        thumbIntrinsics: CameraIntrinsics,
        edgePad: Float = 0.5
    ) -> SIMD2<Float>? {
        let worldDir = worldDirection(yawRad: yawRad, pitchRad: pitchRad)
        guard let frame = Quick360StabilizedCameraFrame.make(
            fromCamera: cameraTransform,
            worldUp: worldUp
        ) else { return nil }
        let dirCam = frame.cameraRay(fromWorldDirection: worldDir)
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

/// Roll-free camera axes for patch image orientation (keeps look pitch/yaw, drops phone roll).
///
/// ```
/// forward = normalize(-camera.columns.2)
/// right   = normalize(cross(forward, worldUp))
/// up      = normalize(cross(right, forward))
/// worldRay = right*x + up*y + forward*(-z)   // cameraRay z≈−1 → along forward
/// ```
struct Quick360StabilizedCameraFrame: Equatable, Sendable {
    var forward: simd_float3
    var right: simd_float3
    var up: simd_float3

    /// Columns = (right, up, −forward) — same layout as ARKit without roll.
    var rotation: simd_float3x3 {
        simd_float3x3(right, up, -forward)
    }

    static func make(
        fromCamera transform: simd_float4x4,
        worldUp: simd_float3 = Quick360CaptureBasis.gravityUp
    ) -> Quick360StabilizedCameraFrame? {
        let forward = simd_normalize(SphericalMath.forwardVector(from: transform))
        var right = simd_cross(forward, worldUp)
        var rightLen = simd_length(right)
        if rightLen < 1e-4 {
            // Looking nearly straight up/down — keep a horizontal right from camera +X.
            let camRight = simd_float3(
                transform.columns.0.x, transform.columns.0.y, transform.columns.0.z
            )
            let horiz = camRight - simd_dot(camRight, worldUp) * worldUp
            rightLen = simd_length(horiz)
            guard rightLen > 1e-4 else { return nil }
            right = horiz / rightLen
        } else {
            right = right / rightLen
        }
        let up = simd_normalize(simd_cross(right, forward))
        // Re-orthogonalize right against forward/up for numerical stability.
        right = simd_normalize(simd_cross(forward, up))
        return Quick360StabilizedCameraFrame(forward: forward, right: right, up: up)
    }

    /// Portrait camera-local ray (x right, y up, z≈−1) → world.
    func worldRay(fromCameraRay cameraRay: simd_float3) -> simd_float3 {
        let x = cameraRay.x
        let y = cameraRay.y
        let z = cameraRay.z
        // forward * (-z): center (0,0,−1) → +forward
        return simd_normalize(right * x + up * y + forward * (-z))
    }

    /// World direction → camera-local ray in this roll-free frame.
    func cameraRay(fromWorldDirection worldDir: simd_float3) -> simd_float3 {
        let d = simd_normalize(worldDir)
        return simd_normalize(simd_float3(
            simd_dot(d, right),
            simd_dot(d, up),
            -simd_dot(d, forward)
        ))
    }
}
