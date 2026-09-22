import Foundation
import simd

/// Geometric view-overlap estimate from camera poses only (assumed depth plane + FOV).
///
/// This is **not** image feature matching, optical flow, or COLMAP track continuity.
/// Do not treat a high score as proof of optical overlap or SfM reconstructability.
enum FrustumOverlapProxy {
    struct Sample: Equatable {
        /// Fraction of reference frustum depth-plane samples that project inside candidate FOV (0…1).
        var frustumOverlap: Double
        /// Angle between camera forward vectors (−Z in ARKit camera space), degrees.
        /// Formula: acos(dot(normalize(f_a), normalize(f_b))) where f = −R[:,2] of camera-to-world.
        var forwardAngleDeg: Double
        /// Absolute shortest-arc yaw delta (degrees). Yaw = atan2(f.x, f.z) in world XZ.
        /// Differs from forwardAngle: yaw ignores pitch; forwardAngle is full 3D direction change.
        var yawDeltaDeg: Double
        /// Euclidean translation between camera centers (meters).
        var translationM: Float

        var state: CaptureOverlapState {
            if frustumOverlap >= CaptureBridgeConfig.minFrustumOverlapAccept { return .good }
            if frustumOverlap <= CaptureBridgeConfig.frustumOverlapLost { return .lost }
            return .weak
        }
    }

    static func sample(
        from last: simd_float4x4,
        to candidate: simd_float4x4,
        assumedDepthM: Float = CaptureBridgeConfig.assumedSceneDepthM,
        horizontalFovDeg: Float = CaptureBridgeConfig.horizontalFovDeg,
        verticalFovDeg: Float = CaptureBridgeConfig.verticalFovDeg,
        grid: Int = 5
    ) -> Sample {
        let forwardAngle = Double(CaptureMath.rotationDeltaRadians(from: last, to: candidate)) * 180 / .pi
        let yawDelta = Double(abs(yawDegrees(from: last) - yawDegrees(from: candidate)))
        let yawShort = min(yawDelta, 360 - yawDelta)
        let translation = CaptureMath.translationMeters(from: last, to: candidate)

        let halfH = horizontalFovDeg * 0.5 * .pi / 180
        let halfV = verticalFovDeg * 0.5 * .pi / 180
        let candW2C = candidate.inverse

        var inside = 0
        var total = 0
        let g = max(2, grid)
        for iy in 0..<g {
            for ix in 0..<g {
                let u = (Float(ix) + 0.5) / Float(g) * 2 - 1
                let v = (Float(iy) + 0.5) / Float(g) * 2 - 1
                let dir = simd_normalize(simd_float3(
                    tan(halfH) * u,
                    tan(halfV) * v,
                    -1
                ))
                let camPt = dir * assumedDepthM
                let world = last * simd_float4(camPt.x, camPt.y, camPt.z, 1)
                let inCand = candW2C * world
                total += 1
                if inCand.z >= -1e-4 { continue } // behind candidate (ARKit −Z forward)
                let nx = atan2(inCand.x, -inCand.z)
                let ny = atan2(inCand.y, -inCand.z)
                if abs(nx) <= halfH && abs(ny) <= halfV {
                    inside += 1
                }
            }
        }
        let overlap = total == 0 ? 0 : Double(inside) / Double(total)
        return Sample(
            frustumOverlap: overlap,
            forwardAngleDeg: forwardAngle,
            yawDeltaDeg: yawShort,
            translationM: translation
        )
    }

    static func yawDegrees(from transform: simd_float4x4) -> Float {
        let f = CaptureMath.forwardVector(from: transform)
        return atan2(f.x, f.z) * 180 / .pi
    }
}

/// Backward-compatible name — prefer `FrustumOverlapProxy`.
typealias OpticalOverlapProxy = FrustumOverlapProxy
