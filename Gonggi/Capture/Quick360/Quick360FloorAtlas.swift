import Foundation
import simd
import UIKit

/// Low-resolution local floor texture atlas with confidence map.
final class Quick360FloorAtlas {
    let size: Int
    private(set) var rgba: [UInt8]
    private(set) var confidence: [UInt8]
    private(set) var updateCount = 0
    private let neutralGray: UInt8 = 145

    init(size: Int = Quick360Config.floorTextureSize) {
        self.size = size
        let count = size * size
        rgba = [UInt8](repeating: 0, count: count * 4)
        confidence = [UInt8](repeating: 0, count: count)
        clearToGray()
    }

    func reset() {
        updateCount = 0
        clearToGray()
    }

    private func clearToGray() {
        let count = size * size
        for i in 0..<count {
            let o = i * 4
            rgba[o] = neutralGray
            rgba[o + 1] = neutralGray
            rgba[o + 2] = neutralGray
            rgba[o + 3] = 255
            confidence[i] = 0
        }
    }

    /// Project camera thumb onto floor UV via ray-plane hits.
    @discardableResult
    func paintFromCamera(
        thumbRGBA: [UInt8],
        thumbWidth: Int,
        thumbHeight: Int,
        cameraTransform: simd_float4x4,
        intrinsics: CameraIntrinsics,
        floor: CapturedFloorSurface,
        observationConfidence: Float,
        dynamicRatio: Float
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

        let stepX = max(1, thumbWidth / 20)
        let stepY = max(1, thumbHeight / 20)
        let stampR = max(2, size / 40)
        var painted = 0

        var y = 0
        while y < thumbHeight {
            var x = 0
            while x < thumbWidth {
                let ray = cameraRayDirection(
                    pixelX: x,
                    pixelY: y,
                    width: thumbWidth,
                    height: thumbHeight,
                    intrinsics: intrinsics,
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
                let ti = (y * thumbWidth + x) * 4
                stamp(
                    cx: px, cy: py, radius: stampR,
                    r: thumbRGBA[ti], g: thumbRGBA[ti + 1], b: thumbRGBA[ti + 2],
                    weight: conf
                )
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
        // Map thumb pixel to approximate full-res principal-point space
        let u = (Float(pixelX) + 0.5) / Float(width) * Float(intrinsics.width)
        let v = (Float(pixelY) + 0.5) / Float(height) * Float(intrinsics.height)
        let x = (u - intrinsics.cx) / max(intrinsics.fx, 1)
        let y = (v - intrinsics.cy) / max(intrinsics.fy, 1)
        let local = simd_normalize(simd_float3(x, -y, -1)) // ARKit camera looks -Z
        let r = simd_float3x3(columns: (
            simd_float3(cameraTransform.columns.0.x, cameraTransform.columns.0.y, cameraTransform.columns.0.z),
            simd_float3(cameraTransform.columns.1.x, cameraTransform.columns.1.y, cameraTransform.columns.1.z),
            simd_float3(cameraTransform.columns.2.x, cameraTransform.columns.2.y, cameraTransform.columns.2.z)
        ))
        return simd_normalize(r * local)
    }

    private func stamp(cx: Int, cy: Int, radius: Int, r: UInt8, g: UInt8, b: UInt8, weight: Float) {
        let r2 = radius * radius
        for dy in -radius...radius {
            for dx in -radius...radius {
                let dist2 = dx * dx + dy * dy
                guard dist2 <= r2 else { continue }
                let px = cx + dx
                let py = cy + dy
                guard px >= 0, px < size, py >= 0, py < size else { continue }
                let falloff = 1 - Float(dist2) / Float(max(r2, 1))
                let sampleW = weight * falloff * falloff
                let idx = py * size + px
                let prev = Float(confidence[idx]) / 255
                if sampleW + 0.04 < prev { continue }
                let blend = sampleW / max(sampleW + prev, 0.001)
                let o = idx * 4
                rgba[o] = mix(rgba[o], r, blend)
                rgba[o + 1] = mix(rgba[o + 1], g, blend)
                rgba[o + 2] = mix(rgba[o + 2], b, blend)
                confidence[idx] = UInt8(clamping: Int((min(1, max(prev, sampleW)) * 255).rounded()))
            }
        }
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

    func makeUIImage() -> UIImage? {
        Quick360ImageBuffer.uiImage(rgba: rgba, width: size, height: size)
    }

    func makeCGImage() -> CGImage? {
        Quick360ImageBuffer.cgImage(rgba: rgba, width: size, height: size)
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
