import Foundation
import simd

/// Future product-placement surface (snap / scale / contact shadow). No commerce UI in V4.
struct CapturedFloorSurface: Equatable {
    var worldTransform: simd_float4x4
    var originRelativeTransform: simd_float4x4
    var center: simd_float3
    var extent: simd_float3 // x, unused/y thickness hint, z
    var averageNormal: simd_float3
    var yHeight: Float
    var trackingConfidence: Float
    var textureWidth: Int
    var textureHeight: Int
    var coveragePercent: Float
    var goodCoveragePercent: Float
    var textureUpdateCount: Int
    /// Debug / future: shadow receiver ready flag (always true once locked).
    var isShadowReceiverReady: Bool

    static func make(
        worldTransform: simd_float4x4,
        originTransform: simd_float4x4,
        extent: simd_float3,
        trackingConfidence: Float,
        textureSize: Int
    ) -> CapturedFloorSurface {
        let center = simd_float3(
            worldTransform.columns.3.x,
            worldTransform.columns.3.y,
            worldTransform.columns.3.z
        )
        let normal = simd_normalize(simd_float3(
            worldTransform.columns.1.x,
            worldTransform.columns.1.y,
            worldTransform.columns.1.z
        ))
        let relative = simd_inverse(originTransform) * worldTransform
        return CapturedFloorSurface(
            worldTransform: worldTransform,
            originRelativeTransform: relative,
            center: center,
            extent: extent,
            averageNormal: normal,
            yHeight: center.y,
            trackingConfidence: trackingConfidence,
            textureWidth: textureSize,
            textureHeight: textureSize,
            coveragePercent: 0,
            goodCoveragePercent: 0,
            textureUpdateCount: 0,
            isShadowReceiverReady: true
        )
    }
}

/// Codable snapshot written to `floor/floor-metadata.json`.
struct CapturedFloorSurfaceMetadata: Codable, Equatable {
    let worldTransform: [Float]
    let originRelativeTransform: [Float]
    let center: [Float]
    let extent: [Float]
    let averageNormal: [Float]
    let yHeight: Float
    let trackingConfidence: Float
    let textureWidth: Int
    let textureHeight: Int
    let coveragePercent: Float
    let goodCoveragePercent: Float
    let textureUpdateCount: Int
    let isShadowReceiverReady: Bool
    let textureFileName: String
    let confidenceMaskFileName: String

    init(surface: CapturedFloorSurface) {
        worldTransform = CaptureKeyframeRecord.encodeTransform(surface.worldTransform)
        originRelativeTransform = CaptureKeyframeRecord.encodeTransform(surface.originRelativeTransform)
        center = [surface.center.x, surface.center.y, surface.center.z]
        extent = [surface.extent.x, surface.extent.y, surface.extent.z]
        averageNormal = [surface.averageNormal.x, surface.averageNormal.y, surface.averageNormal.z]
        yHeight = surface.yHeight
        trackingConfidence = surface.trackingConfidence
        textureWidth = surface.textureWidth
        textureHeight = surface.textureHeight
        coveragePercent = surface.coveragePercent
        goodCoveragePercent = surface.goodCoveragePercent
        textureUpdateCount = surface.textureUpdateCount
        isShadowReceiverReady = surface.isShadowReceiverReady
        textureFileName = "floor-texture.jpg"
        confidenceMaskFileName = "floor-confidence-mask.png"
    }
}

/// Pure floor ray / UV math (unit-testable without ARKit).
enum Quick360FloorMath {
    /// Ray-plane intersection. Returns distance `t` if hit in front of ray.
    static func rayPlaneIntersection(
        rayOrigin: simd_float3,
        rayDirection: simd_float3,
        planePoint: simd_float3,
        planeNormal: simd_float3
    ) -> Float? {
        let denom = simd_dot(planeNormal, rayDirection)
        guard abs(denom) > 1e-5 else { return nil }
        let t = simd_dot(planePoint - rayOrigin, planeNormal) / denom
        guard t > 0.05 else { return nil }
        return t
    }

    /// Cosine of angle between incoming view ray and plane normal (1 = looking straight at floor).
    static func incidenceCosine(rayDirection: simd_float3, planeNormal: simd_float3) -> Float {
        abs(simd_dot(simd_normalize(rayDirection), simd_normalize(planeNormal)))
    }

    static func isGrazingAngle(rayDirection: simd_float3, planeNormal: simd_float3, minCos: Float) -> Bool {
        incidenceCosine(rayDirection: rayDirection, planeNormal: planeNormal) < minCos
    }

    /// Map world point to floor-local UV in [0,1], centered on plane, using XZ extent.
    static func worldToFloorUV(
        worldPoint: simd_float3,
        floorCenter: simd_float3,
        extentX: Float,
        extentZ: Float,
        worldTransform: simd_float4x4
    ) -> SIMD2<Float>? {
        let inv = simd_inverse(worldTransform)
        let local = inv * SIMD4<Float>(worldPoint.x, worldPoint.y, worldPoint.z, 1)
        let halfX = max(extentX * 0.5, 0.01)
        let halfZ = max(extentZ * 0.5, 0.01)
        let u = local.x / halfX * 0.5 + 0.5
        let v = local.z / halfZ * 0.5 + 0.5
        guard u >= 0, u <= 1, v >= 0, v <= 1 else { return nil }
        return SIMD2(u, v)
    }

    static func clampExtent(_ extent: simd_float3, maxRadius: Float) -> simd_float3 {
        let maxSpan = maxRadius * 2
        return simd_float3(
            min(max(extent.x, Quick360Config.floorMinExtentM), maxSpan),
            extent.y,
            min(max(extent.z, Quick360Config.floorMinExtentM), maxSpan)
        )
    }
}
