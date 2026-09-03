import Foundation
import simd

/// FOV footprint diagnostics for Split Debug (same nx/ny convention as `Quick360LiveSphereBrush.paint`).
enum Quick360FOVDiagnostics {
    struct Corner: Equatable, Sendable {
        var label: String
        var yawRad: Float
        var pitchRad: Float
        var u: Float
        var v: Float

        var yawDeg: Float { yawRad * 180 / .pi }
        var pitchDeg: Float { pitchRad * 180 / .pi }
    }

    /// Portrait brush FOV: `nx = dyaw / halfFOVx`, `ny = -dpitch / halfFOVy`
    /// with image TL=(-1,-1), TR=(1,-1), BR=(1,1), BL=(-1,1).
    static func footprintCorners(
        centerYawRad: Float,
        centerPitchRad: Float,
        halfFOVx: Float,
        halfFOVy: Float
    ) -> [Corner] {
        let samples: [(String, Float, Float)] = [
            ("TL", -1, -1),
            ("TR", 1, -1),
            ("BR", 1, 1),
            ("BL", -1, 1)
        ]
        return samples.map { label, nx, ny in
            let yaw = centerYawRad + nx * halfFOVx
            let pitch = centerPitchRad - ny * halfFOVy
            let uv = SphericalMath.equirectangularUV(yawRad: yaw, pitchRad: pitch)
            return Corner(
                label: label,
                yawRad: yaw,
                pitchRad: pitch,
                u: uv.x,
                v: uv.y
            )
        }
    }

    /// True when all four corners stay near equirect center (normal forward FOV, no pole/seam jump).
    static func isCompactAroundCenter(
        _ corners: [Corner],
        maxAbsYawDeg: Float = 70,
        maxAbsPitchDeg: Float = 55,
        uRange: ClosedRange<Float> = 0.15...0.85,
        vRange: ClosedRange<Float> = 0.15...0.85
    ) -> Bool {
        guard corners.count == 4 else { return false }
        return corners.allSatisfy { c in
            abs(c.yawDeg) <= maxAbsYawDeg
                && abs(c.pitchDeg) <= maxAbsPitchDeg
                && uRange.contains(c.u)
                && vRange.contains(c.v)
        }
    }

    static func relativeRollRad(
        cameraTransform: simd_float4x4,
        originTransform: simd_float4x4
    ) -> Float {
        let relative = SphericalMath.relativeCameraTransform(
            cameraTransform: cameraTransform,
            originTransform: originTransform
        )
        // Optical frame: columns.0 = right, columns.1 = up.
        return atan2(relative.columns.0.y, relative.columns.1.y)
    }

    static func logCorners(_ corners: [Corner], prefix: String = "FOV corners") {
        let parts = corners.map { c in
            String(
                format: "%@ yaw=%.1f° pitch=%.1f° UV=(%.3f,%.3f)",
                c.label,
                c.yawDeg,
                c.pitchDeg,
                c.u,
                c.v
            )
        }
        Quick360Log.stage("\(prefix): \(parts.joined(separator: " | "))")
    }
}
