import Foundation
import simd
import UIKit

/// Low-resolution local floor texture atlas with confidence map.
/// Same painting language as sphere: solid gray unseen, clear texture captured.
final class Quick360FloorAtlas {
    let size: Int
    private(set) var rgba: [UInt8]
    private(set) var confidence: [UInt8]
    private var firstSeen: [Double]
    private(set) var updateCount = 0
    private let neutralGray: UInt8 = Quick360Config.unseenNeutralGray

    init(size: Int = Quick360Config.floorTextureSize) {
        self.size = size
        let count = size * size
        rgba = [UInt8](repeating: 0, count: count * 4)
        confidence = [UInt8](repeating: 0, count: count)
        firstSeen = [Double](repeating: 0, count: count)
        clearToGray()
    }

    func reset() {
        updateCount = 0
        firstSeen = [Double](repeating: 0, count: size * size)
        clearToGray()
        for i in 0..<confidence.count { confidence[i] = 0 }
    }

    private func clearToGray() {
        let count = size * size
        for i in 0..<count {
            let o = i * 4
            rgba[o] = neutralGray
            rgba[o + 1] = neutralGray
            rgba[o + 2] = neutralGray
            rgba[o + 3] = 255
        }
    }

    /// Dense FOV projection onto floor UV (no soft mosaic stamps).
    @discardableResult
    func paintFromCamera(
        thumbRGBA: [UInt8],
        thumbWidth: Int,
        thumbHeight: Int,
        cameraTransform: simd_float4x4,
        intrinsics: CameraIntrinsics,
        floor: CapturedFloorSurface,
        observationConfidence: Float,
        dynamicRatio: Float,
        now: TimeInterval = CACurrentMediaTime()
    ) -> Int {
        guard thumbWidth > 1, thumbHeight > 1 else { return 0 }
        let camPos = simd_float3(
            cameraTransform.columns.3.x,
            cameraTransform.columns.3.y,
            cameraTransform.columns.3.z
        )
        let dynamicPenalty = dynamicRatio > 0.25 ? 0.35 : 1.0
        let conf = simd_clamp(observationConfidence * Float(dynamicPenalty), 0, 1)
        guard conf > 0.12 else { return 0 }

        let orientedIntrinsics = Quick360BrushOrientation.remappedIntrinsics(
            intrinsics,
            interface: Quick360BrushOrientation.primaryInterfaceOrientation
        )

        // Dense sampling — every 1–2 thumb pixels for continuous floor paint.
        let stepX = max(1, thumbWidth / 96)
        let stepY = max(1, thumbHeight / 96)
        var painted = 0
        let interiorConf = UInt8(clamping: Int((max(conf, 0.85) * 255).rounded()))
        let featherStart = Quick360Config.brushBoundaryFeatherStart

        var y = 0
        while y < thumbHeight {
            var x = 0
            while x < thumbWidth {
                let nx = (Float(x) + 0.5) / Float(thumbWidth) * 2 - 1
                let ny = (Float(y) + 0.5) / Float(thumbHeight) * 2 - 1
                let edge = max(abs(nx), abs(ny))
                let boundaryWeight: Float
                if edge <= featherStart {
                    boundaryWeight = 1
                } else {
                    boundaryWeight = simd_clamp((1.02 - edge) / max(1.02 - featherStart, 1e-4), 0, 1)
                }
                guard boundaryWeight > 0.04 else {
                    x += stepX
                    continue
                }

                let ray = cameraRayDirection(
                    pixelX: x,
                    pixelY: y,
                    width: thumbWidth,
                    height: thumbHeight,
                    intrinsics: orientedIntrinsics,
                    cameraTransform: cameraTransform
                )
                if Quick360FloorMath.isGrazingAngle(
                    rayDirection: ray,
                    planeNormal: floor.averageNormal,
                    minCos: Quick360Config.floorMinIncidenceCos
                ) {
                    x += stepX
                    continue
                }
                guard let t = Quick360FloorMath.rayPlaneIntersection(
                    rayOrigin: camPos,
                    rayDirection: ray,
                    planePoint: floor.center,
                    planeNormal: floor.averageNormal
                ), t < Quick360Config.floorMaxRadiusM * 2.5 else {
                    x += stepX
                    continue
                }
                let hit = camPos + ray * t
                guard let uv = Quick360FloorMath.worldToFloorUV(
                    worldPoint: hit,
                    floorCenter: floor.center,
                    extentX: floor.extent.x,
                    extentZ: floor.extent.z,
                    worldTransform: floor.worldTransform
                ) else {
                    x += stepX
                    continue
                }

                let px = Int((uv.x * Float(size - 1)).rounded())
                let py = Int((uv.y * Float(size - 1)).rounded())
                guard px >= 0, px < size, py >= 0, py < size else {
                    x += stepX
                    continue
                }
                let ti = (y * thumbWidth + x) * 4
                let r = thumbRGBA[ti]
                let g = thumbRGBA[ti + 1]
                let b = thumbRGBA[ti + 2]
                let idx = py * size + px
                let o = idx * 4
                let prev = confidence[idx]

                if boundaryWeight >= 0.98 {
                    rgba[o] = r
                    rgba[o + 1] = g
                    rgba[o + 2] = b
                    rgba[o + 3] = 255
                    if prev == 0 { firstSeen[idx] = now }
                    confidence[idx] = max(prev, interiorConf)
                } else {
                    let w = boundaryWeight * conf
                    let prevC = Float(prev) / 255
                    if w + 0.08 < prevC {
                        x += stepX
                        continue
                    }
                    rgba[o] = mix(rgba[o], r, w)
                    rgba[o + 1] = mix(rgba[o + 1], g, w)
                    rgba[o + 2] = mix(rgba[o + 2], b, w)
                    if prev == 0 { firstSeen[idx] = now }
                    confidence[idx] = UInt8(clamping: Int((min(1, max(prevC, w)) * 255).rounded()))
                }
                painted += 1
                x += stepX
            }
            y += stepY
        }
        if painted > 0 { updateCount += 1 }
        return painted
    }

    private func cameraRayDirection(
        pixelX: Int,
        pixelY: Int,
        width: Int,
        height: Int,
        intrinsics: CameraIntrinsics,
        cameraTransform: simd_float4x4
    ) -> simd_float3 {
        // Thumb is portrait-normalized; map into oriented full-res intrinsic space.
        let u = (Float(pixelX) + 0.5) / Float(width) * Float(intrinsics.width)
        let v = (Float(pixelY) + 0.5) / Float(height) * Float(intrinsics.height)
        let x = (u - intrinsics.cx) / max(intrinsics.fx, 1)
        let y = (v - intrinsics.cy) / max(intrinsics.fy, 1)
        // Optical forward = local -Z; +X right, +Y down in image → -Y in camera for OpenGL-style?
        // ARKit camera: +X right, +Y up, -Z forward. Image v increases downward → -Y.
        let local = simd_normalize(simd_float3(x, -y, -1))
        let r = simd_float3x3(columns: (
            simd_float3(cameraTransform.columns.0.x, cameraTransform.columns.0.y, cameraTransform.columns.0.z),
            simd_float3(cameraTransform.columns.1.x, cameraTransform.columns.1.y, cameraTransform.columns.1.z),
            simd_float3(cameraTransform.columns.2.x, cameraTransform.columns.2.y, cameraTransform.columns.2.z)
        ))
        return simd_normalize(r * local)
    }

    private func mix(_ a: UInt8, _ b: UInt8, _ t: Float) -> UInt8 {
        UInt8(clamping: Int(Float(a) * (1 - t) + Float(b) * t))
    }

    func coveragePercent(minConfidence: Float = 0.1) -> Float {
        let thr = UInt8(clamping: Int(minConfidence * 255))
        let hit = confidence.reduce(0) { $0 + ($1 >= thr ? 1 : 0) }
        return Float(hit) / Float(max(confidence.count, 1)) * 100
    }

    func goodCoveragePercent() -> Float {
        coveragePercent(minConfidence: Quick360Config.floorGoodConfidence)
    }

    func confidenceMaskRGBA() -> [UInt8] {
        var out = [UInt8](repeating: 0, count: size * size * 4)
        for i in 0..<confidence.count {
            let c = confidence[i]
            let o = i * 4
            out[o] = c
            out[o + 1] = c
            out[o + 2] = c
            out[o + 3] = 255
        }
        return out
    }

    func composePreviewRGBA(now: TimeInterval) -> [UInt8] {
        let fade = max(Quick360Config.brushRevealFadeSec, 0.05)
        let weakThr = UInt8(clamping: Int(Quick360Config.floorWeakConfidence * 255))
        let goodThr = UInt8(clamping: Int(Quick360Config.floorGoodConfidence * 255))
        let veil = Quick360Config.weakConfidenceVeil
        var out = [UInt8](repeating: 0, count: size * size * 4)
        let gray = Float(neutralGray)

        for i in 0..<(size * size) {
            let o = i * 4
            let c = confidence[i]
            if c == 0 {
                out[o] = neutralGray
                out[o + 1] = neutralGray
                out[o + 2] = neutralGray
                out[o + 3] = 255
                continue
            }
            var r = Float(rgba[o])
            var g = Float(rgba[o + 1])
            var b = Float(rgba[o + 2])
            let seen = firstSeen[i]
            let age = seen > 0 ? now - seen : fade
            let reveal = simd_clamp(Float(age / fade), 0, 1)
            r = gray * (1 - reveal) + r * reveal
            g = gray * (1 - reveal) + g * reveal
            b = gray * (1 - reveal) + b * reveal
            if c < goodThr {
                let amount = c < weakThr ? veil * 1.25 : veil
                r = r * (1 - amount) + gray * amount
                g = g * (1 - amount) + gray * amount
                b = b * (1 - amount) + gray * amount
            }
            out[o] = UInt8(clamping: Int(r.rounded()))
            out[o + 1] = UInt8(clamping: Int(g.rounded()))
            out[o + 2] = UInt8(clamping: Int(b.rounded()))
            out[o + 3] = 255
        }
        return out
    }

    func makeUIImage(now: TimeInterval = CACurrentMediaTime()) -> UIImage? {
        Quick360ImageBuffer.uiImage(rgba: composePreviewRGBA(now: now), width: size, height: size)
    }

    func makeCGImage(now: TimeInterval = CACurrentMediaTime()) -> CGImage? {
        Quick360ImageBuffer.cgImage(rgba: composePreviewRGBA(now: now), width: size, height: size)
    }
}

/// Selects a stable local floor plane from ARKit horizontal anchors (non-LiDAR safe).
enum Quick360FloorDetector {
    struct Candidate: Equatable {
        let identifier: UUID
        let worldTransform: simd_float4x4
        let extent: simd_float3
        let alignment: String
        let updateCount: Int
    }

    static func selectBest(
        candidates: [Candidate],
        cameraTransform: simd_float4x4,
        originTransform: simd_float4x4
    ) -> Candidate? {
        guard !candidates.isEmpty else { return nil }
        let camY = cameraTransform.columns.3.y
        let origin = simd_float3(
            originTransform.columns.3.x,
            originTransform.columns.3.y,
            originTransform.columns.3.z
        )

        let scored = candidates.compactMap { c -> (Candidate, Float)? in
            let center = simd_float3(c.worldTransform.columns.3.x, c.worldTransform.columns.3.y, c.worldTransform.columns.3.z)
            let below = camY - center.y
            guard below > -0.2, below < Quick360Config.floorPreferredMaxDepthBelowCameraM else { return nil }
            let horizontal = simd_length(simd_float2(center.x - origin.x, center.z - origin.z))
            guard horizontal < Quick360Config.floorMaxRadiusM * 1.5 else { return nil }
            let area = max(c.extent.x * c.extent.z, 0.01)
            let score = area * 2 + Float(c.updateCount) * 0.5 - horizontal - abs(below - 1.4) * 0.3
            return (c, score)
        }
        return scored.max(by: { $0.1 < $1.1 })?.0
    }
}
