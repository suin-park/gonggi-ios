import CoreImage
import Foundation
import ImageIO
import UIKit
import UniformTypeIdentifiers

/// Writes reconstruction JPEGs in **ARKit sensor pixel space** (matches `ARCamera.intrinsics`).
/// Does not apply UI/portrait orientation bake — unlike Quick360 brush keyframes.
enum SpatialKeyframeJPEGWriter {
    private static let ciContext = CIContext(options: [.cacheIntermediates: false])

    struct WriteResult: Equatable {
        var byteCount: Int
        var width: Int
        var height: Int
        var encodeMs: Double
        var writeMs: Double
        /// EXIF Orientation tag written (always 1 = identity for sensor-space pixels).
        var exifOrientation: Int
    }

    static func write(
        pixelBuffer: CVPixelBuffer,
        to url: URL,
        compressionQuality: CGFloat = SpatialCaptureConfig.jpegCompressionQuality,
        maxLongEdge: Int? = SpatialCaptureConfig.jpegMaxLongEdge,
        principalPoint: (cx: Float, cy: Float)? = nil
    ) throws -> WriteResult {
        let encodeStart = CFAbsoluteTimeGetCurrent()

        var image = CIImage(cvPixelBuffer: pixelBuffer)
        // Identity orientation — do not apply `.right` / portrait bake.
        image = image.transformed(by: CGAffineTransform(
            translationX: -image.extent.origin.x,
            y: -image.extent.origin.y
        ))
        let srcW = image.extent.width
        let srcH = image.extent.height
        guard srcW > 1, srcH > 1 else {
            throw WriteError.emptyImage
        }

        if let maxLongEdge, max(srcW, srcH) > CGFloat(maxLongEdge) {
            let scale = CGFloat(maxLongEdge) / max(srcW, srcH)
            image = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            image = image.transformed(by: CGAffineTransform(
                translationX: -image.extent.origin.x,
                y: -image.extent.origin.y
            ))
        }

        let width = Int(image.extent.width.rounded(.down))
        let height = Int(image.extent.height.rounded(.down))
        guard width > 0, height > 0 else { throw WriteError.emptyImage }
        guard var cgImage = ciContext.createCGImage(image, from: CGRect(x: 0, y: 0, width: width, height: height)) else {
            throw WriteError.renderFailed
        }

        if let principalPoint {
            let scaleX = srcW > 0 ? CGFloat(width) / srcW : 1
            let scaleY = srcH > 0 ? CGFloat(height) / srcH : 1
            cgImage = drawPrincipalPoint(
                on: cgImage,
                cx: CGFloat(principalPoint.cx) * scaleX,
                cy: CGFloat(principalPoint.cy) * scaleY
            ) ?? cgImage
        }

        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw WriteError.destinationFailed
        }
        // Explicit EXIF Orientation = 1 so consumers don't rotate sensor-space pixels.
        let exifOrientation = 1
        let props: [CFString: Any] = [
            kCGImageDestinationLossyCompressionQuality: compressionQuality,
            kCGImagePropertyOrientation: exifOrientation,
        ]
        CGImageDestinationAddImage(dest, cgImage, props as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { throw WriteError.finalizeFailed }

        let encodeMs = (CFAbsoluteTimeGetCurrent() - encodeStart) * 1000

        let writeStart = CFAbsoluteTimeGetCurrent()
        try (data as Data).write(to: url, options: [.atomic])
        let writeMs = (CFAbsoluteTimeGetCurrent() - writeStart) * 1000

        return WriteResult(
            byteCount: data.length,
            width: width,
            height: height,
            encodeMs: encodeMs,
            writeMs: writeMs,
            exifOrientation: exifOrientation
        )
    }

    private static func drawPrincipalPoint(on image: CGImage, cx: CGFloat, cy: CGFloat) -> CGImage? {
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

        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        ctx.setStrokeColor(UIColor.systemRed.cgColor)
        ctx.setLineWidth(3)
        // ARKit / JPEG pixel coords are top-left origin; CGContext bitmap is bottom-left.
        let y = CGFloat(h) - cy
        let arm: CGFloat = 28
        ctx.move(to: CGPoint(x: cx - arm, y: y))
        ctx.addLine(to: CGPoint(x: cx + arm, y: y))
        ctx.move(to: CGPoint(x: cx, y: y - arm))
        ctx.addLine(to: CGPoint(x: cx, y: y + arm))
        ctx.strokePath()
        ctx.setFillColor(UIColor.systemYellow.cgColor)
        ctx.fillEllipse(in: CGRect(x: cx - 4, y: y - 4, width: 8, height: 8))
        return ctx.makeImage()
    }

    enum WriteError: Error {
        case emptyImage
        case renderFailed
        case destinationFailed
        case finalizeFailed
    }
}
