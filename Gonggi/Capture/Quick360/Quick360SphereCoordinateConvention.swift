import CoreGraphics
import Foundation
import simd
import UIKit

/// Shared sphere / equirect conventions for **live capture** and **final 360 viewer**.
///
/// Do **not** invent ±90° texture rotations, extra yaw offsets, or horizontal mirrors
/// outside this helper. Portrait sensor→brush remapping stays in `Quick360BrushOrientation`.
///
/// ## Inside-out display
/// RealityKit + SceneKit use `insideOutScale = (-1, 1, 1)` only.
/// Negative X flips winding (see inside) **and** mirrors mesh U — that mirror is the
/// correct handedness for equirect skyboxes. Do **not** also horizontally flip the
/// texture (that was a duplicate compensation and, via CGBitmapContext redraw, could
/// introduce an unintended vertical flip → large rotate/flip on the sphere).
enum Quick360SphereCoordinateConvention {
    /// Inside-out display scale (negative X). Capture RealityKit + SceneKit viewer share this.
    static let insideOutScale = SIMD3<Float>(-1, 1, 1)

    /// Equirect UV from sphere yaw/pitch — same formula as live brush / stitch.
    static func equirectangularUV(yawRad: Float, pitchRad: Float) -> SIMD2<Float> {
        SphericalMath.equirectangularUV(yawRad: yawRad, pitchRad: pitchRad)
    }

    /// Optical forward for sphere brush: yaw=0,pitch=0 → camera local −Z.
    static func opticalForward(yawRad: Float, pitchRad: Float) -> simd_float3 {
        SphericalMath.opticalDirectionFromSphereYawPitch(yawRad: yawRad, pitchRad: pitchRad)
    }

    /// Prepare equirect for an inside-out mesh that already uses `insideOutScale`.
    /// Pass-through: raw brush/stitch pixels — no horizontal flip, no ±90° rotation.
    static func prepareEquirectTextureForInsideOut(_ image: CGImage) -> CGImage? {
        image
    }

    static func prepareEquirectTextureForInsideOut(uiImage: UIImage) -> UIImage? {
        guard let cg = uiImage.cgImage,
              let prepared = prepareEquirectTextureForInsideOut(cg) else { return nil }
        return UIImage(cgImage: prepared, scale: uiImage.scale, orientation: .up)
    }
}

/// DEBUG comparison: raw equirect 2D vs production inside-out sphere.
enum Quick360SphereDisplayDebugMode: String, CaseIterable, Equatable {
    case sphere
    case raw2D

    var label: String {
        switch self {
        case .sphere: return "SPHERE"
        case .raw2D: return "RAW 2D"
        }
    }
}
