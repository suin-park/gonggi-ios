import Foundation
import simd

/// RANSAC for constrained rotational flow ≈ image translation (dx, dy) — not full homography.
enum PanoramaRANSAC {
    struct Model: Equatable {
        var dx: Float
        var dy: Float
    }

    struct Result: Equatable {
        var model: Model
        var inlierIndices: [Int]
        var meanReprojError: Float
        var inlierRatio: Float
    }

    /// Fit translational model from left→right matches (pure-rotation local approximation).
    static func fitTranslation(
        matches: [PanoramaFeatureMatcher.Match],
        iterations: Int = Quick360Config.refinementRansacIterations,
        thresholdPx: Float = Quick360Config.refinementInlierThresholdPx
    ) -> Result? {
        guard matches.count >= 2 else { return nil }
        var best: Result?
        for _ in 0..<iterations {
            let i = Int.random(in: 0..<matches.count)
            let m = matches[i]
            let model = Model(dx: m.right.x - m.left.x, dy: m.right.y - m.left.y)
            var inliers: [Int] = []
            var errSum: Float = 0
            for (idx, cand) in matches.enumerated() {
                let pdx = cand.right.x - cand.left.x
                let pdy = cand.right.y - cand.left.y
                let e = hypot(pdx - model.dx, pdy - model.dy)
                if e <= thresholdPx {
                    inliers.append(idx)
                    errSum += e
                }
            }
            let ratio = Float(inliers.count) / Float(matches.count)
            let meanErr = inliers.isEmpty ? 999 : errSum / Float(inliers.count)
            let candidate = Result(
                model: model,
                inlierIndices: inliers,
                meanReprojError: meanErr,
                inlierRatio: ratio
            )
            if best == nil
                || candidate.inlierIndices.count > best!.inlierIndices.count
                || (candidate.inlierIndices.count == best!.inlierIndices.count
                    && candidate.meanReprojError < best!.meanReprojError)
            {
                best = candidate
            }
        }
        guard let best, best.inlierIndices.count >= 2 else { return nil }
        // Refine with inlier mean.
        var sx: Float = 0
        var sy: Float = 0
        for idx in best.inlierIndices {
            let m = matches[idx]
            sx += m.right.x - m.left.x
            sy += m.right.y - m.left.y
        }
        let n = Float(best.inlierIndices.count)
        return Result(
            model: Model(dx: sx / n, dy: sy / n),
            inlierIndices: best.inlierIndices,
            meanReprojError: best.meanReprojError,
            inlierRatio: best.inlierRatio
        )
    }

    /// Reject models with excessive shear/scale hint from inlier vector spread.
    static func isModelPlausible(
        matches: [PanoramaFeatureMatcher.Match],
        result: Result,
        maxScaleDeviation: Float = 0.18
    ) -> Bool {
        let inl = result.inlierIndices.map { matches[$0] }
        guard inl.count >= 3 else { return true }
        var scales: [Float] = []
        for i in 0..<(inl.count - 1) {
            let a = inl[i]
            let b = inl[i + 1]
            let dL = hypot(a.left.x - b.left.x, a.left.y - b.left.y)
            let dR = hypot(a.right.x - b.right.x, a.right.y - b.right.y)
            if dL > 4 {
                scales.append(dR / dL)
            }
        }
        guard !scales.isEmpty else { return true }
        let mean = scales.reduce(0, +) / Float(scales.count)
        return abs(mean - 1) <= maxScaleDeviation
    }

    /// Split matches into top/bottom halves; large (dx,dy) disagreement → parallax.
    static func detectHighParallax(
        matches: [PanoramaFeatureMatcher.Match],
        inlierIndices: [Int],
        disagreementPx: Float = Quick360Config.refinementParallaxDisagreementPx
    ) -> Bool {
        let inl = inlierIndices.map { matches[$0] }
        guard inl.count >= 6 else { return false }
        let midY = inl.map(\.left.y).reduce(0, +) / Float(inl.count)
        let top = inl.filter { $0.left.y < midY }
        let bot = inl.filter { $0.left.y >= midY }
        guard top.count >= 3, bot.count >= 3 else { return false }
        func meanDelta(_ ms: [PanoramaFeatureMatcher.Match]) -> (Float, Float) {
            let dx = ms.map { $0.right.x - $0.left.x }.reduce(0, +) / Float(ms.count)
            let dy = ms.map { $0.right.y - $0.left.y }.reduce(0, +) / Float(ms.count)
            return (dx, dy)
        }
        let t = meanDelta(top)
        let b = meanDelta(bot)
        return hypot(t.0 - b.0, t.1 - b.1) >= disagreementPx
    }
}
