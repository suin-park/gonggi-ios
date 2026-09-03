import Foundation
import simd

/// FOV footprint diagnostics for Split Debug (perspective corner rays in gravity basis).
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

    static func footprintCorners(
        thumbIntrinsics: CameraIntrinsics,
        cameraTransform: simd_float4x4,
        basis: Quick360CaptureBasis
    ) -> [Corner] {
        Quick360PerspectiveProjection.footprintCorners(
            thumbIntrinsics: thumbIntrinsics,
            cameraTransform: cameraTransform,
            basis: basis
        )
    }

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

    /// Log portrait axis sample rays (camera local + gravity yaw/pitch).
    static func logAxisRays(
        center: simd_float3,
        topCenter: simd_float3,
        rightCenter: simd_float3,
        yawPitch: (
            center: (yaw: Float, pitch: Float),
            topCenter: (yaw: Float, pitch: Float),
            rightCenter: (yaw: Float, pitch: Float)
        )?
    ) {
        Quick360Log.stage(
            String(
                format: "axisRays cam: C=(%.3f,%.3f,%.3f) T=(%.3f,%.3f,%.3f) R=(%.3f,%.3f,%.3f)",
                center.x, center.y, center.z,
                topCenter.x, topCenter.y, topCenter.z,
                rightCenter.x, rightCenter.y, rightCenter.z
            )
        )
        if let yp = yawPitch {
            Quick360Log.stage(
                String(
                    format: "axisRays grav°: C=%.1f/%.1f T=%.1f/%.1f R=%.1f/%.1f (expect T↑pitch R↑yaw)",
                    yp.center.yaw * 180 / .pi, yp.center.pitch * 180 / .pi,
                    yp.topCenter.yaw * 180 / .pi, yp.topCenter.pitch * 180 / .pi,
                    yp.rightCenter.yaw * 180 / .pi, yp.rightCenter.pitch * 180 / .pi
                )
            )
        }
    }

    static func logStabilizedFrame(
        frame: Quick360StabilizedCameraFrame,
        worldRays: (center: simd_float3, topCenter: simd_float3, rightCenter: simd_float3),
        rawRollDeg: Float
    ) {
        Quick360Log.stage(
            String(
                format: "stabFrame rollRaw=%.1f° R=(%.3f,%.3f,%.3f) U=(%.3f,%.3f,%.3f) F=(%.3f,%.3f,%.3f)",
                rawRollDeg,
                frame.right.x, frame.right.y, frame.right.z,
                frame.up.x, frame.up.y, frame.up.z,
                frame.forward.x, frame.forward.y, frame.forward.z
            )
        )
        Quick360Log.stage(
            String(
                format: "stabWorldRays C=(%.3f,%.3f,%.3f) T=(%.3f,%.3f,%.3f) R=(%.3f,%.3f,%.3f)",
                worldRays.center.x, worldRays.center.y, worldRays.center.z,
                worldRays.topCenter.x, worldRays.topCenter.y, worldRays.topCenter.z,
                worldRays.rightCenter.x, worldRays.rightCenter.y, worldRays.rightCenter.z
            )
        )
    }
}
