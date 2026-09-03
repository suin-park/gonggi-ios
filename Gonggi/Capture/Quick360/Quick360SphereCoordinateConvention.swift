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
/// RealityKit + SceneKit use `insideOutScale = (-1, 1, 1)` only (no texture H-flip).
///
/// ## Sphere mesh orientation
/// Live equirect is painted in a **gravity** yaw/pitch basis (V↑ = world up).
/// The display sphere must use the same gravity frame — **not** the raw ARKit camera
/// matrix. In portrait, ARKit camera +Y often lies along the phone short axis (≈ world
/// left/right), so parenting the sphere to `camera.transform` rotates patch content ~90°.
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

    /// Gravity-aligned sphere pose at capture origin (translation from camera, rotation roll-free).
    /// Mesh +Y tracks world up so equirect pitch matches gravity — fixes portrait 90° content.
    static func gravityAlignedSphereTransform(
        originCamera: simd_float4x4,
        worldUp: simd_float3 = Quick360CaptureBasis.gravityUp
    ) -> simd_float4x4? {
        guard let frame = Quick360StabilizedCameraFrame.make(
            fromCamera: originCamera,
            worldUp: worldUp
        ) else { return nil }
        let R = frame.rotation
        var m = matrix_identity_float4x4
        m.columns.0 = SIMD4<Float>(R.columns.0.x, R.columns.0.y, R.columns.0.z, 0)
        m.columns.1 = SIMD4<Float>(R.columns.1.x, R.columns.1.y, R.columns.1.z, 0)
        m.columns.2 = SIMD4<Float>(R.columns.2.x, R.columns.2.y, R.columns.2.z, 0)
        m.columns.3 = originCamera.columns.3
        return m
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

/// Compare raw equirect 2D vs production inside-out sphere (available in Release TestFlight).
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
