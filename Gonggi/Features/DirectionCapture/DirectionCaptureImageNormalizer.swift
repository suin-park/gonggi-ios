import UIKit

/// Ensures DirectionCapture JPEGs have upright pixels (not EXIF-tag-only).
/// Portrait-app convention: final buffer height ≥ width when source was landscape sensor.
enum DirectionCaptureImageNormalizer {
    struct Result: Equatable {
        let image: UIImage
        /// Raw `UIImage.Orientation` before bake.
        let sourceOrientationRaw: Int
        /// True when pixels were redrawn/rotated (bake and/or landscape→portrait).
        let pixelRotationApplied: Bool
        let finalPixelWidth: Int
        let finalPixelHeight: Int
    }

    /// Bake UIImage orientation into pixels, then ensure portrait (H ≥ W) when needed.
    static func normalizeForUpload(_ image: UIImage) -> Result {
        let sourceOrientationRaw = image.imageOrientation.rawValue
        let didBake = image.imageOrientation != .up
        let baked = bakeOrientationIntoPixels(image)
        let (portrait, didRotateLandscape) = ensurePortraitPixels(baked)
        let cg = portrait.cgImage
        let w = cg?.width ?? Int(portrait.size.width.rounded())
        let h = cg?.height ?? Int(portrait.size.height.rounded())
        return Result(
            image: portrait,
            sourceOrientationRaw: sourceOrientationRaw,
            pixelRotationApplied: didBake || didRotateLandscape,
            finalPixelWidth: w,
            finalPixelHeight: h
        )
    }

    /// Draw applying UIImage orientation so CGImage pixels are upright and orientation == .up.
    static func bakeOrientationIntoPixels(_ image: UIImage) -> UIImage {
        if image.imageOrientation == .up, let cg = image.cgImage {
            return UIImage(cgImage: cg, scale: image.scale, orientation: .up)
        }
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = image.scale
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: image.size, format: format)
        let drawn = renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: image.size))
        }
        guard let cg = drawn.cgImage else { return drawn }
        return UIImage(cgImage: cg, scale: image.scale, orientation: .up)
    }

    /// If pixels are landscape (W > H), rotate 90° CW into portrait (matches preview pipeline).
    static func ensurePortraitPixels(_ image: UIImage) -> (UIImage, Bool) {
        guard let cg = image.cgImage else { return (image, false) }
        let w = cg.width
        let h = cg.height
        guard PanoramaFrameOrientation.needsLandscapeToPortraitRotate(width: w, height: h) else {
            return (UIImage(cgImage: cg, scale: image.scale, orientation: .up), false)
        }

        let scale = image.scale
        let srcPoints = CGSize(width: CGFloat(w) / scale, height: CGFloat(h) / scale)
        let dstPoints = CGSize(width: srcPoints.height, height: srcPoints.width)
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = scale
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: dstPoints, format: format)
        let uprightSource = UIImage(cgImage: cg, scale: scale, orientation: .up)
        let out = renderer.image { ctx in
            let c = ctx.cgContext
            c.translateBy(x: dstPoints.width, y: 0)
            c.rotate(by: .pi / 2)
            uprightSource.draw(in: CGRect(origin: .zero, size: srcPoints))
        }
        guard let outCG = out.cgImage else {
            return (UIImage(cgImage: cg, scale: scale, orientation: .up), false)
        }
        return (UIImage(cgImage: outCG, scale: scale, orientation: .up), true)
    }
}
