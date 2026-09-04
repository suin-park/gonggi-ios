import CoreGraphics
import Foundation
import UIKit

/// Strip-based horizontal panorama compositor.
/// Contract: upright portrait frames (W < H); vertical strips; yaw → canvas X (monotone).
final class PanoramaStripComposer {
    private(set) var placements: [PanoramaStripPlacement] = []
    private(set) var canvasWidth: Int = 0
    private(set) var canvasHeight: Int = 0
    private(set) var uprightFrameWidth: Int = 0
    private(set) var uprightFrameHeight: Int = 0
    private var canvasRGBA: [UInt8] = []
    private var canvasWeight: [Float] = []
    private var lastGrayStrip: [Float]?
    private var lastStripHeight: Int = 0
    private var lastMeanLuma: Float = 128
    private(set) var meanVerticalAlignPx: Double = 0
    private var alignSamples: Int = 0

    private var _pxPerDegree: Float = 0
    private var originX: Float = 0
    private var minX: Float = 0
    private var maxX: Float = 0

    var pxPerDegree: Float { max(1, _pxPerDegree) }

    var firstPlacementX: Float { placements.first?.xOnCanvas ?? 0 }
    var lastPlacementX: Float { placements.last?.xOnCanvas ?? 0 }

    var cropLeft: Float {
        guard !placements.isEmpty else { return 0 }
        let half = Float(PanoramaCaptureConfig.stripWidthPx) / 2
        return placements.map { $0.xOnCanvas - half }.min() ?? 0
    }

    var cropRight: Float {
        guard !placements.isEmpty else { return 0 }
        let half = Float(PanoramaCaptureConfig.stripWidthPx) / 2
        return placements.map { $0.xOnCanvas + half }.max() ?? 0
    }

    var finalCropWidth: Int { max(1, Int(ceil(cropRight - cropLeft))) }
    var finalCropHeight: Int { canvasHeight }

    func reset() {
        placements.removeAll()
        canvasRGBA.removeAll(keepingCapacity: false)
        canvasWeight.removeAll(keepingCapacity: false)
        canvasWidth = 0
        canvasHeight = 0
        uprightFrameWidth = 0
        uprightFrameHeight = 0
        lastGrayStrip = nil
        lastStripHeight = 0
        meanVerticalAlignPx = 0
        alignSamples = 0
        minX = 0
        maxX = 0
        originX = 0
        _pxPerDegree = 0
    }

    /// Configure geometry from upright portrait frame size. Never pass strip width here.
    func configureGeometry(uprightFrameWidth width: Int, uprightFrameHeight height: Int) {
        precondition(width >= 16, "uprightFrameWidth must be full frame width, not strip width")
        uprightFrameWidth = width
        uprightFrameHeight = height
        _pxPerDegree = PanoramaCaptureConfig.pixelsPerDegree(uprightFrameWidth: width)
    }

    /// Place a vertical strip using **unwrapped relative yaw** (degrees from capture start).
    /// - Parameters:
    ///   - rgba: strip pixels OR full upright frame (center strip extracted if wider than stripWidth)
    ///   - width/height: rgba dimensions
    ///   - uprightFrameWidth: full upright portrait width for FOV (required, must be >> strip)
    ///   - relativeYawDeg: unwrapped relative yaw (0 at start; increases as user turns right)
    @discardableResult
    func acceptStrip(
        rgba: [UInt8],
        width: Int,
        height: Int,
        uprightFrameWidth: Int,
        rawYawDeg: Float,
        relativeYawDeg: Float
    ) -> Bool {
        let stripW = PanoramaCaptureConfig.stripWidthPx
        guard stripW >= 8, height > 16 else { return false }
        guard uprightFrameWidth >= stripW * 2 else {
            // Never treat strip width as FOV width.
            return false
        }

        if canvasHeight == 0 {
            configureGeometry(uprightFrameWidth: uprightFrameWidth, uprightFrameHeight: height)
            canvasHeight = height
            let estimate = Int(ceil(200 * _pxPerDegree)) + stripW * 4
            canvasWidth = max(estimate, 2048)
            let n = canvasWidth * canvasHeight
            canvasRGBA = [UInt8](repeating: 0, count: n * 4)
            canvasWeight = [Float](repeating: 0, count: n)
            originX = Float(canvasWidth) * 0.5
            minX = originX
            maxX = originX
        }

        // yaw → canvas X (monotone for increasing yaw)
        let xCenter = originX + relativeYawDeg * _pxPerDegree
        ensureCapacity(forX: xCenter)

        let srcStripW = min(stripW, width)
        let sx0 = max(0, (width - srcStripW) / 2)
        var gray = [Float](repeating: 0, count: srcStripW * height)
        var color = [UInt8](repeating: 0, count: srcStripW * height * 4)
        var sumLuma: Float = 0
        for y in 0..<height {
            for x in 0..<srcStripW {
                let si = (y * width + (sx0 + x)) * 4
                let di = (y * srcStripW + x) * 4
                let r = rgba[si], g = rgba[si + 1], b = rgba[si + 2]
                color[di] = r; color[di + 1] = g; color[di + 2] = b; color[di + 3] = 255
                let luma = 0.299 * Float(r) + 0.587 * Float(g) + 0.114 * Float(b)
                gray[y * srcStripW + x] = luma
                sumLuma += luma
            }
        }
        let meanLuma = sumLuma / Float(max(1, srcStripW * height))

        var vOffset = 0
        if let prev = lastGrayStrip, lastStripHeight == height {
            vOffset = Self.bestVerticalOffset(
                prev: prev, prevW: srcStripW, curr: gray, currW: srcStripW, height: height,
                search: PanoramaCaptureConfig.verticalAlignSearchPx
            )
            meanVerticalAlignPx =
                (meanVerticalAlignPx * Double(alignSamples) + Double(abs(vOffset)))
                / Double(alignSamples + 1)
            alignSamples += 1
        }

        var exposureScale: Float = 1
        if !placements.isEmpty, lastMeanLuma > 8 {
            exposureScale = min(1.35, max(0.7, lastMeanLuma / max(8, meanLuma)))
        }

        blitStrip(
            color: color, stripW: srcStripW, height: height,
            xCenter: xCenter, vOffset: vOffset, exposureScale: exposureScale
        )

        placements.append(PanoramaStripPlacement(
            index: placements.count,
            rawYawDeg: rawYawDeg,
            relativeYawDeg: relativeYawDeg,
            xOnCanvas: xCenter,
            verticalOffsetPx: vOffset,
            meanLuma: meanLuma
        ))
        lastGrayStrip = gray
        lastStripHeight = height
        lastMeanLuma = meanLuma * exposureScale
        minX = min(minX, xCenter - Float(srcStripW) / 2)
        maxX = max(maxX, xCenter + Float(srcStripW) / 2)
        return true
    }

    /// Convenience for tests: relative yaw == absolute when starting at 0.
    @discardableResult
    func acceptFrame(
        rgba: [UInt8],
        width: Int,
        height: Int,
        yawDeg: Float,
        frameWidthForFov: Int? = nil
    ) -> Bool {
        let fovW = frameWidthForFov ?? (width > PanoramaCaptureConfig.stripWidthPx * 2 ? width : 0)
        guard fovW > 0 else { return false }
        return acceptStrip(
            rgba: rgba,
            width: width,
            height: height,
            uprightFrameWidth: fovW,
            rawYawDeg: yawDeg,
            relativeYawDeg: yawDeg
        )
    }

    func yawSpanDeg() -> Float {
        guard let first = placements.first, let last = placements.last else { return 0 }
        return abs(last.relativeYawDeg - first.relativeYawDeg)
    }

    func composeUIImage(cropToContent: Bool = true) -> UIImage? {
        guard canvasWidth > 0, canvasHeight > 0, !placements.isEmpty else { return nil }
        var rgba = canvasRGBA
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

        // Crop to placement span only (no extra strip-width pad).
        let left = max(0, Int(floor(cropLeft)))
        let right = min(canvasWidth, Int(ceil(cropRight)))
        let cropW = max(1, right - left)
        let rect = CGRect(x: left, y: 0, width: cropW, height: canvasHeight)
        guard let cg = full.cgImage?.cropping(to: rect) else { return full }
        return UIImage(cgImage: cg, scale: 1, orientation: .up)
    }

    var isLandscapePanorama: Bool {
        finalCropWidth > finalCropHeight
    }

    // MARK: - Private

    private func ensureCapacity(forX xCenter: Float) {
        let stripW = Float(PanoramaCaptureConfig.stripWidthPx)
        let needLeft = xCenter - stripW
        let needRight = xCenter + stripW
        if needLeft >= 0, needRight < Float(canvasWidth) { return }

        let expandLeft = needLeft < 0 ? Int(ceil(-needLeft)) + 128 : 0
        let expandRight = needRight >= Float(canvasWidth)
            ? Int(ceil(needRight - Float(canvasWidth))) + 128 : 0
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
        originX += Float(expandLeft)
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
                let ow = canvasWeight[dst]
                let nw = ow + w
                if nw > 1e-4 {
                    let o = dst * 4
                    let or = Float(canvasRGBA[o]) * ow
                    let og = Float(canvasRGBA[o + 1]) * ow
                    let ob = Float(canvasRGBA[o + 2]) * ow
                    canvasRGBA[o] = UInt8(clamping: Int((or + r * w) / nw))
                    canvasRGBA[o + 1] = UInt8(clamping: Int((og + g * w) / nw))
                    canvasRGBA[o + 2] = UInt8(clamping: Int((ob + b * w) / nw))
                    canvasRGBA[o + 3] = 255
                    canvasWeight[dst] = 1
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

    static func sharpnessScore(rgba: [UInt8], width: Int, height: Int) -> Float {
        let x0 = max(0, width / 4)
        let x1 = max(x0 + 1, width * 3 / 4)
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
