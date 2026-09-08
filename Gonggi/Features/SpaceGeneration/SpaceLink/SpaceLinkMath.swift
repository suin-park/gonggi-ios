import Foundation
import SceneKit
import simd

/// Angular + radius position helpers for SpaceHotspotNode (Build 72/74).
enum SpaceLinkMath {
    /// worldPosition = rayFromCamera(yaw,pitch) * radius (inside-out sphere convention).
    static func worldPosition(yawDeg: Float, pitchDeg: Float, radius: Float) -> SIMD3<Float> {
        VRSphereEquirectBridge.insideOutSpherePoint(
            yawDeg: yawDeg,
            pitchDeg: pitchDeg,
            radius: SpaceLink.clampRadius(radius)
        )
    }

    /// Inverse of `insideOutSpherePoint` direction (unit vector → equirect degrees).
    static func equirectDegreesFromWorldDirection(_ direction: SIMD3<Float>) -> (yawDeg: Float, pitchDeg: Float) {
        let len = simd_length(direction)
        guard len > 1e-8 else { return (0, 0) }
        let d = direction / len
        // Match insideOutSpherePoint: x=-sinφ·sinθ, y=cosφ, z=sinφ·cosθ
        let phi = acos(max(-1, min(1, d.y))) // 0…π
        let theta = atan2(-d.x, d.z)
        var u = theta / (2 * Float.pi)
        u -= floor(u)
        let v = phi / Float.pi
        return VRSphereEquirectBridge.equirectDegreesFromTextureUV(u: u, v: v)
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
        return min(max(extent, 0.18), 0.55)
    }

    /// Project equirect pose to normalized screen UV (0…1) via SceneKit camera euler
    /// (same transform as `equirectDegreesFromCameraCenterRay`). Returns nil if behind camera.
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
    /// Used by Build 74 spawn round-trip tests (same path as `SCNHostView.equirectDegreesAtScreenPoint`).
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
