import Foundation
import simd

/// Build 27 — camera ray / world / LatLong math aligned with Gonggi equirect contract.
///
/// Optical convention (ARKit / CaptureBasis):
/// - Camera: X right, Y up, −Z forward
/// - Image: top-left origin, Y down → ray Y is flipped vs pixel v
/// - LatLong: yaw=0 (first-forward / −Z) → U=0.5; +pitch → smaller V
/// No extra H-flip / ±90° hacks.
enum DepthReprojectionMath {
    static func cameraRay(u: Float, v: Float, K: CameraIntrinsics) -> simd_float3 {
        let x = (u - K.cx) / max(K.fx, 1e-3)
        let y = -((v - K.cy) / max(K.fy, 1e-3))
        let z: Float = -1
        return simd_normalize(simd_float3(x, y, z))
    }

    static func worldPoint(
        depth: Float,
        rayCam: simd_float3,
        cameraToWorld: simd_float4x4
    ) -> simd_float3 {
        let pCam = rayCam * depth
        let R = simd_float3x3(columns: (
            simd_float3(cameraToWorld.columns.0.x, cameraToWorld.columns.0.y, cameraToWorld.columns.0.z),
            simd_float3(cameraToWorld.columns.1.x, cameraToWorld.columns.1.y, cameraToWorld.columns.1.z),
            simd_float3(cameraToWorld.columns.2.x, cameraToWorld.columns.2.y, cameraToWorld.columns.2.z)
        ))
        let t = simd_float3(cameraToWorld.columns.3.x, cameraToWorld.columns.3.y, cameraToWorld.columns.3.z)
        return R * pCam + t
    }

    static func cameraCenter(_ cameraToWorld: simd_float4x4) -> simd_float3 {
        simd_float3(cameraToWorld.columns.3.x, cameraToWorld.columns.3.y, cameraToWorld.columns.3.z)
    }

    /// Project world point into a camera image (same optical convention).
    static func projectWorldToPixel(
        _ Pw: simd_float3,
        cameraToWorld: simd_float4x4,
        K: CameraIntrinsics,
        width: Int,
        height: Int
    ) -> SIMD2<Float>? {
        let worldToCam = simd_inverse(cameraToWorld)
        let R = simd_float3x3(columns: (
            simd_float3(worldToCam.columns.0.x, worldToCam.columns.0.y, worldToCam.columns.0.z),
            simd_float3(worldToCam.columns.1.x, worldToCam.columns.1.y, worldToCam.columns.1.z),
            simd_float3(worldToCam.columns.2.x, worldToCam.columns.2.y, worldToCam.columns.2.z)
        ))
        let t = simd_float3(worldToCam.columns.3.x, worldToCam.columns.3.y, worldToCam.columns.3.z)
        let Pc = R * Pw + t
        // Camera looks −Z: visible if z < 0
        guard Pc.z < -1e-4 else { return nil }
        let u = K.fx * (Pc.x / -Pc.z) + K.cx
        let v = K.fy * (-Pc.y / -Pc.z) + K.cy
        if u < -1 || v < -1 || u > Float(width) || v > Float(height) { return nil }
        return SIMD2(u, v)
    }

    /// Direction from panorama origin → LatLong UV using optical sphere convention.
    static func equirectUV(fromDirection dirWorld: simd_float3) -> SIMD2<Float> {
        let (yaw, pitch) = SphericalMath.sphereYawPitchFromOpticalForward(dirWorld)
        return SphericalMath.equirectangularUV(yawRad: yaw, pitchRad: pitch)
    }

    static func equirectPixel(
        direction: simd_float3,
        width: Int,
        height: Int
    ) -> (x: Float, y: Float) {
        let uv = equirectUV(fromDirection: direction)
        let x = uv.x * Float(width - 1)
        let y = uv.y * Float(height - 1)
        return (x, y)
    }

    enum PanoramaCenterMode: String, CaseIterable, Codable {
        case firstCamera
        case medianCameras
        case leastParallax
    }

    static func panoramaCenter(
        cameraCenters: [simd_float3],
        mode: PanoramaCenterMode
    ) -> simd_float3 {
        guard let first = cameraCenters.first else { return .zero }
        switch mode {
        case .firstCamera:
            return first
        case .medianCameras:
            return robustMedian(cameraCenters)
        case .leastParallax:
            // Weiszfeld-like geometric median (few iterations) — local least-parallax proxy.
            var c = robustMedian(cameraCenters)
            for _ in 0..<8 {
                var num = simd_float3.zero
                var den: Float = 0
                for p in cameraCenters {
                    let d = max(simd_length(p - c), 1e-4)
                    let w = 1 / d
                    num += p * w
                    den += w
                }
                if den > 0 { c = num / den }
            }
            return c
        }
    }

    static func robustMedian(_ pts: [simd_float3]) -> simd_float3 {
        guard !pts.isEmpty else { return .zero }
        let xs = pts.map(\.x).sorted()
        let ys = pts.map(\.y).sorted()
        let zs = pts.map(\.z).sorted()
        let m = pts.count / 2
        return simd_float3(xs[m], ys[m], zs[m])
    }

    /// Adaptive splat radius in LatLong pixels.
    static func splatRadius(
        depth: Float,
        viewCos: Float,
        sourceLongEdge: Float,
        outWidth: Int
    ) -> Float {
        let ang = max(0.15, min(1, abs(viewCos)))
        let footprint = (Float(outWidth) / max(sourceLongEdge, 1)) * (2.5 / max(depth, 0.5))
        let r = footprint / ang
        return max(0.6, min(2.8, r))
    }
}
