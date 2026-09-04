import Foundation
import simd

/// Accumulator for depth-aware LatLong fusion (Build 27).
final class DepthReprojectionCanvas {
    let width: Int
    let height: Int
    private(set) var sumR: [Float]
    private(set) var sumG: [Float]
    private(set) var sumB: [Float]
    private(set) var sumW: [Float]
    private(set) var zNear: [Float]
    private(set) var sourceCount: [UInt16]
    private(set) var holeFlags: [UInt8] // bitfield classifiers
    private(set) var conflictCount: Int = 0
    private(set) var discontinuityRejects: Int = 0
    private(set) var acceptedSplats: Int = 0
    private(set) var depthInvalidSkips: Int = 0

    // Hole class bits
    static let holeCapture: UInt8 = 1 << 0
    static let holeDepthInvalid: UInt8 = 1 << 1
    static let holeVisibility: UInt8 = 1 << 2
    static let holeOverlap: UInt8 = 1 << 3

    init(width: Int, height: Int) {
        self.width = width
        self.height = height
        let n = width * height
        sumR = [Float](repeating: 0, count: n)
        sumG = [Float](repeating: 0, count: n)
        sumB = [Float](repeating: 0, count: n)
        sumW = [Float](repeating: 0, count: n)
        zNear = [Float](repeating: .greatestFiniteMagnitude, count: n)
        sourceCount = [UInt16](repeating: 0, count: n)
        holeFlags = [UInt8](repeating: holeCapture, count: n)
    }

    func splat(
        colorR: Float, colorG: Float, colorB: Float,
        px: Float, py: Float,
        radius: Float,
        weight: Float,
        depthFromOrigin: Float,
        depthConfidence: Float,
        depthGradientHigh: Bool
    ) {
        guard weight > 1e-6, depthConfidence > 0.02 else {
            depthInvalidSkips += 1
            return
        }
        let rEff = depthGradientHigh ? min(radius, 0.85) : radius
        let r0 = Int(floor(px - rEff))
        let r1 = Int(ceil(px + rEff))
        let c0 = Int(floor(py - rEff))
        let c1 = Int(ceil(py + rEff))
        let r2 = rEff * rEff

        for y in max(0, c0)...min(height - 1, c1) {
            for x in max(0, r0)...min(width - 1, r1) {
                let dx = Float(x) - px
                let dy = Float(y) - py
                let d2 = dx * dx + dy * dy
                if d2 > r2 { continue }
                let kernel = exp(-d2 / max(0.25, r2 * 0.55))
                let idx = y * width + x
                let w = weight * kernel * depthConfidence

                // Z-buffer gate: reject clearly farther surfaces (ghosting).
                if depthFromOrigin > zNear[idx] * 1.08 && sumW[idx] > 1e-4 {
                    if abs(depthFromOrigin - zNear[idx]) > 0.12 {
                        if depthGradientHigh {
                            discontinuityRejects += 1
                            continue
                        }
                        conflictCount += 1
                        // Soft down-weight far contributor instead of hard overwrite.
                        let farW = w * 0.15
                        accumulate(idx: idx, r: colorR, g: colorG, b: colorB, w: farW)
                        continue
                    }
                }
                if depthFromOrigin < zNear[idx] {
                    zNear[idx] = depthFromOrigin
                }
                accumulate(idx: idx, r: colorR, g: colorG, b: colorB, w: w)
                if sourceCount[idx] < .max {
                    sourceCount[idx] &+= 1
                }
                holeFlags[idx] = 0
                acceptedSplats += 1
            }
        }
    }

    private func accumulate(idx: Int, r: Float, g: Float, b: Float, w: Float) {
        sumR[idx] += r * w
        sumG[idx] += g * w
        sumB[idx] += b * w
        sumW[idx] += w
    }

    func markDepthInvalidRegion() {
        // Pixels still empty keep capture hole; callers may OR depth-invalid on unused rays.
    }

    struct ComposeResult {
        var rgba: [UInt8]
        var holeMask: [UInt8]
        var coveragePercent: Double
        var holePercent: Double
        var observedPercent: Double
        var avgSources: Double
        var p90Sources: Double
        var conflictPercent: Double
        var discontinuityRejectPercent: Double
        var holeCapturePercent: Double
        var holeDepthPercent: Double
        var holeVisibilityPercent: Double
        var holeOverlapPercent: Double
    }

    func compose(exposureGains _: [Float] = []) -> ComposeResult {
        let n = width * height
        var rgba = [UInt8](repeating: 0, count: n * 4)
        var hole = [UInt8](repeating: 0, count: n)
        var sources: [Float] = []
        sources.reserveCapacity(n / 4)
        var observed = 0
        var hCap = 0, hDep = 0, hVis = 0, hOv = 0

        for i in 0..<n {
            let w = sumW[i]
            if w > 1e-4 {
                observed += 1
                let inv = 1 / w
                rgba[i * 4] = UInt8(clamping: Int((sumR[i] * inv).rounded()))
                rgba[i * 4 + 1] = UInt8(clamping: Int((sumG[i] * inv).rounded()))
                rgba[i * 4 + 2] = UInt8(clamping: Int((sumB[i] * inv).rounded()))
                rgba[i * 4 + 3] = 255
                sources.append(Float(sourceCount[i]))
            } else {
                hole[i] = 255
                let f = holeFlags[i]
                if f & Self.holeDepthInvalid != 0 { hDep += 1 }
                else if f & Self.holeVisibility != 0 { hVis += 1 }
                else if f & Self.holeOverlap != 0 { hOv += 1 }
                else { hCap += 1 }
            }
        }

        sources.sort()
        let avg = sources.isEmpty ? 0 : Double(sources.reduce(0, +)) / Double(sources.count)
        let p90 = sources.isEmpty ? 0 : Double(sources[min(sources.count - 1, Int(Double(sources.count) * 0.9))])
        let totalSplatAttempts = max(1, acceptedSplats + discontinuityRejects + conflictCount)

        return ComposeResult(
            rgba: rgba,
            holeMask: hole,
            coveragePercent: 100.0 * Double(observed) / Double(max(1, n)),
            holePercent: 100.0 * Double(n - observed) / Double(max(1, n)),
            observedPercent: 100.0 * Double(observed) / Double(max(1, n)),
            avgSources: avg,
            p90Sources: p90,
            conflictPercent: 100.0 * Double(conflictCount) / Double(totalSplatAttempts),
            discontinuityRejectPercent: 100.0 * Double(discontinuityRejects) / Double(totalSplatAttempts),
            holeCapturePercent: 100.0 * Double(hCap) / Double(max(1, n)),
            holeDepthPercent: 100.0 * Double(hDep) / Double(max(1, n)),
            holeVisibilityPercent: 100.0 * Double(hVis) / Double(max(1, n)),
            holeOverlapPercent: 100.0 * Double(hOv) / Double(max(1, n))
        )
    }

    func coverageConfidenceRGBA() -> (cov: [UInt8], conf: [UInt8], depthViz: [UInt8]) {
        let n = width * height
        var cov = [UInt8](repeating: 0, count: n * 4)
        var conf = [UInt8](repeating: 0, count: n * 4)
        var depthViz = [UInt8](repeating: 0, count: n * 4)
        var zMax: Float = 1
        for z in zNear where z.isFinite && z < .greatestFiniteMagnitude / 2 {
            zMax = max(zMax, z)
        }
        for i in 0..<n {
            let on = sumW[i] > 1e-4
            let v: UInt8 = on ? 255 : 0
            cov[i * 4] = v; cov[i * 4 + 1] = v; cov[i * 4 + 2] = v; cov[i * 4 + 3] = 255
            let c = UInt8(clamping: Int(min(1, sumW[i] / 3) * 255))
            conf[i * 4] = c; conf[i * 4 + 1] = c; conf[i * 4 + 2] = c; conf[i * 4 + 3] = 255
            if on, zNear[i] < .greatestFiniteMagnitude / 2 {
                let t = UInt8(clamping: Int((1 - zNear[i] / zMax) * 255))
                depthViz[i * 4] = t; depthViz[i * 4 + 1] = t; depthViz[i * 4 + 2] = t; depthViz[i * 4 + 3] = 255
            } else {
                depthViz[i * 4 + 3] = 255
            }
        }
        return (cov, conf, depthViz)
    }
}
