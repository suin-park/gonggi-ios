import CoreGraphics
import simd

struct VRWorldRay: Equatable, Sendable {
    var origin: SIMD3<Float>
    var direction: SIMD3<Float>
}

enum VRFloorRay {
    static let minimumDistance: Float = 0.8
    static let maximumDistance: Float = 4
    static let fallbackDistance: Float = 2

    static func ray(
        screenPoint: CGPoint,
        viewportSize: CGSize,
        cameraTransform: simd_float4x4,
        verticalFOVDegrees: Float = 70
    ) -> VRWorldRay {
        guard viewportSize.width > 0, viewportSize.height > 0 else {
            return VRWorldRay(
                origin: translation(of: cameraTransform),
                direction: worldDirection(SIMD3(0, 0, -1), cameraTransform: cameraTransform)
            )
        }

        let normalizedX = Float((screenPoint.x / viewportSize.width) * 2 - 1)
        let normalizedY = Float(1 - (screenPoint.y / viewportSize.height) * 2)
        let aspect = Float(viewportSize.width / viewportSize.height)
        let tanHalfFOV = tan(verticalFOVDegrees * .pi / 360)
        let cameraDirection = simd_normalize(
            SIMD3(normalizedX * aspect * tanHalfFOV, normalizedY * tanHalfFOV, -1)
        )
        return VRWorldRay(
            origin: translation(of: cameraTransform),
            direction: worldDirection(cameraDirection, cameraTransform: cameraTransform)
        )
    }

    static func floorPoint(
        screenPoint: CGPoint,
        viewportSize: CGSize,
        cameraTransform: simd_float4x4,
        floorY: Float,
        verticalFOVDegrees: Float = 70
    ) -> SIMD3<Float> {
        let worldRay = ray(
            screenPoint: screenPoint,
            viewportSize: viewportSize,
            cameraTransform: cameraTransform,
            verticalFOVDegrees: verticalFOVDegrees
        )
        return intersectFloor(ray: worldRay, floorY: floorY)
    }

    static func intersectFloor(ray: VRWorldRay, floorY: Float) -> SIMD3<Float> {
        if ray.direction.y < -1e-5 {
            let t = (floorY - ray.origin.y) / ray.direction.y
            if t > 0, t.isFinite {
                let hit = ray.origin + ray.direction * t
                return clampToFloor(hit, origin: ray.origin, floorY: floorY)
            }
        }
        return fallbackPoint(ray: ray, floorY: floorY)
    }

    private static func fallbackPoint(ray: VRWorldRay, floorY: Float) -> SIMD3<Float> {
        var horizontal = SIMD2(ray.direction.x, ray.direction.z)
        if simd_length_squared(horizontal) < 1e-6 {
            horizontal = SIMD2(0, -1)
        } else {
            horizontal = simd_normalize(horizontal)
        }
        return SIMD3(
            ray.origin.x + horizontal.x * fallbackDistance,
            floorY,
            ray.origin.z + horizontal.y * fallbackDistance
        )
    }

    private static func clampToFloor(
        _ point: SIMD3<Float>,
        origin: SIMD3<Float>,
        floorY: Float
    ) -> SIMD3<Float> {
        var offset = SIMD2(point.x - origin.x, point.z - origin.z)
        let distance = simd_length(offset)
        if distance < 1e-6 {
            offset = SIMD2(0, -minimumDistance)
        } else {
            offset *= min(max(distance, minimumDistance), maximumDistance) / distance
        }
        return SIMD3(origin.x + offset.x, floorY, origin.z + offset.y)
    }

    private static func translation(of transform: simd_float4x4) -> SIMD3<Float> {
        SIMD3(transform.columns.3.x, transform.columns.3.y, transform.columns.3.z)
    }

    private static func worldDirection(
        _ direction: SIMD3<Float>,
        cameraTransform: simd_float4x4
    ) -> SIMD3<Float> {
        let value = cameraTransform * SIMD4(direction.x, direction.y, direction.z, 0)
        let world = SIMD3(value.x, value.y, value.z)
        guard simd_length_squared(world) > 1e-8 else { return SIMD3(0, 0, -1) }
        return simd_normalize(world)
    }
}
