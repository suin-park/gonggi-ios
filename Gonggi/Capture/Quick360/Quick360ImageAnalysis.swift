import Foundation
import simd

/// Image analysis helpers for sharpness and exposure scoring (testable on byte grids).
enum Quick360ImageAnalysis {
    /// Laplacian-variance style sharpness on grayscale grid (0…1).
    static func sharpnessScore(grayscale: [UInt8], width: Int, height: Int) -> Float {
        guard width >= 3, height >= 3, grayscale.count == width * height else { return 0.5 }
        var laplacianSum: Double = 0
        var count = 0
        for y in 1..<(height - 1) {
            for x in 1..<(width - 1) {
                let idx = y * width + x
                let center = Double(grayscale[idx])
                let up = Double(grayscale[idx - width])
                let down = Double(grayscale[idx + width])
                let left = Double(grayscale[idx - 1])
                let right = Double(grayscale[idx + 1])
                let lap = abs(4 * center - up - down - left - right)
                laplacianSum += lap
                count += 1
            }
        }
        guard count > 0 else { return 0.5 }
        let variance = laplacianSum / Double(count)
        // Normalize: typical indoor 0…40 range
        return Float(simd_clamp(variance / 40.0, 0, 1))
    }

    /// Exposure score: penalize clipping (0…1).
    static func exposureScore(grayscale: [UInt8]) -> Float {
        guard !grayscale.isEmpty else { return 0.5 }
        var clipped = 0
        var sum: Int = 0
        for v in grayscale {
            sum += Int(v)
            if v < 8 || v > 247 { clipped += 1 }
        }
        let clipRatio = Float(clipped) / Float(grayscale.count)
        let mean = Float(sum) / Float(grayscale.count) / 255.0
        let meanPenalty = abs(mean - 0.5) * 0.5
        return simd_clamp(1 - clipRatio * 2 - meanPenalty, 0, 1)
    }

    /// Mean absolute difference ratio between two equal-size grayscale buffers (0…1).
    static func differenceRatio(a: [UInt8], b: [UInt8]) -> Float {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        var diffSum: Int = 0
        for i in 0..<a.count {
            diffSum += abs(Int(a[i]) - Int(b[i]))
        }
        let meanDiff = Float(diffSum) / Float(a.count) / 255.0
        return simd_clamp(meanDiff * 3, 0, 1)
    }

    /// Downsample RGBA buffer to coarse grayscale for analysis.
    static func downsampleGrayscale(
        rgba: [UInt8],
        srcWidth: Int,
        srcHeight: Int,
        dstWidth: Int,
        dstHeight: Int
    ) -> [UInt8] {
        guard srcWidth > 0, srcHeight > 0, rgba.count >= srcWidth * srcHeight * 4 else {
            return []
        }
        var out = [UInt8](repeating: 0, count: dstWidth * dstHeight)
        for dy in 0..<dstHeight {
            for dx in 0..<dstWidth {
                let sx = dx * srcWidth / dstWidth
                let sy = dy * srcHeight / dstHeight
                let idx = (sy * srcWidth + sx) * 4
                let r = Int(rgba[idx])
                let g = Int(rgba[idx + 1])
                let b = Int(rgba[idx + 2])
                out[dy * dstWidth + dx] = UInt8((r * 77 + g * 150 + b * 29) >> 8)
            }
        }
        return out
    }
}
