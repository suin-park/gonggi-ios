import Foundation
import simd

/// Angular + radius position helpers for SpaceHotspotNode (Build 72).
enum SpaceLinkMath {
    /// worldPosition = rayFromCamera(yaw,pitch) * radius (inside-out sphere convention).
    static func worldPosition(yawDeg: Float, pitchDeg: Float, radius: Float) -> SIMD3<Float> {
        VRSphereEquirectBridge.insideOutSpherePoint(
            yawDeg: yawDeg,
            pitchDeg: pitchDeg,
            radius: SpaceLink.clampRadius(radius)
        )
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
}
