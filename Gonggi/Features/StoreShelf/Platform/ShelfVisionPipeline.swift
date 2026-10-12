import CoreImage
import CoreVideo
import Foundation
import ImageIO
import UIKit
import Vision

// On-device product region detection and image features, using only Apple's Vision framework (no downloaded model,
// no third-party weights). Detection is class-agnostic: rectangles (boxes, cartons, cans seen from the side) plus
// foreground instances. The embedding is Vision's generic image feature print; a dedicated retrieval model
// (PP-ShiTuV2 / DINOv2 converted to Core ML) can replace `ShelfAppearanceExtractor` without touching anything else.
//
// All coordinates handled here are in the NATIVE sensor buffer (landscape, orientation .up). Crops are rotated to
// upright (CGImagePropertyOrientation.right: the device is held in portrait) before they are embedded or stored, so a
// registered crop and a crop taken later in portrait, or a photo of the product, compare in the same orientation.

struct ShelfDetectedRegion: Equatable {
    var rect: StoreImageSpace.PixelRect
    var score: Float
    var source: String
}

struct ShelfCrop {
    var image: CGImage
    var jpeg: Data
    var sharpness: Float
    var color: [Float]
}

final class ShelfProductDetector {
    struct Config {
        var minAreaFraction: Float = 0.004
        var maxAreaFraction: Float = 0.30
        var maxRegions = 14
        var minLongSidePixels: Float = 40
    }

    let config: Config

    init(config: Config = Config()) {
        self.config = config
    }

    /// Regions in sensor-pixel space, best first, overlapping duplicates removed.
    func detect(pixelBuffer: CVPixelBuffer) -> [ShelfDetectedRegion] {
        let w = Float(CVPixelBufferGetWidth(pixelBuffer)), h = Float(CVPixelBufferGetHeight(pixelBuffer))
        guard w > 0, h > 0 else { return [] }
        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .up, options: [:])
        var found: [ShelfDetectedRegion] = []

        let rectangles = VNDetectRectanglesRequest()
        rectangles.minimumAspectRatio = 0.15
        rectangles.maximumAspectRatio = 1.0
        rectangles.minimumSize = 0.04
        rectangles.maximumObservations = 40
        rectangles.minimumConfidence = 0.45
        rectangles.quadratureTolerance = 25
        if (try? handler.perform([rectangles])) != nil {
            for case let o as VNRectangleObservation in rectangles.results ?? [] {
                let b = o.boundingBox
                let r = StoreImageSpace.sensorRect(fromVision: Float(b.minX), y: Float(b.minY), w: Float(b.width),
                                                   h: Float(b.height), imageWidth: w, imageHeight: h)
                found.append(ShelfDetectedRegion(rect: r, score: 0.4 + 0.5 * o.confidence, source: "rectangle"))
            }
        }

        let foreground = VNGenerateForegroundInstanceMaskRequest()
        if (try? handler.perform([foreground])) != nil, let obs = foreground.results?.first {
            found.append(contentsOf: instanceRegions(obs, imageWidth: w, imageHeight: h))
        }

        let area = w * h
        let filtered = found.filter { r in
            let a = r.rect.width * r.rect.height
            return a >= config.minAreaFraction * area && a <= config.maxAreaFraction * area
                && max(r.rect.width, r.rect.height) >= config.minLongSidePixels
        }
        let keep = StoreRegionNMS.suppress(filtered.map { ($0.rect, $0.score) })
        return Array(keep.prefix(config.maxRegions).map { filtered[$0] })
    }

    private func instanceRegions(_ obs: VNInstanceMaskObservation, imageWidth w: Float, imageHeight h: Float) -> [ShelfDetectedRegion] {
        let mask = obs.instanceMask
        CVPixelBufferLockBaseAddress(mask, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(mask, .readOnly) }
        let mw = CVPixelBufferGetWidth(mask), mh = CVPixelBufferGetHeight(mask)
        guard mw > 0, mh > 0, CVPixelBufferGetPixelFormatType(mask) == kCVPixelFormatType_OneComponent8,
              let base = CVPixelBufferGetBaseAddress(mask) else { return [] }
        let stride = CVPixelBufferGetBytesPerRow(mask)
        var minX = [Int: Int](), minY = [Int: Int](), maxX = [Int: Int](), maxY = [Int: Int](), count = [Int: Int]()
        for y in 0..<mh {
            let row = base.advanced(by: y * stride).assumingMemoryBound(to: UInt8.self)
            for x in 0..<mw {
                let label = Int(row[x])
                if label == 0 { continue }
                minX[label] = min(minX[label] ?? x, x)
                maxX[label] = max(maxX[label] ?? x, x)
                minY[label] = min(minY[label] ?? y, y)
                maxY[label] = max(maxY[label] ?? y, y)
                count[label, default: 0] += 1
            }
        }
        var out: [ShelfDetectedRegion] = []
        for (label, c) in count where c >= 12 {
            let r = StoreImageSpace.PixelRect(
                minU: Float(minX[label]!) / Float(mw) * w, minV: Float(minY[label]!) / Float(mh) * h,
                maxU: Float(maxX[label]! + 1) / Float(mw) * w, maxV: Float(maxY[label]! + 1) / Float(mh) * h)
            out.append(ShelfDetectedRegion(rect: r, score: 0.55, source: "instance"))
        }
        return out
    }
}

final class ShelfAppearanceExtractor {
    private let context = CIContext(options: nil)
    private let longSide: CGFloat = 224

    /// Crops a sensor-space rectangle, rotates it upright and prepares everything the registry needs.
    func crop(pixelBuffer: CVPixelBuffer, rect: StoreImageSpace.PixelRect, padding: Float = 0.05) -> ShelfCrop? {
        let w = CGFloat(CVPixelBufferGetWidth(pixelBuffer)), h = CGFloat(CVPixelBufferGetHeight(pixelBuffer))
        let padU = CGFloat(rect.width * padding), padV = CGFloat(rect.height * padding)
        let minU = max(0, CGFloat(rect.minU) - padU), maxU = min(w, CGFloat(rect.maxU) + padU)
        let minV = max(0, CGFloat(rect.minV) - padV), maxV = min(h, CGFloat(rect.maxV) + padV)
        guard maxU - minU >= 16, maxV - minV >= 16 else { return nil }
        // Core Image's origin is bottom-left.
        let ciRect = CGRect(x: minU, y: h - maxV, width: maxU - minU, height: maxV - minV)
        let upright = CIImage(cvPixelBuffer: pixelBuffer).cropped(to: ciRect).oriented(.right)
        let ext = upright.extent
        guard ext.width > 1, ext.height > 1 else { return nil }
        let scale = min(1, longSide / max(ext.width, ext.height))
        let placed = upright
            .transformed(by: CGAffineTransform(translationX: -ext.origin.x, y: -ext.origin.y))
            .transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        guard let cg = context.createCGImage(placed, from: placed.extent) else { return nil }
        return finish(cg)
    }

    /// For a photo of a product (search by picture): the whole image is the crop, upright already.
    func crop(photo: CGImage) -> ShelfCrop? {
        let w = CGFloat(photo.width), h = CGFloat(photo.height)
        let scale = min(1, longSide / max(w, h))
        guard scale < 1 else { return finish(photo) }
        let ci = CIImage(cgImage: photo).transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        guard let cg = context.createCGImage(ci, from: ci.extent) else { return nil }
        return finish(cg)
    }

    private func finish(_ cg: CGImage) -> ShelfCrop? {
        guard let jpeg = UIImage(cgImage: cg).jpegData(compressionQuality: 0.8) else { return nil }
        let luma = gray(cg, side: 64)
        let sharp = StoreImageStats.laplacianVariance(luma: luma, width: 64, height: 64)
        let rgba = rgbaPixels(cg, side: 32)
        let color = StoreImageStats.colorDescriptor(rgba: rgba, width: 32, height: 32)
        return ShelfCrop(image: cg, jpeg: jpeg, sharpness: sharp, color: color)
    }

    private func gray(_ cg: CGImage, side: Int) -> [UInt8] {
        var buf = [UInt8](repeating: 0, count: side * side)
        buf.withUnsafeMutableBytes { ptr in
            guard let ctx = CGContext(data: ptr.baseAddress, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side,
                                      space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return }
            ctx.interpolationQuality = .medium
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: side, height: side))
        }
        return buf
    }

    private func rgbaPixels(_ cg: CGImage, side: Int) -> [UInt8] {
        var buf = [UInt8](repeating: 0, count: side * side * 4)
        buf.withUnsafeMutableBytes { ptr in
            guard let ctx = CGContext(data: ptr.baseAddress, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
            ctx.interpolationQuality = .medium
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: side, height: side))
        }
        return buf
    }

    /// Vision feature print as a float vector (L2-normalised), combined with the colour descriptor.
    func appearance(of crop: ShelfCrop) -> ShelfAppearance? {
        let request = VNGenerateImageFeaturePrintRequest()
        let handler = VNImageRequestHandler(cgImage: crop.image, orientation: .up, options: [:])
        do { try handler.perform([request]) } catch { return nil }
        for case let o as VNFeaturePrintObservation in request.results ?? [] {
            let v = Self.floats(o)
            if v.isEmpty { return nil }
            return ShelfAppearance(embedding: StoreVectorMath.l2Normalized(v), color: crop.color)
        }
        return nil
    }

    static func floats(_ o: VNFeaturePrintObservation) -> [Float] {
        let n = o.elementCount
        guard n > 0 else { return [] }
        switch o.elementType {
        case .float:
            return o.data.withUnsafeBytes { raw -> [Float] in
                let p = raw.bindMemory(to: Float.self)
                return Array(p.prefix(n))
            }
        case .double:
            return o.data.withUnsafeBytes { raw -> [Float] in
                let p = raw.bindMemory(to: Double.self)
                return p.prefix(n).map { Float($0) }
            }
        default:
            return []
        }
    }
}

enum ShelfFrameImage {
    /// A whole frame as an upright JPEG (the saved shelf photo, the reference sign).
    static func uprightJPEG(pixelBuffer: CVPixelBuffer, maxSide: CGFloat = 1280, quality: CGFloat = 0.7) -> Data? {
        let ci = CIImage(cvPixelBuffer: pixelBuffer).oriented(.right)
        let ext = ci.extent
        let scale = min(1, maxSide / max(ext.width, ext.height))
        let placed = ci.transformed(by: CGAffineTransform(translationX: -ext.origin.x, y: -ext.origin.y))
            .transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let ctx = CIContext(options: nil)
        guard let cg = ctx.createCGImage(placed, from: placed.extent) else { return nil }
        return UIImage(cgImage: cg).jpegData(compressionQuality: quality)
    }
}
