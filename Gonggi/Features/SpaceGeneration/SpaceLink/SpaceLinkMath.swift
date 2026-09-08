import Foundation
import SceneKit
import simd

/// Angular + radius position helpers for SpaceHotspotNode (Build 72/75).
///
/// **Canonical pose** remains equirect `yawDeg` / `pitchDeg` / `radius`.
///
/// **World placement (Build 75):** use the same SceneKit camera look direction as
/// `VRLookMath.cameraEulerRad` → camera local −Z. Do **not** use
/// `VRSphereEquirectBridge.insideOutSpherePoint` for hotspots — that formula matches
/// scaled SCNSphere UV vertices, which sit on the opposite longitude from the
/// camera look ray for non-zero yaw (sibling nodes are not under the −X sphere scale).
enum SpaceLinkMath {
    /// worldPosition = cameraLookDirection(yaw,pitch) * radius.
    static func worldPosition(yawDeg: Float, pitchDeg: Float, radius: Float) -> SIMD3<Float> {
        let r = SpaceLink.clampRadius(radius)
        return lookDirection(yawDeg: yawDeg, pitchDeg: pitchDeg) * r
    }

    /// Unit look direction for composed equirect pose (SceneKit camera −Z).
    static func lookDirection(yawDeg: Float, pitchDeg: Float) -> SIMD3<Float> {
        let cam = VRLookMath.cameraEulerRad(equirectYawDeg: yawDeg, equirectPitchDeg: pitchDeg)
        let node = SCNNode()
        node.eulerAngles = SCNVector3(cam.pitch, cam.yaw, 0)
        let dir4 = node.simdWorldTransform * SIMD4(0, 0, -1, 0)
        let dir = SIMD3(dir4.x, dir4.y, dir4.z)
        let len = simd_length(dir)
        guard len > 1e-8 else { return SIMD3(0, 0, -1) }
        return dir / len
    }

    /// Inverse of `lookDirection` (unit vector → equirect degrees).
    static func equirectDegreesFromWorldDirection(_ direction: SIMD3<Float>) -> (yawDeg: Float, pitchDeg: Float) {
        let len = simd_length(direction)
        guard len > 1e-8 else { return (0, 0) }
        let d = direction / len
        // Match VRLookMath / camera −Z: yaw from (−x, −z), pitch from elevation.
        let yawDeg = VRLookMath.normalizeYawDeg(atan2(-d.x, -d.z) * 180 / .pi)
        let horiz = max(1e-6, sqrt(d.x * d.x + d.z * d.z))
        let pitchDeg = VRLookMath.clampPitchDeg(atan2(d.y, horiz) * 180 / .pi)
        return (yawDeg, pitchDeg)
    }

    /// Billboard diameter so on-screen size ≈ targetPoints at given distance/FOV.
    static func billboardDiameterMeters(
        distance: Float,
        viewportHeight: Float,
        verticalFOVDegrees: Float,
        targetPoints: Float = 48
    ) -> Float {
        let extent = VRGestureMath.minimumHitExtentMeters(
            distance: max(distance, 0.5),
            viewportHeight: max(viewportHeight, 1),
            verticalFOVDegrees: verticalFOVDegrees,
            targetPoints: targetPoints
        )
        // Keep Edit markers readable (Build 75 minimum clamp).
        return min(max(extent, 0.28), 0.70)
    }

    /// Project equirect pose to normalized screen UV (0…1) via SceneKit camera euler.
    /// Returns nil if behind camera.
    static func screenUV(
        yawDeg: Float,
        pitchDeg: Float,
        cameraYawDeg: Float,
        cameraPitchDeg: Float,
        verticalFOVDegrees: Float,
        aspect: Float
    ) -> (x: Float, y: Float)? {
        let world = worldPosition(yawDeg: yawDeg, pitchDeg: pitchDeg, radius: 1)
        let cam = VRLookMath.cameraEulerRad(equirectYawDeg: cameraYawDeg, equirectPitchDeg: cameraPitchDeg)
        let node = SCNNode()
        node.eulerAngles = SCNVector3(cam.pitch, cam.yaw, 0)
        let inv = node.simdWorldTransform.inverse
        let local4 = inv * SIMD4(world.x, world.y, world.z, 1)
        let local = SIMD3(local4.x, local4.y, local4.z)
        guard local.z < -1e-5 else { return nil }
        let tanHalf = tan(verticalFOVDegrees * .pi / 360)
        let ndcX = (local.x / -local.z) / (aspect * tanHalf)
        let ndcY = (local.y / -local.z) / tanHalf
        return (ndcX * 0.5 + 0.5, 0.5 - ndcY * 0.5)
    }

    /// Screen-center world ray under SceneKit camera euler → equirect degrees.
    static func equirectDegreesFromCameraCenterRay(
        cameraYawDeg: Float,
        cameraPitchDeg: Float,
        verticalFOVDegrees: Float = 70,
        viewportSize: CGSize = CGSize(width: 390, height: 844)
    ) -> (yawDeg: Float, pitchDeg: Float) {
        let cam = VRLookMath.cameraEulerRad(equirectYawDeg: cameraYawDeg, equirectPitchDeg: cameraPitchDeg)
        let node = SCNNode()
        node.eulerAngles = SCNVector3(cam.pitch, cam.yaw, 0)
        let center = CGPoint(x: viewportSize.width * 0.5, y: viewportSize.height * 0.5)
        let worldRay = VRFloorRay.ray(
            screenPoint: center,
            viewportSize: viewportSize,
            cameraTransform: node.simdWorldTransform,
            verticalFOVDegrees: verticalFOVDegrees
        )
        return equirectDegreesFromWorldDirection(worldRay.direction)
    }
}
