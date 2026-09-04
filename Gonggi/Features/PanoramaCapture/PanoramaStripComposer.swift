import CoreGraphics
import Foundation
import UIKit

/// Strip-based horizontal panorama compositor (iPhone-style lightweight path).
final class PanoramaStripComposer {
    private(set) var placements: [PanoramaStripPlacement] = []
    private(set) var canvasWidth: Int = 0
    private(set) var canvasHeight: Int = 0
    private var canvasRGBA: [UInt8] = []
    private var canvasWeight: [Float] = []
    private var lastGrayStrip: [Float]?
    private var lastStripHeight: Int = 0
    private var lastMeanLuma: Float = 128
    private(set) var meanVerticalAlignPx: Double = 0
    private var alignSamples: Int = 0

    private var _pxPerDegree: Float = 12
    private var originYawDeg: Float?
    private var minX: Float = 0
    private var maxX: Float = 0

    var pxPerDegree: Float { max(1, _pxPerDegree) }

    func reset() {
        placements.removeAll()
        canvasRGBA.removeAll(keepingCapacity: false)
        canvasWeight.removeAll(keepingCapacity: false)
        canvasWidth = 0
        canvasHeight = 0
        lastGrayStrip = nil
        lastStripHeight = 0
        originYawDeg = nil
        meanVerticalAlignPx = 0
        alignSamples = 0
        minX = 0
        maxX = 0
        _pxPerDegree = 12
    }

    func configurePxPerDegree(frameWidth: Int) {
        _pxPerDegree = Float(frameWidth) / max(1, PanoramaCaptureConfig.approxHFovDeg)
    }

    /// Extract center strip + accept into canvas.
    /// - Parameters:
    ///   - frameWidthForFov: Full sensor/frame width used for px/deg (when `rgba` is already a strip).
    @discardableResult
    func acceptFrame(
        rgba: [UInt8],
        width: Int,
        height: Int,
        yawDeg: Float,
        frameWidthForFov: Int? = nil
    ) -> Bool {
        let stripW = min(PanoramaCaptureConfig.stripWidthPx, width)
        guard stripW >= 8, height > 16 else { return false }
        if canvasHeight == 0 {
            configurePxPerDegree(frameWidth: frameWidthForFov ?? width)
            canvasHeight = height
            // Allocate generous canvas for ~120°; grow if needed.
            let estimate = Int(ceil(120 * _pxPerDegree)) + stripW * 4
            canvasWidth = max(estimate, 1024)
            let n = canvasWidth * canvasHeight
            canvasRGBA = [UInt8](repeating: 0, count: n * 4)
            canvasWeight = [Float](repeating: 0, count: n)
            originYawDeg = yawDeg
            minX = Float(canvasWidth) * 0.5
            maxX = minX
        }

        let origin = originYawDeg ?? yawDeg
        let xCenter = Float(canvasWidth) * 0.5 + (yawDeg - origin) * _pxPerDegree
        ensureCapacity(forX: xCenter)

        let sx0 = max(0, (width - stripW) / 2)
        var gray = [Float](repeating: 0, count: stripW * height)
        var color = [UInt8](repeating: 0, count: stripW * height * 4)
        var sumLuma: Float = 0
        for y in 0..<height {
            for x in 0..<stripW {
                let si = (y * width + (sx0 + x)) * 4
                let di = (y * stripW + x) * 4
                let r = rgba[si], g = rgba[si + 1], b = rgba[si + 2]
                color[di] = r; color[di + 1] = g; color[di + 2] = b; color[di + 3] = 255
                let luma = 0.299 * Float(r) + 0.587 * Float(g) + 0.114 * Float(b)
                gray[y * stripW + x] = luma
                sumLuma += luma
            }
        }
        let meanLuma = sumLuma / Float(max(1, stripW * height))

        var vOffset = 0
        if let prev = lastGrayStrip, lastStripHeight == height {
            vOffset = Self.bestVerticalOffset(
                prev: prev, prevW: stripW, curr: gray, currW: stripW, height: height,
                search: PanoramaCaptureConfig.verticalAlignSearchPx
            )
            meanVerticalAlignPx =
                (meanVerticalAlignPx * Double(alignSamples) + Double(abs(vOffset)))
                / Double(alignSamples + 1)
            alignSamples += 1
        }

        // Exposure normalize toward previous mean.
        var exposureScale: Float = 1
        if !placements.isEmpty, lastMeanLuma > 8 {
            exposureScale = min(1.35, max(0.7, lastMeanLuma / max(8, meanLuma)))
        }

        blitStrip(
            color: color, stripW: stripW, height: height,
            xCenter: xCenter, vOffset: vOffset, exposureScale: exposureScale
        )

        placements.append(PanoramaStripPlacement(
            index: placements.count,
            yawDeg: yawDeg,
            xOnCanvas: xCenter,
            verticalOffsetPx: vOffset,
            meanLuma: meanLuma
        ))
        lastGrayStrip = gray
        lastStripHeight = height
        lastMeanLuma = meanLuma * exposureScale
        minX = min(minX, xCenter - Float(stripW) / 2)
        maxX = max(maxX, xCenter + Float(stripW) / 2)
        return true
    }

    func yawSpanDeg() -> Float {
        guard let first = placements.first, let last = placements.last else { return 0 }
        return abs(last.yawDeg - first.yawDeg)
    }

    func composeUIImage(cropToContent: Bool = true) -> UIImage? {
        guard canvasWidth > 0, canvasHeight > 0, !placements.isEmpty else { return nil }
        var rgba = canvasRGBA
        // Normalize by weight.
        for i in 0..<canvasWidth * canvasHeight {
            let w = canvasWeight[i]
            if w > 1e-3 {
                let inv = 1 / w
                let o = i * 4
                rgba[o] = UInt8(clamping: Int(Float(rgba[o]) * inv))
                rgba[o + 1] = UInt8(clamping: Int(Float(rgba[o + 1]) * inv))
                rgba[o + 2] = UInt8(clamping: Int(Float(rgba[o + 2]) * inv))
                rgba[o + 3] = 255
            } else {
                let o = i * 4
                rgba[o] = 0; rgba[o + 1] = 0; rgba[o + 2] = 0; rgba[o + 3] = 0
            }
        }

        guard let full = Self.image(fromRGBA: rgba, width: canvasWidth, height: canvasHeight) else {
            return nil
        }
        guard cropToContent else { return full }

        let pad = PanoramaCaptureConfig.stripWidthPx
        let left = max(0, Int(floor(minX)) - pad)
        let right = min(canvasWidth, Int(ceil(maxX)) + pad)
        let cropW = max(1, right - left)
        let rect = CGRect(x: left, y: 0, width: cropW, height: canvasHeight)
        guard let cg = full.cgImage?.cropping(to: rect) else { return full }
        // Pixel buffer itself is upright landscape panorama — no EXIF orientation hack.
        return UIImage(cgImage: cg, scale: 1, orientation: .up)
    }

    /// True when cropped content is a wide landscape panorama.
    var isLandscapePanorama: Bool {
        guard canvasHeight > 0, !placements.isEmpty else { return false }
        let pad = PanoramaCaptureConfig.stripWidthPx
        let left = max(0, Int(floor(minX)) - pad)
        let right = min(canvasWidth, Int(ceil(maxX)) + pad)
        let w = max(1, right - left)
        return w > canvasHeight
    }

    // MARK: - Private

    private func ensureCapacity(forX xCenter: Float) {
        let stripW = Float(PanoramaCaptureConfig.stripWidthPx)
        let needLeft = xCenter - stripW
        let needRight = xCenter + stripW
        if needLeft >= 0, needRight < Float(canvasWidth) { return }

        let expandLeft = needLeft < 0 ? Int(ceil(-needLeft)) + 64 : 0
        let expandRight = needRight >= Float(canvasWidth)
            ? Int(ceil(needRight - Float(canvasWidth))) + 64 : 0
        guard expandLeft > 0 || expandRight > 0 else { return }

        let newW = canvasWidth + expandLeft + expandRight
        var newRGBA = [UInt8](repeating: 0, count: newW * canvasHeight * 4)
        var newWgt = [Float](repeating: 0, count: newW * canvasHeight)
        for y in 0..<canvasHeight {
            for x in 0..<canvasWidth {
                let si = y * canvasWidth + x
                let di = y * newW + (x + expandLeft)
                newWgt[di] = canvasWeight[si]
                let so = si * 4, d = di * 4
                newRGBA[d] = canvasRGBA[so]
                newRGBA[d + 1] = canvasRGBA[so + 1]
                newRGBA[d + 2] = canvasRGBA[so + 2]
                newRGBA[d + 3] = canvasRGBA[so + 3]
            }
        }
        canvasRGBA = newRGBA
        canvasWeight = newWgt
        canvasWidth = newW
        minX += Float(expandLeft)
        maxX += Float(expandLeft)
        for i in placements.indices {
            placements[i].xOnCanvas += Float(expandLeft)
        }
    }

    private func blitStrip(
        color: [UInt8],
        stripW: Int,
        height: Int,
        xCenter: Float,
        vOffset: Int,
        exposureScale: Float
    ) {
        let feather = max(1, PanoramaCaptureConfig.seamFeatherPx)
        let x0 = Int(round(xCenter - Float(stripW) / 2))
        for y in 0..<height {
            let sy = y + vOffset
            if sy < 0 || sy >= height { continue }
            for x in 0..<stripW {
                let dx = x0 + x
                if dx < 0 || dx >= canvasWidth { continue }
                let edge = min(x, stripW - 1 - x)
                let featherW = edge < feather
                    ? Float(edge + 1) / Float(feather + 1)
                    : 1
                let src = (sy * stripW + x) * 4
                let dst = (y * canvasWidth + dx)
                let w = featherW
                let r = Float(color[src]) * exposureScale
                let g = Float(color[src + 1]) * exposureScale
                let b = Float(color[src + 2]) * exposureScale
                // Accumulate premultiplied by weight into byte buffer approx:
                let ow = canvasWeight[dst]
                let nw = ow + w
                if nw > 1e-4 {
                    let o = dst * 4
                    let or = Float(canvasRGBA[o]) * ow
                    let og = Float(canvasRGBA[o + 1]) * ow
                    let ob = Float(canvasRGBA[o + 2]) * ow
                    // Store weighted sum in bytes temporarily (scaled); finalize in compose.
                    // Better: store as float — but keep memory lighter with re-weight trick:
                    canvasRGBA[o] = UInt8(clamping: Int((or + r * w) / nw))
                    canvasRGBA[o + 1] = UInt8(clamping: Int((og + g * w) / nw))
                    canvasRGBA[o + 2] = UInt8(clamping: Int((ob + b * w) / nw))
                    canvasRGBA[o + 3] = 255
                    canvasWeight[dst] = 1 // already normalized blend
                }
            }
        }
    }

    static func bestVerticalOffset(
        prev: [Float], prevW: Int,
        curr: [Float], currW: Int,
        height: Int,
        search: Int
    ) -> Int {
        var best = 0
        var bestScore = -Float.greatestFiniteMagnitude
        let band = min(prevW, currW)
        for dy in -search...search {
            var sum: Float = 0
            var count: Float = 0
            let y0 = max(0, dy)
            let y1 = min(height, height + dy)
            for y in y0..<y1 {
                let py = y - dy
                if py < 0 || py >= height { continue }
                for x in 0..<band {
                    sum += prev[py * prevW + x] * curr[y * currW + x]
                    count += 1
                }
            }
            let score = count > 0 ? sum / count : -1e9
            if score > bestScore {
                bestScore = score
                best = dy
            }
        }
        return best
    }

    static func image(fromRGBA rgba: [UInt8], width: Int, height: Int) -> UIImage? {
        let bytesPerRow = width * 4
        guard rgba.count >= bytesPerRow * height else { return nil }
        return rgba.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return nil }
            let data = Data(bytes: base, count: bytesPerRow * height)
            guard let provider = CGDataProvider(data: data as CFData) else { return nil }
            guard let cg = CGImage(
                width: width,
                height: height,
                bitsPerComponent: 8,
                bitsPerPixel: 32,
                bytesPerRow: bytesPerRow,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                provider: provider,
                decode: nil,
                shouldInterpolate: true,
                intent: .defaultIntent
            ) else { return nil }
            return UIImage(cgImage: cg)
        }
    }

    static func resize(_ image: UIImage, longEdge: Int) -> UIImage {
        let w = image.size.width
        let h = image.size.height
        let long = max(w, h)
        guard long > CGFloat(longEdge) else { return image }
        let s = CGFloat(longEdge) / long
        let nw = max(1, Int((w * s).rounded()))
        let nh = max(1, Int((h * s).rounded()))
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: nw, height: nh), format: format)
        return renderer.image { _ in
            image.draw(in: CGRect(x: 0, y: 0, width: nw, height: nh))
        }
    }

    /// Laplacian-variance blur proxy on center region.
    static func sharpnessScore(rgba: [UInt8], width: Int, height: Int) -> Float {
        let x0 = width / 4
        let x1 = width * 3 / 4
        let y0 = height / 4
        let y1 = height * 3 / 4
        var sum: Float = 0
        var sumSq: Float = 0
        var n: Float = 0
        func luma(_ x: Int, _ y: Int) -> Float {
            let o = (y * width + x) * 4
            return 0.299 * Float(rgba[o]) + 0.587 * Float(rgba[o + 1]) + 0.114 * Float(rgba[o + 2])
        }
        for y in stride(from: y0 + 1, to: y1 - 1, by: 2) {
            for x in stride(from: x0 + 1, to: x1 - 1, by: 2) {
                let lap = abs(
                    4 * luma(x, y) - luma(x - 1, y) - luma(x + 1, y) - luma(x, y - 1) - luma(x, y + 1)
                )
                sum += lap
                sumSq += lap * lap
                n += 1
            }
        }
        guard n > 0 else { return 0 }
        let mean = sum / n
        return max(0, sumSq / n - mean * mean)
    }
}
