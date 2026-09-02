import ARKit
import CoreGraphics
import Foundation
import ImageIO
import simd
import UniformTypeIdentifiers

/// Converts ARFrame pixel buffers to analysis thumbnails and JPEG keyframes.
enum Quick360FrameEncoder {
    static let analysisWidth = 64
    static let analysisHeight = 36

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

    static func extractRGBA(from pixelBuffer: CVPixelBuffer) -> (rgba: [UInt8], width: Int, height: Int)? {
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }

        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        guard let base = CVPixelBufferGetBaseAddress(pixelBuffer) else { return nil }
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        var rgba = [UInt8](repeating: 0, count: width * height * 4)

        for y in 0..<height {
            let row = base.advanced(by: y * bytesPerRow).assumingMemoryBound(to: UInt8.self)
            for x in 0..<width {
                let bi = (y * width + x) * 4
                let yi = y * bytesPerRow + x * 4
                rgba[bi] = row[yi + 2]     // BGRA → RGBA
                rgba[bi + 1] = row[yi + 1]
                rgba[bi + 2] = row[yi]
                rgba[bi + 3] = 255
            }
        }
        return (rgba, width, height)
    }

    static func analysisGrayscale(from pixelBuffer: CVPixelBuffer) -> [UInt8] {
        guard let (rgba, w, h) = extractRGBA(from: pixelBuffer) else { return [] }
        return Quick360ImageAnalysis.downsampleGrayscale(
            rgba: rgba,
            srcWidth: w,
            srcHeight: h,
            dstWidth: analysisWidth,
            dstHeight: analysisHeight
        )
    }

    static func jpegData(from pixelBuffer: CVPixelBuffer, maxWidth: Int = Quick360Config.keyframeMaxPixelWidth) -> Data? {
        guard let (rgba, w, h) = extractRGBA(from: pixelBuffer) else { return nil }
        let scale = min(1, Float(maxWidth) / Float(w))
        let outW = max(1, Int(Float(w) * scale))
        let outH = max(1, Int(Float(h) * scale))
        let scaled = Quick360ImageAnalysis.downsampleGrayscale(
            rgba: rgba,
            srcWidth: w,
            srcHeight: h,
            dstWidth: outW,
            dstHeight: outH
        )
        // Re-expand grayscale to RGB for JPEG
        var rgb = [UInt8](repeating: 0, count: outW * outH * 4)
        for i in 0..<(outW * outH) {
            let g = scaled[i]
            let bi = i * 4
            rgb[bi] = g
            rgb[bi + 1] = g
            rgb[bi + 2] = g
            rgb[bi + 3] = 255
        }
        return jpegFromRGBA(rgb, width: outW, height: outH)
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
