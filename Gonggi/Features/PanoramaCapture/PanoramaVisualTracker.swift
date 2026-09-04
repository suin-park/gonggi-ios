import Foundation

// MARK: - Config extensions for Build 31 visual tracking

extension PanoramaCaptureConfig {
    /// Wide center crop used for visual registration (not the final strip).
    static var trackingCropWidthPx: Int = 360
    /// Horizontal search half-width around yaw-expected dx (px at full tracking scale).
    static var trackingSearchXPx: Int = 64
    /// Vertical search half-width (px).
    static var trackingSearchYPx: Int = 28
    /// Max |dy| applied per accepted step (px).
    static var maxStepVerticalPx: Float = 12
    /// Max cumulative |vertical offset| (px).
    static var maxCumulativeVerticalPx: Float = 80
    /// Reverse yaw beyond this → reject (direction lock).
    static var reverseYawRejectDeg: Float = 2.0
    /// Minimum tracking texture variance (luma) to allow visual correction.
    static var minTrackingVariance: Float = 80
    /// Minimum NCC best score.
    static var minNCCScore: Float = 0.35
    /// Minimum (best - secondBest) margin.
    static var minNCCMargin: Float = 0.03
    /// High confidence threshold for visual-heavy blend.
    static var highConfidence: Float = 0.72
    /// Medium confidence threshold.
    static var mediumConfidence: Float = 0.48
}

// MARK: - Tracking sample / match

struct PanoramaTrackingSample {
    var index: Int
    var rawYawDeg: Float
    var relativeYawDeg: Float
    var trackingGray: [Float]
    var trackingWidth: Int
    var trackingHeight: Int
    var stripRGBA: [UInt8]
    var stripWidth: Int
    var stripHeight: Int
    var predictedX: Float
    var correctedX: Float
    var correctedY: Float
}

struct PanoramaTrackingPairDebug: Codable, Equatable {
    var prevIndex: Int
    var currIndex: Int
    var yawDeltaDeg: Float
    var expectedDx: Float
    var visualDx: Float
    var visualDy: Float
    var correctedX: Float
    var correctedY: Float
    var nccBest: Float
    var nccSecond: Float
    var confidence: Float
    var usedVisualCorrection: Bool
    var fallbackReason: String?
}

struct PanoramaVisualMatch {
    var visualDx: Float
    var visualDy: Float
    var nccBest: Float
    var nccSecond: Float
    var confidence: Float
    var textureOK: Bool
    var usedVisual: Bool
    var fallbackReason: String?
}

/// Lightweight coarse→fine NCC tracker for panorama strip placement.
enum PanoramaVisualTracker {
    static func textureVariance(_ gray: [Float]) -> Float {
        guard !gray.isEmpty else { return 0 }
        var sum: Float = 0
        var sumSq: Float = 0
        let n = Float(gray.count)
        for v in gray {
            sum += v
            sumSq += v * v
        }
        let mean = sum / n
        return max(0, sumSq / n - mean * mean)
    }

    static func gradientEnergy(_ gray: [Float], width: Int, height: Int) -> Float {
        guard width > 2, height > 2 else { return 0 }
        var e: Float = 0
        var n: Float = 0
        for y in stride(from: 1, to: height - 1, by: 2) {
            for x in stride(from: 1, to: width - 1, by: 2) {
                let i = y * width + x
                let gx = gray[i + 1] - gray[i - 1]
                let gy = gray[i + width] - gray[i - width]
                e += abs(gx) + abs(gy)
                n += 1
            }
        }
        return n > 0 ? e / n : 0
    }

    /// Match curr onto prev: returns (dx,dy) such that curr(x+dx,y+dy) ≈ prev(x,y).
    /// expectedDx is the yaw-prior horizontal displacement (canvas / image space).
    static func match(
        prev: [Float],
        prevW: Int,
        prevH: Int,
        curr: [Float],
        currW: Int,
        currH: Int,
        expectedDx: Float
    ) -> PanoramaVisualMatch {
        let varP = textureVariance(prev)
        let varC = textureVariance(curr)
        let texOK = min(varP, varC) >= PanoramaCaptureConfig.minTrackingVariance
            && gradientEnergy(curr, width: currW, height: currH) > 4

        if !texOK {
            return PanoramaVisualMatch(
                visualDx: expectedDx, visualDy: 0,
                nccBest: 0, nccSecond: 0, confidence: 0,
                textureOK: false, usedVisual: false,
                fallbackReason: "weak_texture"
            )
        }

        // Level 1: 1/4 scale coarse
        let (p4, w4, h4) = downsample(prev, prevW, prevH, factor: 4)
        let (c4, _, _) = downsample(curr, currW, currH, factor: 4)
        let exp4 = expectedDx / 4
        let sx4 = max(4, PanoramaCaptureConfig.trackingSearchXPx / 4)
        let sy4 = max(3, PanoramaCaptureConfig.trackingSearchYPx / 4)
        let coarse = nccSearch(
            prev: p4, prevW: w4, prevH: h4,
            curr: c4, currW: w4, currH: h4,
            centerDx: exp4, centerDy: 0,
            searchX: sx4, searchY: sy4,
            step: 1
        )

        // Level 2: 1/2 scale — refine dx primarily (keep dy near coarse*2)
        let (p2, w2, h2) = downsample(prev, prevW, prevH, factor: 2)
        let (c2, _, _) = downsample(curr, currW, currH, factor: 2)
        let refineX = nccSearch(
            prev: p2, prevW: w2, prevH: h2,
            curr: c2, currW: w2, currH: h2,
            centerDx: coarse.bestDx * 2, centerDy: coarse.bestDy * 2,
            searchX: 6, searchY: 3,
            step: 1
        )

        // Level 3: full-scale 1D dy refine at locked dx (avoids dx/dy swap false peaks)
        let fullDx = Int(round(refineX.bestDx * 2))
        let fullDyCenter = Int(round(refineX.bestDy * 2))
        let dyRefine = nccSearch(
            prev: prev, prevW: prevW, prevH: prevH,
            curr: curr, currW: currW, currH: currH,
            centerDx: Float(fullDx), centerDy: Float(fullDyCenter),
            searchX: 2, searchY: PanoramaCaptureConfig.trackingSearchYPx,
            step: 1
        )

        let dx = dyRefine.bestDx
        let dy = dyRefine.bestDy
        let best = dyRefine.bestScore
        let second = max(dyRefine.secondScore, refineX.secondScore)
        let margin = best - second

        if best < PanoramaCaptureConfig.minNCCScore {
            return PanoramaVisualMatch(
                visualDx: expectedDx, visualDy: 0,
                nccBest: best, nccSecond: second, confidence: 0,
                textureOK: true, usedVisual: false,
                fallbackReason: "low_ncc"
            )
        }
        if margin < PanoramaCaptureConfig.minNCCMargin {
            return PanoramaVisualMatch(
                visualDx: expectedDx, visualDy: 0,
                nccBest: best, nccSecond: second, confidence: max(0, margin * 4),
                textureOK: true, usedVisual: false,
                fallbackReason: "ambiguous_match"
            )
        }

        // Reject absurd outliers vs yaw prior.
        let err = abs(dx - expectedDx)
        if err > Float(PanoramaCaptureConfig.trackingSearchXPx) + 20 {
            return PanoramaVisualMatch(
                visualDx: expectedDx, visualDy: 0,
                nccBest: best, nccSecond: second, confidence: 0.1,
                textureOK: true, usedVisual: false,
                fallbackReason: "outlier_vs_yaw"
            )
        }

        let conf = confidence(best: best, margin: margin, textureVar: min(varP, varC))
        return PanoramaVisualMatch(
            visualDx: dx, visualDy: dy,
            nccBest: best, nccSecond: second, confidence: conf,
            textureOK: true, usedVisual: true,
            fallbackReason: nil
        )
    }

    /// Blend visual accumulation with global yaw prior.
    static func blendPlacement(
        visualAccumX: Float,
        yawPriorX: Float,
        confidence: Float
    ) -> (x: Float, visualWeight: Float) {
        let wVisual: Float
        if confidence >= PanoramaCaptureConfig.highConfidence {
            wVisual = 0.80
        } else if confidence >= PanoramaCaptureConfig.mediumConfidence {
            wVisual = 0.50
        } else if confidence > 0.15 {
            wVisual = 0.25
        } else {
            wVisual = 0
        }
        let x = wVisual * visualAccumX + (1 - wVisual) * yawPriorX
        return (x, wVisual)
    }

    // MARK: - Internals

    private static func confidence(best: Float, margin: Float, textureVar: Float) -> Float {
        let sBest = min(1, max(0, (best - 0.2) / 0.7))
        let sMargin = min(1, max(0, margin / 0.15))
        let sTex = min(1, max(0, (textureVar - 80) / 400))
        return 0.45 * sBest + 0.35 * sMargin + 0.20 * sTex
    }

    private static func downsample(
        _ src: [Float], _ w: Int, _ h: Int, factor: Int
    ) -> ([Float], Int, Int) {
        let nw = max(1, w / factor)
        let nh = max(1, h / factor)
        var out = [Float](repeating: 0, count: nw * nh)
        for y in 0..<nh {
            for x in 0..<nw {
                var sum: Float = 0
                var n: Float = 0
                let y0 = y * factor
                let x0 = x * factor
                for dy in 0..<factor {
                    let sy = y0 + dy
                    if sy >= h { continue }
                    for dx in 0..<factor {
                        let sx = x0 + dx
                        if sx >= w { continue }
                        sum += src[sy * w + sx]
                        n += 1
                    }
                }
                out[y * nw + x] = n > 0 ? sum / n : 0
            }
        }
        return (out, nw, nh)
    }

    private struct SearchResult {
        var bestDx: Float
        var bestDy: Float
        var bestScore: Float
        var secondScore: Float
    }

    private static func nccSearch(
        prev: [Float], prevW: Int, prevH: Int,
        curr: [Float], currW: Int, currH: Int,
        centerDx: Float, centerDy: Float,
        searchX: Int, searchY: Int,
        step: Int
    ) -> SearchResult {
        var bestScore: Float = -1
        var second: Float = -1
        var bestDx = centerDx
        var bestDy = centerDy
        let x0 = Int(round(centerDx)) - searchX
        let x1 = Int(round(centerDx)) + searchX
        let y0 = Int(round(centerDy)) - searchY
        let y1 = Int(round(centerDy)) + searchY
        for dy in stride(from: y0, through: y1, by: step) {
            for dx in stride(from: x0, through: x1, by: step) {
                let score = ncc(
                    prev: prev, prevW: prevW, prevH: prevH,
                    curr: curr, currW: currW, currH: currH,
                    dx: dx, dy: dy
                )
                if score > bestScore {
                    second = bestScore
                    bestScore = score
                    bestDx = Float(dx)
                    bestDy = Float(dy)
                } else if score > second {
                    second = score
                }
            }
        }
        return SearchResult(
            bestDx: bestDx, bestDy: bestDy,
            bestScore: bestScore, secondScore: max(second, -1)
        )
    }

    /// Zero-mean NCC over overlap of prev with curr shifted by (dx,dy).
    private static func ncc(
        prev: [Float], prevW: Int, prevH: Int,
        curr: [Float], currW: Int, currH: Int,
        dx: Int, dy: Int
    ) -> Float {
        let xStart = max(0, -dx)
        let yStart = max(0, -dy)
        let xEnd = min(prevW, currW - dx)
        let yEnd = min(prevH, currH - dy)
        let ow = xEnd - xStart
        let oh = yEnd - yStart
        guard ow > 8, oh > 16 else { return -1 }

        // Subsample for speed.
        let stepX = max(1, ow / 48)
        let stepY = max(1, oh / 64)
        var sumP: Float = 0, sumC: Float = 0, sumPP: Float = 0, sumCC: Float = 0, sumPC: Float = 0
        var n: Float = 0
        var y = yStart
        while y < yEnd {
            var x = xStart
            while x < xEnd {
                let pv = prev[y * prevW + x]
                let cv = curr[(y + dy) * currW + (x + dx)]
                sumP += pv; sumC += cv
                sumPP += pv * pv; sumCC += cv * cv
                sumPC += pv * cv
                n += 1
                x += stepX
            }
            y += stepY
        }
        guard n > 16 else { return -1 }
        let meanP = sumP / n
        let meanC = sumC / n
        let num = sumPC - n * meanP * meanC
        let denP = sumPP - n * meanP * meanP
        let denC = sumCC - n * meanC * meanC
        let den = sqrt(max(1e-3, denP) * max(1e-3, denC))
        return num / den
    }
}
