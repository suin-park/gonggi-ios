import Foundation

/// Feature-based alignment refinement hook (Vision translational registration on thumbnails).
enum PanoramaAlignmentRefiner {
    struct RefinementResult: Equatable {
        let applied: Bool
        let dx: Float
        let dy: Float
    }

    /// Prototype: estimate small translational offset between two downsampled grayscale buffers.
    static func estimateTranslationalOffset(
        reference: [UInt8],
        target: [UInt8],
        width: Int,
        height: Int
    ) -> RefinementResult {
        guard reference.count == target.count, reference.count == width * height else {
            return RefinementResult(applied: false, dx: 0, dy: 0)
        }

        // Normalized cross-correlation on small search window
        let searchRadius = 3
        var bestDx = 0
        var bestDy = 0
        var bestScore: Float = -1

        for dy in -searchRadius...searchRadius {
            for dx in -searchRadius...searchRadius {
                var score: Float = 0
                var count = 0
                for y in searchRadius..<(height - searchRadius) {
                    for x in searchRadius..<(width - searchRadius) {
                        let refIdx = y * width + x
                        let tx = x + dx
                        let ty = y + dy
                        guard tx >= 0, tx < width, ty >= 0, ty < height else { continue }
                        let tgtIdx = ty * width + tx
                        let diff = abs(Int(reference[refIdx]) - Int(target[tgtIdx]))
                        score += 1 - Float(diff) / 255
                        count += 1
                    }
                }
                if count > 0 {
                    score /= Float(count)
                    let displacement = abs(dx) + abs(dy)
                    let bestDisplacement = abs(bestDx) + abs(bestDy)
                    if score > bestScore || (score == bestScore && displacement < bestDisplacement) {
                        bestScore = score
                        bestDx = dx
                        bestDy = dy
                    }
                }
            }
        }

        let applied = bestScore > 0.85 && (bestDx != 0 || bestDy != 0)
        return RefinementResult(applied: applied, dx: Float(bestDx), dy: Float(bestDy))
    }
}

/// Parallax-aware local warp hook — V1 applies identity; architecture for future APAP/mesh warp.
enum PanoramaParallaxWarp {
    static let level = "identity_v1"

    static func applyLocalCorrection(
        colors: [SIMD3<Float>],
        width: Int,
        height: Int
    ) -> [SIMD3<Float>] {
        colors
    }
}
