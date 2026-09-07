import CoreGraphics
import Foundation
import simd

enum EditOneFingerOwner: Equatable {
    case none
    case assetMove(placementId: String)
    case cameraPan
}

enum VRGestureMath {
    static let pinchLerpAlpha: Float = 0.35
    static let rotateLerpAlpha: Float = 0.35
    /// Approx minimum touch target in points (iOS HIG ~44–60).
    static let minimumTouchTargetPoints: Float = 52

    static func lerp(_ from: Float, _ to: Float, alpha: Float) -> Float {
        from + (to - from) * min(max(alpha, 0), 1)
    }

    /// Shortest-path angle interpolation (radians). Avoids 359°→1° long-way spin.
    static func lerpAngle(_ from: Float, _ to: Float, alpha: Float) -> Float {
        var delta = to - from
        let pi = Float.pi
        while delta > pi { delta -= 2 * pi }
        while delta < -pi { delta += 2 * pi }
        return from + delta * min(max(alpha, 0), 1)
    }

    static func shortestAngleDelta(from: Float, to: Float) -> Float {
        var delta = to - from
        let pi = Float.pi
        while delta > pi { delta -= 2 * pi }
        while delta < -pi { delta += 2 * pi }
        return delta
    }

    /// World-space minimum hit extent so projected size ≈ targetPoints at FOV/distance.
    static func minimumHitExtentMeters(
        distance: Float,
        viewportHeight: Float,
        verticalFOVDegrees: Float = 70,
        targetPoints: Float = minimumTouchTargetPoints
    ) -> Float {
        let d = max(distance, 0.35)
        let h = max(viewportHeight, 1)
        let fov = verticalFOVDegrees * .pi / 180
        return 2 * d * tan(fov * 0.5) * (targetPoints / h)
    }

    static func expandExtent(_ mesh: Float, minimum: Float) -> Float {
        max(mesh, minimum)
    }
}
