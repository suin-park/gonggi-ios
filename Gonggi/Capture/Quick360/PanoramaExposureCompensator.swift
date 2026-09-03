import Foundation
import simd

/// Exposure compensation: keep global mean scale; optionally refine with overlap luminance gain.
enum PanoramaExposureCompensator {
    static func brightnessMeans(rgba: [UInt8]) -> Float {
        guard !rgba.isEmpty else { return 0.5 }
        var sum: Float = 0
        let pixelCount = rgba.count / 4
        for i in stride(from: 0, to: rgba.count, by: 4) {
            sum += (Float(rgba[i]) + Float(rgba[i + 1]) + Float(rgba[i + 2])) / (3 * 255)
        }
        return sum / Float(pixelCount)
    }

    /// Per-keyframe scale factors to reduce seam brightness jumps.
    static func computeScales(means: [Float]) -> [Float] {
        guard !means.isEmpty else { return [] }
        let globalMean = means.reduce(0, +) / Float(means.count)
        return means.map { m in
            guard m > 0.05 else { return 1 }
            return simd_clamp(globalMean / m, 0.7, 1.4)
        }
    }

    /// Overlap luminance (+ mild color) gain of `target` relative to `reference` overlap patches.
    static func overlapGain(
        referenceRGBA: [UInt8],
        referenceWidth: Int,
        referenceHeight: Int,
        targetRGBA: [UInt8],
        targetWidth: Int,
        targetHeight: Int,
        refRegion: (x0: Int, y0: Int, x1: Int, y1: Int),
        tgtRegion: (x0: Int, y0: Int, x1: Int, y1: Int)
    ) -> (luminance: Float, color: SIMD3<Float>) {
        func meanRGB(
            _ rgba: [UInt8],
            width: Int,
            height: Int,
            x0: Int, y0: Int, x1: Int, y1: Int
        ) -> SIMD3<Float> {
            var sum = SIMD3<Float>(0, 0, 0)
            var n: Float = 0
            let xa = max(0, min(x0, x1))
            let xb = min(width - 1, max(x0, x1))
            let ya = max(0, min(y0, y1))
            let yb = min(height - 1, max(y0, y1))
            for y in ya...yb {
                for x in xa...xb {
                    let i = (y * width + x) * 4
                    guard i + 2 < rgba.count else { continue }
                    sum += SIMD3(Float(rgba[i]), Float(rgba[i + 1]), Float(rgba[i + 2]))
                    n += 1
                }
            }
            guard n > 0 else { return SIMD3(1, 1, 1) }
            return sum / (n * 255)
        }
        let r = meanRGB(
            referenceRGBA, width: referenceWidth, height: referenceHeight,
            x0: refRegion.x0, y0: refRegion.y0, x1: refRegion.x1, y1: refRegion.y1
        )
        let t = meanRGB(
            targetRGBA, width: targetWidth, height: targetHeight,
            x0: tgtRegion.x0, y0: tgtRegion.y0, x1: tgtRegion.x1, y1: tgtRegion.y1
        )
        let rl = (r.x + r.y + r.z) / 3
        let tl = (t.x + t.y + t.z) / 3
        let lum = tl > 0.05 ? simd_clamp(rl / tl, 0.7, 1.4) : 1
        let color = SIMD3(
            t.x > 0.05 ? simd_clamp(r.x / t.x, 0.75, 1.35) : 1,
            t.y > 0.05 ? simd_clamp(r.y / t.y, 0.75, 1.35) : 1,
            t.z > 0.05 ? simd_clamp(r.z / t.z, 0.75, 1.35) : 1
        )
        return (lum, color)
    }

    /// Apply RGB scale (alpha unchanged).
    static func applyScale(to rgba: [UInt8], scale: Float) -> [UInt8] {
        applyColorGain(to: rgba, gain: SIMD3(scale, scale, scale))
    }

    static func applyColorGain(to rgba: [UInt8], gain: SIMD3<Float>) -> [UInt8] {
        var out = rgba
        for i in stride(from: 0, to: rgba.count, by: 4) {
            out[i] = UInt8(min(255, Int(Float(rgba[i]) * gain.x)))
            out[i + 1] = UInt8(min(255, Int(Float(rgba[i + 1]) * gain.y)))
            out[i + 2] = UInt8(min(255, Int(Float(rgba[i + 2]) * gain.z)))
            // alpha unchanged
        }
        return out
    }

    /// Chain global scales with optional adjacent overlap gains.
    static func computeScalesWithOverlap(
        keyframes: [PanoramaStitcher.InputKeyframe],
        originTransform: simd_float4x4
    ) -> [SIMD3<Float>] {
        let means = keyframes.map { brightnessMeans(rgba: $0.rgba) }
        let global = computeScales(means: means)
        var gains = global.map { SIMD3<Float>($0, $0, $0) }
        guard keyframes.count >= 2 else { return gains }
        for i in 1..<keyframes.count {
            let left = keyframes[i - 1]
            let right = keyframes[i]
            guard let region = PanoramaOverlapEstimator.estimate(
                leftIntrinsics: left.intrinsics,
                rightIntrinsics: right.intrinsics,
                leftTransform: left.cameraTransform,
                rightTransform: right.cameraTransform,
                originTransform: originTransform
            ) else { continue }
            let g = overlapGain(
                referenceRGBA: left.rgba,
                referenceWidth: left.width,
                referenceHeight: left.height,
                targetRGBA: right.rgba,
                targetWidth: right.width,
                targetHeight: right.height,
                refRegion: (region.leftX0, region.leftY0, region.leftX1, region.leftY1),
                tgtRegion: (region.rightX0, region.rightY0, region.rightX1, region.rightY1)
            )
            // Blend mild overlap color with global luminance.
            let blended = SIMD3(
                simd_clamp(gains[i].x * 0.5 + g.color.x * g.luminance * 0.5, 0.7, 1.4),
                simd_clamp(gains[i].y * 0.5 + g.color.y * g.luminance * 0.5, 0.7, 1.4),
                simd_clamp(gains[i].z * 0.5 + g.color.z * g.luminance * 0.5, 0.7, 1.4)
            )
            gains[i] = blended
        }
        return gains
    }
}
