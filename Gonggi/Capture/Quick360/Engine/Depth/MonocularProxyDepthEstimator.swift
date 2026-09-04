import Foundation
import simd

/// Build 27 primary `monocularProxy`: geometric relative depth (no ML binary required).
///
/// Pipeline:
/// 1) Sparse multi-view triangulation on a coarse grid using ARKit poses
/// 2) Per-frame median fill + edge-aware confidence
/// 3) Cross-frame median scale normalization on overlap samples
/// 4) Extreme depth clamp
///
/// Optional Core ML Depth Anything path is documented but not required for CI.
struct MonocularProxyDepthEstimator: DepthMapProviding {
    let mode: DepthSourceMode = .monocularProxy
    var gridStep: Int = 16
    var minDepth: Float = 0.4
    var maxDepth: Float = 12.0
    var defaultPlaneDepth: Float = 2.5

    func depthMap(
        rgba: [UInt8],
        width: Int,
        height: Int,
        frameIndex: Int,
        cameraTransform: simd_float4x4,
        intrinsics: CameraIntrinsics,
        neighbors: [DepthNeighborHint]
    ) -> DepthFrameMap {
        let n = width * height
        guard n > 0, rgba.count >= n * 4 else {
            return .invalid(width: width, height: height, label: "empty")
        }

        var depth = [Float](repeating: 0, count: n)
        var conf = [Float](repeating: 0, count: n)
        var sparseSamples: [(Int, Float)] = []

        let gray = Self.toGray(rgba: rgba, width: width, height: height)
        let Ti = cameraTransform
        let Ci = Self.cameraCenter(Ti)

        for ny in stride(from: gridStep / 2, to: height, by: gridStep) {
            for nx in stride(from: gridStep / 2, to: width, by: gridStep) {
                let ray = DepthReprojectionMath.cameraRay(
                    u: Float(nx), v: Float(ny), K: intrinsics
                )
                var bestD: Float?
                var bestScore: Float = .greatestFiniteMagnitude

                for nb in neighbors {
                    let Tj = nb.cameraTransform
                    let Cj = Self.cameraCenter(Tj)
                    let baseline = simd_length(Cj - Ci)
                    if baseline < 0.02 { continue }

                    // Photometric 1D search along ray in world → project into neighbor.
                    let searchMin = minDepth
                    let searchMax = maxDepth
                    let steps = 12
                    for s in 0..<steps {
                        let t = Float(s) / Float(steps - 1)
                        let d = searchMin + t * (searchMax - searchMin)
                        let Pw = DepthReprojectionMath.worldPoint(
                            depth: d, rayCam: ray, cameraToWorld: Ti
                        )
                        guard let uvj = DepthReprojectionMath.projectWorldToPixel(
                            Pw, cameraToWorld: Tj, K: nb.intrinsics,
                            width: nb.width, height: nb.height
                        ) else { continue }
                        let cost = Self.patchSAD(
                            grayA: gray, wA: width, hA: height, xA: nx, yA: ny,
                            rgbaB: nb.rgba, wB: nb.width, hB: nb.height,
                            xB: Int(uvj.x.rounded()), yB: Int(uvj.y.rounded()),
                            radius: 2
                        )
                        if cost < bestScore {
                            bestScore = cost
                            bestD = d
                        }
                    }
                }

                if let d = bestD, bestScore < 80 {
                    let idx = ny * width + nx
                    depth[idx] = d
                    conf[idx] = max(0.15, min(1, 1 - bestScore / 120))
                    sparseSamples.append((idx, d))
                }
            }
        }

        let median = Self.median(sparseSamples.map(\.1)) ?? defaultPlaneDepth
        // Dense fill: plane prior + nearest sparse influence.
        for y in 0..<height {
            for x in 0..<width {
                let idx = y * width + x
                if conf[idx] > 0 { continue }
                depth[idx] = median
                // Lower confidence for filled pixels; reduce further near strong edges.
                let edge = Self.edgeStrength(gray: gray, width: width, height: height, x: x, y: y)
                conf[idx] = max(0.05, 0.35 * (1 - min(1, edge / 40)))
            }
        }

        // Propagate sparse highs over a small radius.
        for (idx, d) in sparseSamples {
            let y0 = idx / width
            let x0 = idx % width
            let r = max(2, gridStep / 3)
            for dy in -r...r {
                for dx in -r...r {
                    let x = x0 + dx
                    let y = y0 + dy
                    if x < 0 || y < 0 || x >= width || y >= height { continue }
                    let j = y * width + x
                    let w = 1 / (1 + Float(dx * dx + dy * dy))
                    if conf[j] < 0.5 {
                        depth[j] = depth[j] * (1 - w) + d * w
                        conf[j] = max(conf[j], 0.45 * w + conf[j] * (1 - w))
                    }
                }
            }
        }

        // Depth discontinuity: lower confidence on strong depth gradients.
        var outConf = conf
        for y in 1..<height - 1 {
            for x in 1..<width - 1 {
                let i = y * width + x
                let gx = abs(depth[i + 1] - depth[i - 1])
                let gy = abs(depth[i + width] - depth[i - width])
                let g = max(gx, gy)
                if g > 0.35 * median {
                    outConf[i] *= 0.25
                }
            }
        }

        var map = DepthFrameMap(
            width: width,
            height: height,
            depth: depth,
            confidence: outConf,
            isMetric: true,
            sourceLabel: "monocularProxy_geometric_mvs_lite"
        )
        map = map.clamped(minD: minDepth, maxD: maxDepth)

        // Neighbor overlap scale consistency (median ratio).
        if let scale = Self.overlapScale(
            map: map, transform: Ti, K: intrinsics, neighbors: neighbors,
            minDepth: minDepth, maxDepth: maxDepth
        ), abs(scale - 1) > 0.05, abs(scale - 1) < 0.6 {
            map.applyMedianScale(scale)
        }
        return map
    }

    // MARK: - Helpers

    static func cameraCenter(_ T: simd_float4x4) -> simd_float3 {
        simd_float3(T.columns.3.x, T.columns.3.y, T.columns.3.z)
    }

    static func toGray(rgba: [UInt8], width: Int, height: Int) -> [Float] {
        var g = [Float](repeating: 0, count: width * height)
        for i in 0..<width * height {
            let o = i * 4
            let r = Float(rgba[o])
            let gr = Float(rgba[o + 1])
            let b = Float(rgba[o + 2])
            g[i] = 0.299 * r + 0.587 * gr + 0.114 * b
        }
        return g
    }

    static func edgeStrength(gray: [Float], width: Int, height: Int, x: Int, y: Int) -> Float {
        if x <= 0 || y <= 0 || x >= width - 1 || y >= height - 1 { return 0 }
        let i = y * width + x
        let gx = abs(gray[i + 1] - gray[i - 1])
        let gy = abs(gray[i + width] - gray[i - width])
        return max(gx, gy)
    }

    static func patchSAD(
        grayA: [Float], wA: Int, hA: Int, xA: Int, yA: Int,
        rgbaB: [UInt8], wB: Int, hB: Int, xB: Int, yB: Int,
        radius: Int
    ) -> Float {
        var sum: Float = 0
        var count: Float = 0
        for dy in -radius...radius {
            for dx in -radius...radius {
                let ax = xA + dx
                let ay = yA + dy
                let bx = xB + dx
                let by = yB + dy
                if ax < 0 || ay < 0 || ax >= wA || ay >= hA { continue }
                if bx < 0 || by < 0 || bx >= wB || by >= hB { continue }
                let ga = grayA[ay * wA + ax]
                let o = (by * wB + bx) * 4
                let gb = 0.299 * Float(rgbaB[o]) + 0.587 * Float(rgbaB[o + 1]) + 0.114 * Float(rgbaB[o + 2])
                sum += abs(ga - gb)
                count += 1
            }
        }
        return count > 0 ? sum / count : 1e6
    }

    static func median(_ vals: [Float]) -> Float? {
        guard !vals.isEmpty else { return nil }
        let v = vals.sorted()
        return v[v.count / 2]
    }

    /// Align frame median depth toward neighbor geometric consistency.
    static func overlapScale(
        map: DepthFrameMap,
        transform: simd_float4x4,
        K: CameraIntrinsics,
        neighbors: [DepthNeighborHint],
        minDepth: Float,
        maxDepth: Float
    ) -> Float? {
        guard let med = map.medianPositiveDepth(), med > 1e-3 else { return nil }
        var ratios: [Float] = []
        let step = max(24, map.width / 20)
        for y in stride(from: step, to: map.height - step, by: step) {
            for x in stride(from: step, to: map.width - step, by: step) {
                let i = y * map.width + x
                guard map.confidence[i] > 0.4 else { continue }
                let d = map.depth[i]
                let ray = DepthReprojectionMath.cameraRay(u: Float(x), v: Float(y), K: K)
                let Pw = DepthReprojectionMath.worldPoint(depth: d, rayCam: ray, cameraToWorld: transform)
                for nb in neighbors {
                    let Cj = cameraCenter(nb.cameraTransform)
                    let dist = simd_length(Pw - Cj)
                    if dist > minDepth * 0.5 && dist < maxDepth * 1.2 {
                        ratios.append(dist / max(d, 1e-4))
                    }
                }
            }
        }
        guard ratios.count >= 8, let r = median(ratios) else { return nil }
        // Soft pull toward 1.
        return 0.5 + 0.5 * r
    }
}

/// Injected / test depth provider.
struct InjectedDepthProvider: DepthMapProviding {
    let mode: DepthSourceMode = .monocularProxy
    let maps: [Int: DepthFrameMap]

    func depthMap(
        rgba: [UInt8],
        width: Int,
        height: Int,
        frameIndex: Int,
        cameraTransform: simd_float4x4,
        intrinsics: CameraIntrinsics,
        neighbors: [DepthNeighborHint]
    ) -> DepthFrameMap {
        if let m = maps[frameIndex], m.width == width, m.height == height {
            return m
        }
        return MonocularProxyDepthEstimator().depthMap(
            rgba: rgba, width: width, height: height, frameIndex: frameIndex,
            cameraTransform: cameraTransform, intrinsics: intrinsics, neighbors: neighbors
        )
    }
}

/// ARKit sceneDepth optional path — returns invalid unless maps supplied (capture wiring later).
struct ARKitDepthIfAvailableProvider: DepthMapProviding {
    let mode: DepthSourceMode = .arkitDepthIfAvailable
    var supplied: [Int: DepthFrameMap] = [:]

    func depthMap(
        rgba: [UInt8],
        width: Int,
        height: Int,
        frameIndex: Int,
        cameraTransform: simd_float4x4,
        intrinsics: CameraIntrinsics,
        neighbors: [DepthNeighborHint]
    ) -> DepthFrameMap {
        if let m = supplied[frameIndex] { return m }
        return .invalid(width: width, height: height, label: "arkit_depth_unavailable")
    }
}
