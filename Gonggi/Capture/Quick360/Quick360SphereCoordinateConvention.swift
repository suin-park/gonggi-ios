import CoreGraphics
import Foundation
import simd
import UIKit

/// Shared sphere / equirect conventions for **live capture** and **final 360 viewer**.
///
/// Do **not** invent ±90° texture rotations, extra yaw offsets, or horizontal mirrors
/// outside this helper. Portrait sensor→brush remapping stays in `Quick360BrushOrientation`.
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

    /// Prepare equirect CGImage for inside-out mesh (`scale.x = -1`).
    /// Horizontal flip cancels UV mirroring from negative X — does not change yaw math.
    static func prepareEquirectTextureForInsideOut(_ image: CGImage) -> CGImage? {
        let w = image.width
        let h = image.height
        guard let ctx = CGContext(
            data: nil,
            width: w,
            height: h,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        ctx.translateBy(x: CGFloat(w), y: 0)
        ctx.scaleBy(x: -1, y: 1)
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage()
    }

    static func prepareEquirectTextureForInsideOut(uiImage: UIImage) -> UIImage? {
        guard let cg = uiImage.cgImage,
              let flipped = prepareEquirectTextureForInsideOut(cg) else { return nil }
        return UIImage(cgImage: flipped, scale: uiImage.scale, orientation: .up)
    }
}
