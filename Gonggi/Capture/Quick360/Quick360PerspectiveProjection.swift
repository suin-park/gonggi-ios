import Foundation
import simd

/// Perspective-correct brush projection helpers (intrinsics rays).
/// Sphere yaw/pitch uses `Quick360CaptureBasis` (gravity-aligned), not raw relative rotation.
///
/// Portrait brush convention (after `CIImage.oriented(.right)` + matching remapped intrinsics):
/// - image right (↑u) → camera local **+X**
/// - image up (↓v) → camera local **+Y**
/// - optical center → camera local **−Z**
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

    /// Portrait brush pixel → camera-space optical ray (+X right, +Y up, −Z forward).
    /// `pixelV` increases downward in the thumb buffer; Y is flipped so image-up → +Y.
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

    /// Debug / HUD: center, top-center, right-center camera rays for one thumb frame.
    static func sampleAxisRays(thumbIntrinsics: CameraIntrinsics) -> (
        center: simd_float3,
        topCenter: simd_float3,
        rightCenter: simd_float3
    ) {
        let cx = thumbIntrinsics.cx
        let cy = thumbIntrinsics.cy
        let rightU = Float(max(thumbIntrinsics.width - 1, 1))
        return (
            cameraRayFromPixel(pixelU: cx, pixelV: cy, thumbIntrinsics: thumbIntrinsics),
            cameraRayFromPixel(pixelU: cx, pixelV: 0, thumbIntrinsics: thumbIntrinsics),
            cameraRayFromPixel(pixelU: rightU, pixelV: cy, thumbIntrinsics: thumbIntrinsics)
        )
    }

    /// Gravity-basis yaw/pitch for the three axis sample rays (identity-aligned camera expected).
    static func sampleAxisYawPitch(
        thumbIntrinsics: CameraIntrinsics,
        cameraTransform: simd_float4x4,
        basis: Quick360CaptureBasis
    ) -> (
        center: (yaw: Float, pitch: Float),
        topCenter: (yaw: Float, pitch: Float),
        rightCenter: (yaw: Float, pitch: Float)
    ) {
        let cx = thumbIntrinsics.cx
        let cy = thumbIntrinsics.cy
        let rightU = Float(max(thumbIntrinsics.width - 1, 1))
        return (
            basis.sphereYawPitchFromPixel(
                pixelU: cx, pixelV: cy, thumbIntrinsics: thumbIntrinsics, cameraTransform: cameraTransform
            ),
            basis.sphereYawPitchFromPixel(
                pixelU: cx, pixelV: 0, thumbIntrinsics: thumbIntrinsics, cameraTransform: cameraTransform
            ),
            basis.sphereYawPitchFromPixel(
                pixelU: rightU, pixelV: cy, thumbIntrinsics: thumbIntrinsics, cameraTransform: cameraTransform
            )
        )
    }

    /// Normalized image UV (0…1) → camera ray.
    static func cameraRayFromNormalizedUV(
        u: Float,
        v: Float,
        thumbIntrinsics: CameraIntrinsics
    ) -> simd_float3 {
        let pixelU = u * Float(max(thumbIntrinsics.width - 1, 1))
        let pixelV = v * Float(max(thumbIntrinsics.height - 1, 1))
        return cameraRayFromPixel(pixelU: pixelU, pixelV: pixelV, thumbIntrinsics: thumbIntrinsics)
    }

    /// Four image-corner rays → gravity-basis sphere yaw/pitch/UV.
    static func footprintCorners(
        thumbIntrinsics: CameraIntrinsics,
        cameraTransform: simd_float4x4,
        basis: Quick360CaptureBasis
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
            let (yaw, pitch) = basis.sphereYawPitchFromPixel(
                pixelU: pu,
                pixelV: pv,
                thumbIntrinsics: thumbIntrinsics,
                cameraTransform: cameraTransform
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
    var opaqueReplace: Bool
    var enableFeather: Bool

    static let production = Quick360BrushPaintOptions(opaqueReplace: false, enableFeather: true)
    static let singleFrameDebug = Quick360BrushPaintOptions(opaqueReplace: true, enableFeather: false)
}
