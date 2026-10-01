import CoreGraphics
import CoreVideo
import Foundation
import Vision

/// Runs Vision's foreground instance mask on one image and hands the label map to `ObjectProductEvidenceRule`.
///
/// Synchronous, meant for a background queue. It never touches the AR session and never throws: every failure is
/// reported as `.unknown(.failed)` so the caller falls back to the box rule. The image is analysed exactly as it is
/// (sensor orientation, no rotation), so mask and projected box share one coordinate system.
final class ObjectProductSegmenter {
    init() {}

    /// App path: a copy of the camera frame (bi-planar YCbCr; plane 0 is luma).
    func analyze(pixelBuffer: CVPixelBuffer, hull: [CGPoint], baseFace: [CGPoint]) -> ObjectProductEvidence {
        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .up, options: [:])
        return analyze(
            handler: handler,
            lumaAt: { width, height in Self.lumaPlane(of: pixelBuffer, width: width, height: height) },
            hull: hull,
            baseFace: baseFace
        )
    }

    /// Validation-tool path: a decoded image.
    func analyze(cgImage: CGImage, hull: [CGPoint], baseFace: [CGPoint]) -> ObjectProductEvidence {
        let handler = VNImageRequestHandler(cgImage: cgImage, orientation: .up, options: [:])
        return analyze(
            handler: handler,
            lumaAt: { width, height in Self.lumaPlane(of: cgImage, width: width, height: height) },
            hull: hull,
            baseFace: baseFace
        )
    }

    private func analyze(
        handler: VNImageRequestHandler,
        lumaAt: (_ width: Int, _ height: Int) -> [UInt8]?,
        hull: [CGPoint],
        baseFace: [CGPoint]
    ) -> ObjectProductEvidence {
        let request = VNGenerateForegroundInstanceMaskRequest()
        do {
            try handler.perform([request])
        } catch {
            return .unknown(.failed)
        }
        guard let observation = request.results?.first else { return .unknown(.noCandidateInBox) }
        let mask = observation.instanceMask
        CVPixelBufferLockBaseAddress(mask, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(mask, .readOnly) }
        let width = CVPixelBufferGetWidth(mask)
        let height = CVPixelBufferGetHeight(mask)
        guard width > 0, height > 0,
              CVPixelBufferGetPixelFormatType(mask) == kCVPixelFormatType_OneComponent8,
              let base = CVPixelBufferGetBaseAddress(mask) else {
            return .unknown(.failed)
        }
        let stride = CVPixelBufferGetBytesPerRow(mask)
        var labels = [UInt8](repeating: 0, count: width * height)
        for y in 0..<height {
            let row = base.advanced(by: y * stride).assumingMemoryBound(to: UInt8.self)
            for x in 0..<width {
                labels[y * width + x] = row[x]
            }
        }
        return ObjectProductEvidenceRule.evaluate(
            ObjectProductEvidenceRule.Input(
                labels: labels,
                luma: lumaAt(width, height),
                width: width,
                height: height,
                hull: hull,
                baseFace: baseFace
            )
        )
    }

    // MARK: - Luma at mask resolution

    static func lumaPlane(of buffer: CVPixelBuffer, width: Int, height: Int) -> [UInt8]? {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard CVPixelBufferGetPlaneCount(buffer) >= 1,
              let base = CVPixelBufferGetBaseAddressOfPlane(buffer, 0) else { return nil }
        let sourceWidth = CVPixelBufferGetWidthOfPlane(buffer, 0)
        let sourceHeight = CVPixelBufferGetHeightOfPlane(buffer, 0)
        let stride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
        guard sourceWidth > 0, sourceHeight > 0, width > 0, height > 0 else { return nil }
        let source = base.assumingMemoryBound(to: UInt8.self)
        var out = [UInt8](repeating: 0, count: width * height)
        for y in 0..<height {
            let sy = min(sourceHeight - 1, y * sourceHeight / height)
            for x in 0..<width {
                let sx = min(sourceWidth - 1, x * sourceWidth / width)
                out[y * width + x] = source[sy * stride + sx]
            }
        }
        return out
    }

    static func lumaPlane(of image: CGImage, width: Int, height: Int) -> [UInt8]? {
        guard width > 0, height > 0 else { return nil }
        var out = [UInt8](repeating: 0, count: width * height)
        let drawn = out.withUnsafeMutableBytes { raw -> Bool in
            guard let context = CGContext(
                data: raw.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width,
                space: CGColorSpaceCreateDeviceGray(),
                bitmapInfo: CGImageAlphaInfo.none.rawValue
            ) else { return false }
            context.interpolationQuality = .medium
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        return drawn ? out : nil
    }
}
