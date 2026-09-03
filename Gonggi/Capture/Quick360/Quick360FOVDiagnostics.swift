import Foundation
import simd

/// FOV footprint diagnostics for Split Debug (perspective corner rays).
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

    /// Perspective FOV corners from oriented+scaled brush intrinsics and relative camera rotation.
    static func footprintCorners(
        thumbIntrinsics: CameraIntrinsics,
        relativeRotation: simd_float3x3
    ) -> [Corner] {
        Quick360PerspectiveProjection.footprintCorners(
            thumbIntrinsics: thumbIntrinsics,
            relativeRotation: relativeRotation
        )
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
