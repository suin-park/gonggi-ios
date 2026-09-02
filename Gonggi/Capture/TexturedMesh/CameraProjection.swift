import Foundation
import simd

/// Pure camera projection math (testable without ARKit).
enum CameraProjection {
    struct ProjectedPoint: Equatable {
        let pixel: SIMD2<Float>
        let depth: Float
        let facing: Float
    }

    static func worldToCamera(
        worldPoint: SIMD3<Float>,
        cameraTransform: simd_float4x4
    ) -> SIMD3<Float> {
        let worldToCamera = simd_inverse(cameraTransform)
        let homogeneous = SIMD4<Float>(worldPoint.x, worldPoint.y, worldPoint.z, 1)
        let camera = worldToCamera * homogeneous
        return SIMD3<Float>(camera.x, camera.y, camera.z)
    }

    static func project(
        worldPoint: SIMD3<Float>,
        worldNormal: SIMD3<Float>,
        cameraTransform: simd_float4x4,
        intrinsics: CameraIntrinsics,
        minFacing: Float = 0.15
    ) -> ProjectedPoint? {
        let cameraPoint = worldToCamera(worldPoint: worldPoint, cameraTransform: cameraTransform)
        let depth = -cameraPoint.z
        guard depth > 0.05 else { return nil }

        let pixel = SIMD2<Float>(
            intrinsics.fx * cameraPoint.x / depth + intrinsics.cx,
            intrinsics.fy * cameraPoint.y / depth + intrinsics.cy
        )

        guard pixel.x >= 0, pixel.y >= 0,
              pixel.x < Float(intrinsics.width),
              pixel.y < Float(intrinsics.height) else {
            return nil
        }

        let cameraPosition = SIMD3<Float>(
            cameraTransform.columns.3.x,
            cameraTransform.columns.3.y,
            cameraTransform.columns.3.z
        )
        let viewDirection = simd_normalize(cameraPosition - worldPoint)
        let facing = simd_dot(simd_normalize(worldNormal), viewDirection)
        guard facing >= minFacing else { return nil }

        return ProjectedPoint(pixel: pixel, depth: depth, facing: facing)
    }

    static func scoreProjection(_ projected: ProjectedPoint) -> Float {
        projected.facing / (projected.depth + 0.25)
    }
}
