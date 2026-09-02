import Foundation
import simd

/// Seam blending with feather weights and dynamic-region preference.
enum PanoramaSeamBlender {
  static func blend(
    accumColors: [SIMD3<Float>],
    accumWeights: [Float],
    perFrameColors: [[SIMD3<Float>]],
    perFrameWeights: [[Float]],
    perFrameDynamic: [Float]
  ) -> [SIMD3<Float>] {
    let count = accumColors.count
    var result = [SIMD3<Float>](repeating: .zero, count: count)

    for i in 0..<count {
      if accumWeights[i] > 0.001 {
        result[i] = accumColors[i] / accumWeights[i]
        continue
      }

      var bestColor = SIMD3<Float>(0, 0, 0)
      var bestWeight: Float = 0
      for (fi, frameColors) in perFrameColors.enumerated() {
        let w = perFrameWeights[fi][i]
        guard w > 0.001 else { continue }
        let dynamicPenalty = 1 - simd_clamp(perFrameDynamic[fi], 0, 1) * 0.5
        let adjusted = w * dynamicPenalty
        if adjusted > bestWeight {
          bestWeight = adjusted
          bestColor = frameColors[i]
        }
      }
      if bestWeight > 0 {
        result[i] = bestColor
      }
    }

    return featherBlend(
      base: result,
      accumColors: accumColors,
      accumWeights: accumWeights
    )
  }

  /// Light horizontal feather in overlap zones.
  static func featherBlend(
    base: [SIMD3<Float>],
    accumColors: [SIMD3<Float>],
    accumWeights: [Float],
    width: Int = Quick360Config.outputWidth,
    height: Int = Quick360Config.outputHeight
  ) -> [SIMD3<Float>] {
    var out = base
    for y in 0..<height {
      for x in 1..<(width - 1) {
        let idx = y * width + x
        guard accumWeights[idx] > 0.001 else { continue }
        let left = accumWeights[idx - 1]
        let right = accumWeights[idx + 1]
        if left > 0.001 && right > 0.001 {
          let mix = (accumColors[idx - 1] / left + accumColors[idx + 1] / right) * 0.5
          out[idx] = out[idx] * 0.7 + mix * 0.3
        }
      }
    }
    return out
  }
}
