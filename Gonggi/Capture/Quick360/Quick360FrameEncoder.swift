import ARKit
import CoreGraphics
import CoreImage
import Foundation
import ImageIO
import simd
import UIKit
import UniformTypeIdentifiers

/// Converts ARFrame pixel buffers to analysis thumbnails and JPEG keyframes.
///
/// ARKit `capturedImage` is typically `420YpCbCr8BiPlanarFullRange` (YUV), not BGRA.
/// Always convert via `CIContext` — never assume 4-byte BGRA row layout.
enum Quick360FrameEncoder {
    static let analysisWidth = 64
    static let analysisHeight = 36

    private static let ciContext = CIContext(options: [.cacheIntermediates: false])

    static func intrinsics(from frame: ARFrame) -> CameraIntrinsics {
        let matrix = frame.camera.intrinsics
        let resolution = frame.camera.imageResolution
        return CameraIntrinsics(
            fx: matrix[0][0],
            fy: matrix[1][1],
            cx: matrix[2][0],
            cy: matrix[2][1],
            width: Int(resolution.width),
            height: Int(resolution.height)
        )
    }

    /// Render CVPixelBuffer (any ARKit format) to owned RGBA8 bytes (sensor orientation).
    static func renderRGBA(
        from pixelBuffer: CVPixelBuffer,
        maxWidth: Int? = nil
    ) -> (rgba: [UInt8], width: Int, height: Int)? {
        renderRGBA(from: pixelBuffer, maxWidth: maxWidth, orientation: nil)
    }

    /// Brush source: apply interface orientation so portrait UI top/right matches thumb top/right.
    static func renderBrushRGBA(
        from pixelBuffer: CVPixelBuffer,
        maxWidth: Int,
        interfaceOrientation: UIInterfaceOrientation = Quick360BrushOrientation.primaryInterfaceOrientation
    ) -> (rgba: [UInt8], width: Int, height: Int)? {
        let orient = Quick360BrushOrientation.cgImageOrientation(for: interfaceOrientation)
        return renderRGBA(from: pixelBuffer, maxWidth: maxWidth, orientation: orient)
    }

    private static func renderRGBA(
        from pixelBuffer: CVPixelBuffer,
        maxWidth: Int?,
        orientation: CGImagePropertyOrientation?
    ) -> (rgba: [UInt8], width: Int, height: Int)? {
        var image = CIImage(cvPixelBuffer: pixelBuffer)
        if let orientation {
            // Image-space rotation only — do not bake pose offsets into sphere yaw.
            image = image.oriented(orientation)
        }
        image = image.transformed(by: CGAffineTransform(
            translationX: -image.extent.origin.x,
            y: -image.extent.origin.y
        ))
        let srcW = image.extent.width
        let srcH = image.extent.height
        guard srcW > 1, srcH > 1 else { return nil }

        if let maxWidth, max(srcW, srcH) > CGFloat(maxWidth) {
            let scale = CGFloat(maxWidth) / max(srcW, srcH)
            image = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            image = image.transformed(by: CGAffineTransform(
                translationX: -image.extent.origin.x,
                y: -image.extent.origin.y
            ))
        }

        let width = Int(image.extent.width.rounded(.down))
        let height = Int(image.extent.height.rounded(.down))
        guard width > 0, height > 0 else { return nil }

        var rgba = [UInt8](repeating: 0, count: width * height * 4)
        let bounds = CGRect(x: 0, y: 0, width: width, height: height)
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        ciContext.render(
            image,
            toBitmap: &rgba,
            rowBytes: width * 4,
            bounds: bounds,
            format: .RGBA8,
            colorSpace: colorSpace
        )
        return (rgba, width, height)
    }

    static func analysisGrayscale(from pixelBuffer: CVPixelBuffer) -> [UInt8] {
        guard let (rgba, w, h) = renderRGBA(from: pixelBuffer, maxWidth: analysisWidth * 4) else {
            return []
        }
        return Quick360ImageAnalysis.downsampleGrayscale(
            rgba: rgba,
            srcWidth: w,
            srcHeight: h,
            dstWidth: analysisWidth,
            dstHeight: analysisHeight
        )
    }

    static func jpegData(from pixelBuffer: CVPixelBuffer, maxWidth: Int = Quick360Config.keyframeMaxPixelWidth) -> Data? {
        // Portrait-bake pixels (same convention as live brush) so stitch K remap matches.
        // No EXIF orientation — upright is in the pixel buffer itself.
        guard let (rgba, w, h) = renderBrushRGBA(
            from: pixelBuffer,
            maxWidth: maxWidth,
            interfaceOrientation: Quick360BrushOrientation.primaryInterfaceOrientation
        ) else { return nil }
        return jpegFromRGBA(rgba, width: w, height: h)
    }

    /// Remap sensor intrinsics into portrait JPEG pixel space (matches `jpegData` / brush).
    static func portraitKeyframeIntrinsics(
        sensor: CameraIntrinsics,
        jpegWidth: Int,
        jpegHeight: Int
    ) -> CameraIntrinsics {
        let remapped = Quick360BrushOrientation.remappedIntrinsics(
            sensor,
            interface: Quick360BrushOrientation.primaryInterfaceOrientation
        )
        return Quick360PerspectiveProjection.scaledIntrinsics(
            remapped,
            thumbWidth: jpegWidth,
            thumbHeight: jpegHeight
        )
    }

    static func jpegFromRGBA(_ rgba: [UInt8], width: Int, height: Int) -> Data? {
        guard let provider = CGDataProvider(data: Data(rgba) as CFData) else { return nil }
        guard let cgImage = CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: true,
            intent: .defaultIntent
        ) else { return nil }

        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else {
            return nil
        }
        CGImageDestinationAddImage(dest, cgImage, [
            kCGImageDestinationLossyCompressionQuality: Quick360Config.keyframeJPEGQuality
        ] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return data as Data
    }

    static func loadRGBA(fromJPEG data: Data) -> (rgba: [UInt8], width: Int, height: Int)? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        let w = cgImage.width
        let h = cgImage.height
        var rgba = [UInt8](repeating: 0, count: w * h * 4)
        guard let ctx = CGContext(
            data: &rgba,
            width: w,
            height: h,
            bitsPerComponent: 8,
            bytesPerRow: w * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: w, height: h))
        return (rgba, w, h)
    }
}
