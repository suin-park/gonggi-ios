import Foundation
import simd

/// Spherical reprojection from camera keyframes to equirectangular canvas.
enum PanoramaSphericalProjector {
    struct ProjectedSample: Equatable {
        let r: Float
        let g: Float
        let b: Float
        let weight: Float
        let keyframeIndex: Int
    }

    /// Project a single keyframe onto equirectangular canvas (relative to origin).
    static func projectKeyframe(
        rgba: [UInt8],
        width: Int,
        height: Int,
        cameraTransform: simd_float4x4,
        originTransform: simd_float4x4,
        intrinsics: CameraIntrinsics,
        keyframeIndex: Int,
        outWidth: Int,
        outHeight: Int
    ) -> (colors: [SIMD3<Float>], weights: [Float], coverage: [Bool]) {
        let count = outWidth * outHeight
        var colors = [SIMD3<Float>](repeating: .zero, count: count)
        var weights = [Float](repeating: 0, count: count)
        var coverage = [Bool](repeating: false, count: count)

        let worldToOrigin = simd_inverse(originTransform)
        let cameraToWorld = cameraTransform
        let worldToCamera = simd_inverse(cameraToWorld)

        for py in 0..<outHeight {
            for px in 0..<outWidth {
                let dirWorld = SphericalMath.directionFromEquirectangularPixel(
                    x: px, y: py, width: outWidth, height: outHeight
                )
                // Direction in origin-local world space
                let dirOrigin = simd_float3(
                    worldToOrigin.columns.0.x * dirWorld.x + worldToOrigin.columns.1.x * dirWorld.y + worldToOrigin.columns.2.x * dirWorld.z,
                    worldToOrigin.columns.0.y * dirWorld.x + worldToOrigin.columns.1.y * dirWorld.y + worldToOrigin.columns.2.y * dirWorld.z,
                    worldToOrigin.columns.0.z * dirWorld.x + worldToOrigin.columns.1.z * dirWorld.y + worldToOrigin.columns.2.z * dirWorld.z
                )
                // To camera space
                let dirCam = simd_float3(
                    worldToCamera.columns.0.x * dirOrigin.x + worldToCamera.columns.1.x * dirOrigin.y + worldToCamera.columns.2.x * dirOrigin.z,
                    worldToCamera.columns.0.y * dirOrigin.x + worldToCamera.columns.1.y * dirOrigin.y + worldToCamera.columns.2.y * dirOrigin.z,
                    worldToCamera.columns.0.z * dirOrigin.x + worldToCamera.columns.1.z * dirOrigin.y + worldToCamera.columns.2.z * dirOrigin.z
                )
                let depth = -dirCam.z
                guard depth > 0.05 else { continue }

                let u = intrinsics.fx * dirCam.x / depth + intrinsics.cx
                let v = intrinsics.fy * dirCam.y / depth + intrinsics.cy
                guard u >= 0, v >= 0, u < Float(intrinsics.width - 1), v < Float(intrinsics.height - 1) else {
                    continue
                }

                let color = bilinearSample(rgba: rgba, width: width, height: height, u: u, v: v)
                let forward = SphericalMath.forwardVector(from: cameraTransform)
                let facing = simd_dot(simd_normalize(dirWorld), forward)
                let w = simd_clamp(facing, 0, 1)
                guard w > 0.05 else { continue }

                let idx = py * outWidth + px
                colors[idx] += color * w
                weights[idx] += w
                coverage[idx] = true
            }
        }
        return (colors, weights, coverage)
    }

    static func bilinearSample(
        rgba: [UInt8],
        width: Int,
        height: Int,
        u: Float,
        v: Float
    ) -> SIMD3<Float> {
        let x0 = Int(floor(u))
        let y0 = Int(floor(v))
        let x1 = min(x0 + 1, width - 1)
        let y1 = min(y0 + 1, height - 1)
        let fx = u - Float(x0)
        let fy = v - Float(y0)

        func sample(_ x: Int, _ y: Int) -> SIMD3<Float> {
            let i = (y * width + x) * 4
            return SIMD3<Float>(
                Float(rgba[i]) / 255,
                Float(rgba[i + 1]) / 255,
                Float(rgba[i + 2]) / 255
            )
        }

        let c00 = sample(x0, y0)
        let c10 = sample(x1, y0)
        let c01 = sample(x0, y1)
        let c11 = sample(x1, y1)
        let c0 = c00 * (1 - fx) + c10 * fx
        let c1 = c01 * (1 - fx) + c11 * fx
        return c0 * (1 - fy) + c1 * fy
    }
}
