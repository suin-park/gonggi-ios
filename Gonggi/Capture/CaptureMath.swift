import Foundation
import simd

/// Pure math helpers (testable without ARKit).
enum CaptureMath {
    static func translationMeters(from a: simd_float4x4, to b: simd_float4x4) -> Float {
        let pa = simd_float3(a.columns.3.x, a.columns.3.y, a.columns.3.z)
        let pb = simd_float3(b.columns.3.x, b.columns.3.y, b.columns.3.z)
        return simd_distance(pa, pb)
    }

    static func rotationDeltaRadians(from a: simd_float4x4, to b: simd_float4x4) -> Float {
        let fa = forwardVector(from: a)
        let fb = forwardVector(from: b)
        let dot = simd_clamp(simd_dot(fa, fb), -1, 1)
        return acos(dot)
    }

    static func forwardVector(from transform: simd_float4x4) -> simd_float3 {
        let col = transform.columns.2
        return simd_normalize(simd_float3(-col.x, -col.y, -col.z))
    }

    /// Quantize camera forward into view bucket for angle diversity.
    static func viewBucket(for transform: simd_float4x4, buckets: Int = 12) -> Int {
        let f = forwardVector(from: transform)
        let yaw = atan2(f.x, f.z)
        let normalized = (yaw + .pi) / (2 * .pi)
        return min(buckets - 1, max(0, Int(normalized * Float(buckets))))
    }

    /// World-space grid cell from camera position (0.5 m cells).
    static func gridCellId(position: simd_float3, cellSize: Float = 0.5) -> String {
        let ix = Int(floor(position.x / cellSize))
        let iy = Int(floor(position.y / cellSize))
        let iz = Int(floor(position.z / cellSize))
        return "\(ix)_\(iy)_\(iz)"
    }

    static func speeds(
        translationM: Float,
        rotationRad: Float,
        deltaTimeSec: Float
    ) -> (translationMps: Float, angularRadPerSec: Float) {
        guard deltaTimeSec > 1e-4 else { return (0, 0) }
        return (translationM / deltaTimeSec, rotationRad / deltaTimeSec)
    }
}
