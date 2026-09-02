import Foundation
import simd

/// Pure spherical / equirectangular math (testable without ARKit).
enum SphericalMath {
    static func forwardVector(from transform: simd_float4x4) -> simd_float3 {
        let col = transform.columns.2
        return simd_normalize(simd_float3(-col.x, -col.y, -col.z))
    }

    static func yawPitchRad(from transform: simd_float4x4) -> (yaw: Float, pitch: Float) {
        let f = forwardVector(from: transform)
        let yaw = atan2(f.x, f.z)
        let pitch = asin(simd_clamp(f.y, -1, 1))
        return (yaw, pitch)
    }

    /// Yaw/pitch relative to origin camera orientation.
    static func relativeYawPitchRad(
        cameraTransform: simd_float4x4,
        originTransform: simd_float4x4
    ) -> (yaw: Float, pitch: Float) {
        let originYaw = yawPitchRad(from: originTransform).yaw
        let (yaw, pitch) = yawPitchRad(from: cameraTransform)
        var relativeYaw = yaw - originYaw
        while relativeYaw > .pi { relativeYaw -= 2 * .pi }
        while relativeYaw < -.pi { relativeYaw += 2 * .pi }
        return (relativeYaw, pitch)
    }

    static func yawPitchDeg(from transform: simd_float4x4) -> (yaw: Float, pitch: Float) {
        let (y, p) = yawPitchRad(from: transform)
        return (y * 180 / .pi, p * 180 / .pi)
    }

    static func directionVector(yawRad: Float, pitchRad: Float) -> simd_float3 {
        let cosPitch = cos(pitchRad)
        return simd_normalize(simd_float3(
            sin(yawRad) * cosPitch,
            sin(pitchRad),
            cos(yawRad) * cosPitch
        ))
    }

    static func angularDistanceRad(
        yawA: Float, pitchA: Float,
        yawB: Float, pitchB: Float
    ) -> Float {
        let a = directionVector(yawRad: yawA, pitchRad: pitchA)
        let b = directionVector(yawRad: yawB, pitchRad: pitchB)
        return acos(simd_clamp(simd_dot(a, b), -1, 1))
    }

    static func angularDistanceDeg(
        yawA: Float, pitchA: Float,
        yawB: Float, pitchB: Float
    ) -> Float {
        angularDistanceRad(yawA: yawA, pitchA: pitchA, yawB: yawB, pitchB: pitchB) * 180 / .pi
    }

    /// Equirectangular UV (0…1) from yaw/pitch in radians.
    /// yaw: -π…π, pitch: -π/2…π/2
    static func equirectangularUV(yawRad: Float, pitchRad: Float) -> SIMD2<Float> {
        let u = (yawRad + .pi) / (2 * .pi)
        let v = (.pi / 2 - pitchRad) / .pi
        return SIMD2(u, simd_clamp(v, 0, 1))
    }

    /// Pixel coordinates in 2:1 equirectangular canvas.
    static func equirectangularPixel(
        yawRad: Float,
        pitchRad: Float,
        width: Int,
        height: Int
    ) -> SIMD2<Int> {
        let uv = equirectangularUV(yawRad: yawRad, pitchRad: pitchRad)
        let x = Int((uv.x * Float(width - 1)).rounded())
        let y = Int((uv.y * Float(height - 1)).rounded())
        return SIMD2(
            min(max(x, 0), width - 1),
            min(max(y, 0), height - 1)
        )
    }

    /// Direction from pixel in equirectangular image.
    static func directionFromEquirectangularPixel(
        x: Int,
        y: Int,
        width: Int,
        height: Int
    ) -> simd_float3 {
        let u = Float(x) / Float(max(width - 1, 1))
        let v = Float(y) / Float(max(height - 1, 1))
        let yaw = u * 2 * .pi - .pi
        let pitch = .pi / 2 - v * .pi
        return directionVector(yawRad: yaw, pitchRad: pitch)
    }

    static func normalizeYawDeg(_ deg: Float) -> Float {
        var d = deg.truncatingRemainder(dividingBy: 360)
        if d < 0 { d += 360 }
        return d
    }

    static func isValidEquirectangularAspect(width: Int, height: Int) -> Bool {
        guard height > 0 else { return false }
        let ratio = Double(width) / Double(height)
        return abs(ratio - 2.0) < 0.02
    }
}
