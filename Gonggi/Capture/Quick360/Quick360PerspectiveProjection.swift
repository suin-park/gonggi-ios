import Foundation
import simd

/// Perspective-correct brush projection: pixel → camera ray → relative rotation → sphere yaw/pitch.
///
/// Does **not** use centerYaw±halfFOV / centerPitch±halfFOV linear FOV boxes.
enum Quick360PerspectiveProjection {
    /// Scale oriented (full-res) intrinsics into brush thumbnail pixel space.
    static func scaledIntrinsics(
        _ oriented: CameraIntrinsics,
        thumbWidth: Int,
        thumbHeight: Int
    ) -> CameraIntrinsics {
        let sw = max(Float(oriented.width), 1)
        let sh = max(Float(oriented.height), 1)
        let sx = Float(thumbWidth) / sw
        let sy = Float(thumbHeight) / sh
        return CameraIntrinsics(
            fx: oriented.fx * sx,
            fy: oriented.fy * sy,
            cx: oriented.cx * sx,
            cy: oriented.cy * sy,
            width: thumbWidth,
            height: thumbHeight
        )
    }

    /// 3×3 rotation of `relative = inverse(origin) * camera` (camera axes in origin/sphere space).
    static func relativeRotation(
        cameraTransform: simd_float4x4,
        originTransform: simd_float4x4
    ) -> simd_float3x3 {
        let relative = SphericalMath.relativeCameraTransform(
            cameraTransform: cameraTransform,
            originTransform: originTransform
        )
        return simd_float3x3(
            SIMD3(relative.columns.0.x, relative.columns.0.y, relative.columns.0.z),
            SIMD3(relative.columns.1.x, relative.columns.1.y, relative.columns.1.z),
            SIMD3(relative.columns.2.x, relative.columns.2.y, relative.columns.2.z)
        )
    }

    /// Portrait brush pixel → camera-space optical ray (+X right, +Y up, −Z forward).
    /// `pixelU` / `pixelV` in thumbnail coordinates (v increases downward).
    static func cameraRayFromPixel(
        pixelU: Float,
        pixelV: Float,
        thumbIntrinsics: CameraIntrinsics
    ) -> simd_float3 {
        let fx = max(thumbIntrinsics.fx, 1e-4)
        let fy = max(thumbIntrinsics.fy, 1e-4)
        let x = (pixelU - thumbIntrinsics.cx) / fx
        let y = -(pixelV - thumbIntrinsics.cy) / fy
        return simd_normalize(simd_float3(x, y, -1))
    }

    /// Normalized image UV (0…1) → camera ray (same convention as `cameraRayFromPixel`).
    static func cameraRayFromNormalizedUV(
        u: Float,
        v: Float,
        thumbIntrinsics: CameraIntrinsics
    ) -> simd_float3 {
        let pixelU = u * Float(max(thumbIntrinsics.width - 1, 1))
        let pixelV = v * Float(max(thumbIntrinsics.height - 1, 1))
        return cameraRayFromPixel(pixelU: pixelU, pixelV: pixelV, thumbIntrinsics: thumbIntrinsics)
    }

    /// Camera-local ray → origin/sphere-space direction via relative camera rotation.
    static func sphereDirection(
        cameraRay: simd_float3,
        relativeRotation: simd_float3x3
    ) -> simd_float3 {
        simd_normalize(relativeRotation * cameraRay)
    }

    /// Full chain: pixel → ray → relative R → sphere yaw/pitch (optical −Z → yaw0/pitch0).
    static func sphereYawPitchFromPixel(
        pixelU: Float,
        pixelV: Float,
        thumbIntrinsics: CameraIntrinsics,
        relativeRotation: simd_float3x3
    ) -> (yaw: Float, pitch: Float) {
        let ray = cameraRayFromPixel(pixelU: pixelU, pixelV: pixelV, thumbIntrinsics: thumbIntrinsics)
        let dir = sphereDirection(cameraRay: ray, relativeRotation: relativeRotation)
        return SphericalMath.sphereYawPitchFromOpticalForward(dir)
    }

    /// Reverse: sphere direction → camera pixel (nil if behind camera or outside image+pad).
    static func projectSphereDirectionToPixel(
        sphereDirection: simd_float3,
        relativeRotation: simd_float3x3,
        thumbIntrinsics: CameraIntrinsics,
        edgePad: Float = 0.5
    ) -> SIMD2<Float>? {
        // dir_cam = R^T * dir_sphere (R orthonormal).
        let dirCam = simd_normalize(simd_transpose(relativeRotation) * sphereDirection)
        let depth = -dirCam.z
        guard depth > 1e-5 else { return nil }
        let u = thumbIntrinsics.fx * (dirCam.x / depth) + thumbIntrinsics.cx
        let v = thumbIntrinsics.fy * (-dirCam.y / depth) + thumbIntrinsics.cy
        let maxU = Float(thumbIntrinsics.width - 1) + edgePad
        let maxV = Float(thumbIntrinsics.height - 1) + edgePad
        guard u >= -edgePad, v >= -edgePad, u <= maxU, v <= maxV else { return nil }
        return SIMD2(u, v)
    }

    /// Four image-corner rays → sphere yaw/pitch/UV (not a linear ±halfFOV rectangle).
    static func footprintCorners(
        thumbIntrinsics: CameraIntrinsics,
        relativeRotation: simd_float3x3
    ) -> [Quick360FOVDiagnostics.Corner] {
        let w = Float(max(thumbIntrinsics.width - 1, 1))
        let h = Float(max(thumbIntrinsics.height - 1, 1))
        let samples: [(String, Float, Float)] = [
            ("TL", 0, 0),
            ("TR", w, 0),
            ("BR", w, h),
            ("BL", 0, h)
        ]
        return samples.map { label, pu, pv in
            let (yaw, pitch) = sphereYawPitchFromPixel(
                pixelU: pu,
                pixelV: pv,
                thumbIntrinsics: thumbIntrinsics,
                relativeRotation: relativeRotation
            )
            let uv = SphericalMath.equirectangularUV(yawRad: yaw, pitchRad: pitch)
            return Quick360FOVDiagnostics.Corner(
                label: label,
                yawRad: yaw,
                pitchRad: pitch,
                u: uv.x,
                v: uv.y
            )
        }
    }

    /// Equirect scan bounds covering the perspective FOV footprint (with pad).
    static func equirectScanBounds(
        corners: [Quick360FOVDiagnostics.Corner],
        equirectWidth: Int,
        equirectHeight: Int,
        padPixels: Int = 3
    ) -> (x0: Int, x1: Int, y0: Int, y1: Int, wrapsSeam: Bool) {
        guard !corners.isEmpty else {
            return (0, equirectWidth - 1, 0, equirectHeight - 1, false)
        }
        let us = corners.map(\.u)
        let vs = corners.map(\.v)
        let minV = vs.min() ?? 0
        let maxV = vs.max() ?? 1
        let y0 = max(0, Int(floor(minV * Float(equirectHeight - 1))) - padPixels)
        let y1 = min(equirectHeight - 1, Int(ceil(maxV * Float(equirectHeight - 1))) + padPixels)

        let minU = us.min() ?? 0
        let maxU = us.max() ?? 1
        // If FOV straddles the equirect seam, scan full width.
        let wraps = (maxU - minU) > 0.55
        if wraps {
            return (0, equirectWidth - 1, y0, y1, true)
        }
        let x0 = max(0, Int(floor(minU * Float(equirectWidth - 1))) - padPixels)
        let x1 = min(equirectWidth - 1, Int(ceil(maxU * Float(equirectWidth - 1))) + padPixels)
        return (x0, x1, y0, y1, false)
    }
}

/// Options for live sphere brush paint (Test A uses opaque replace, no feather).
struct Quick360BrushPaintOptions: Equatable, Sendable {
    /// Opaque write; ignore previous confidence / no alpha blend.
    var opaqueReplace: Bool
    /// Soft FOV edge feather (production continuous brush).
    var enableFeather: Bool

    static let production = Quick360BrushPaintOptions(opaqueReplace: false, enableFeather: true)
    static let singleFrameDebug = Quick360BrushPaintOptions(opaqueReplace: true, enableFeather: false)
}
