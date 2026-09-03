import Foundation
import simd

/// Seam blending: prefer one frame in high-difference overlap (avoid double-image average).
enum PanoramaSeamBlender {
    struct SeamDebug: Equatable {
        var preferredFrame: [Int16]
        var differenceMap: [Float]
    }

    static func blend(
        accumColors: [SIMD3<Float>],
        accumWeights: [Float],
        perFrameColors: [[SIMD3<Float>]],
        perFrameWeights: [[Float]],
        perFrameDynamic: [Float],
        highParallaxFlags: [Bool] = [],
        width: Int = Quick360Config.outputWidth,
        height: Int = Quick360Config.outputHeight
    ) -> (colors: [SIMD3<Float>], seam: SeamDebug) {
        let count = accumColors.count
        var preferred = [Int16](repeating: -1, count: count)
        var diffMap = [Float](repeating: 0, count: count)
        var result = [SIMD3<Float>](repeating: .zero, count: count)

        for i in 0..<count {
            var contributors: [(Int, Float, SIMD3<Float>)] = []
            for (fi, frameColors) in perFrameColors.enumerated() {
                let w = perFrameWeights[fi][i]
                guard w > 0.001 else { continue }
                var adjusted = w * (1 - simd_clamp(perFrameDynamic[fi], 0, 1) * 0.5)
                if fi < highParallaxFlags.count, highParallaxFlags[fi] {
                    adjusted *= 0.65
                }
                contributors.append((fi, adjusted, frameColors[i]))
            }
            contributors.sort { $0.1 > $1.1 }

            if contributors.isEmpty {
                if accumWeights[i] > 0.001 {
                    result[i] = accumColors[i] / accumWeights[i]
                }
                continue
            }

            if contributors.count == 1 {
                preferred[i] = Int16(contributors[0].0)
                result[i] = contributors[0].2
                continue
            }

            let a = contributors[0]
            let b = contributors[1]
            let diff = (abs(a.2.x - b.2.x) + abs(a.2.y - b.2.y) + abs(a.2.z - b.2.z)) / 3
            diffMap[i] = diff

            if diff < 0.04 {
                // Low difference: soft weighted average of top-2.
                let wSum = a.1 + b.1
                result[i] = (a.2 * a.1 + b.2 * b.1) / max(wSum, 1e-4)
                preferred[i] = Int16(a.0)
            } else {
                // High difference: pick one side (winner) — seam, not double image.
                preferred[i] = Int16(a.0)
                result[i] = a.2
            }
        }

        result = featherAlongSeam(
            base: result,
            preferred: preferred,
            width: width,
            height: height
        )
        return (result, SeamDebug(preferredFrame: preferred, differenceMap: diffMap))
    }

    /// Feather only near vertical/horizontal preferred-frame transitions.
    static func featherAlongSeam(
        base: [SIMD3<Float>],
        preferred: [Int16],
        width: Int,
        height: Int
    ) -> [SIMD3<Float>] {
        var out = base
        for y in 0..<height {
            for x in 1..<(width - 1) {
                let idx = y * width + x
                let left = preferred[idx - 1]
                let right = preferred[idx + 1]
                let cur = preferred[idx]
                guard cur >= 0 else { continue }
                if left >= 0, right >= 0, left != right {
                    out[idx] = (base[idx - 1] + base[idx] + base[idx + 1]) / 3
                } else if left >= 0, left != cur {
                    out[idx] = base[idx] * 0.65 + base[idx - 1] * 0.35
                } else if right >= 0, right != cur {
                    out[idx] = base[idx] * 0.65 + base[idx + 1] * 0.35
                }
            }
        }
        return out
    }

    /// Legacy API used by older unit tests.
    static func blend(
        accumColors: [SIMD3<Float>],
        accumWeights: [Float],
        perFrameColors: [[SIMD3<Float>]],
        perFrameWeights: [[Float]],
        perFrameDynamic: [Float]
    ) -> [SIMD3<Float>] {
        blend(
            accumColors: accumColors,
            accumWeights: accumWeights,
            perFrameColors: perFrameColors,
            perFrameWeights: perFrameWeights,
            perFrameDynamic: perFrameDynamic,
            highParallaxFlags: []
        ).colors
    }

    static func featherBlend(
        base: [SIMD3<Float>],
        accumColors: [SIMD3<Float>],
        accumWeights: [Float],
        width: Int = Quick360Config.outputWidth,
        height: Int = Quick360Config.outputHeight
    ) -> [SIMD3<Float>] {
        var preferred = [Int16](repeating: 0, count: base.count)
        for i in 0..<base.count {
            preferred[i] = accumWeights[i] > 0.001 ? 0 : -1
        }
        return featherAlongSeam(base: base, preferred: preferred, width: width, height: height)
    }

    /// Continuity: seam labels should not flicker every pixel along a row (unit-test helper).
    static func seamLabelRunContinuity(preferred: [Int16], width: Int, height: Int) -> Float {
        guard width > 2, height > 0, preferred.count >= width * height else { return 0 }
        var transitions = 0
        var samples = 0
        for y in 0..<height {
            for x in 1..<width {
                let a = preferred[y * width + x - 1]
                let b = preferred[y * width + x]
                if a >= 0, b >= 0 {
                    samples += 1
                    if a != b { transitions += 1 }
                }
            }
        }
        guard samples > 0 else { return 1 }
        return 1 - Float(transitions) / Float(samples)
    }
}
