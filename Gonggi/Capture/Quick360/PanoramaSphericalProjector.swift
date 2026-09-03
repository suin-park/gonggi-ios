import Foundation
import simd

/// Spherical reprojection aligned with **live** capture math.
///
/// Contract (must match `Quick360LiveSphereBrush` / `Quick360CaptureBasis`):
/// - Equirect yaw/pitch: `u→yaw`, `v→pitch` via `SphericalMath.equirectangularUV` inverse
/// - World direction: `captureBasis.worldDirection` (yaw=0 = capture forward)
/// - Camera ray: roll-free `Quick360StabilizedCameraFrame`
/// - Pixel: portrait-oriented keyframe + remapped/scaled intrinsics
/// - Image Y: `v = fy * (-dirCam.y)/depth + cy` (same as live)
///
/// Do **not** use `directionFromEquirectangularPixel` (+Z at yaw=0) here — that is the
/// legacy mismatch that rotated final VR ~90° vs live.
enum PanoramaSphericalProjector {
    /// Project a single keyframe onto equirectangular canvas using gravity capture basis.
    static func projectKeyframe(
        rgba: [UInt8],
        width: Int,
        height: Int,
        cameraTransform: simd_float4x4,
        captureBasis: Quick360CaptureBasis,
        intrinsics: CameraIntrinsics,
        keyframeIndex: Int,
        outWidth: Int,
        outHeight: Int
    ) -> (colors: [SIMD3<Float>], weights: [Float], coverage: [Bool]) {
        let count = outWidth * outHeight
        var colors = [SIMD3<Float>](repeating: .zero, count: count)
        var weights = [Float](repeating: 0, count: count)
        var coverage = [Bool](repeating: false, count: count)

        // Intrinsics must match portrait keyframe pixel size.
        let thumbK = Quick360PerspectiveProjection.scaledIntrinsics(
            intrinsics,
            thumbWidth: width,
            thumbHeight: height
        )
        let forward = SphericalMath.forwardVector(from: cameraTransform)

        for py in 0..<outHeight {
            for px in 0..<outWidth {
                let uNorm = Float(px) / Float(max(outWidth - 1, 1))
                let vNorm = Float(py) / Float(max(outHeight - 1, 1))
                let yaw = uNorm * 2 * .pi - .pi
                let pitch = .pi / 2 - vNorm * .pi

                guard let uv = captureBasis.projectSphereDirectionToPixel(
                    yawRad: yaw,
                    pitchRad: pitch,
                    cameraTransform: cameraTransform,
                    thumbIntrinsics: thumbK,
                    edgePad: 0.5
                ) else { continue }

                let sampleU = uv.x
                let sampleV = uv.y
                guard sampleU >= 0, sampleV >= 0,
                      sampleU < Float(width - 1), sampleV < Float(height - 1) else {
                    continue
                }

                let worldDir = captureBasis.worldDirection(yawRad: yaw, pitchRad: pitch)
                let facing = simd_dot(worldDir, forward)
                let w = simd_clamp(facing, 0, 1)
                guard w > 0.05 else { continue }

                let color = bilinearSample(rgba: rgba, width: width, height: height, u: sampleU, v: sampleV)
                let idx = py * outWidth + px
                colors[idx] += color * w
                weights[idx] += w
                coverage[idx] = true
            }
        }
        return (colors, weights, coverage)
    }

    /// Legacy overload kept for older call sites / tests — builds basis from origin camera.
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
        let basis = Quick360CaptureBasis.make(fromStartCamera: originTransform)
            ?? Quick360CaptureBasis(
                worldUp: Quick360CaptureBasis.gravityUp,
                referenceForward: simd_float3(0, 0, -1),
                referenceRight: simd_float3(1, 0, 0)
            )
        return projectKeyframe(
            rgba: rgba,
            width: width,
            height: height,
            cameraTransform: cameraTransform,
            captureBasis: basis,
            intrinsics: intrinsics,
            keyframeIndex: keyframeIndex,
            outWidth: outWidth,
            outHeight: outHeight
        )
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
