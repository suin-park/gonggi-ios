import Foundation
import simd

/// Exposure compensation between adjacent keyframes using global brightness scale.
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

    static func applyScale(to rgba: [UInt8], scale: Float) -> [UInt8] {
        rgba.map { byte in
            let v = min(255, Int(Float(byte) * scale))
            return UInt8(v)
        }
    }
}
