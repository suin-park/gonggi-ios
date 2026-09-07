import Foundation
import simd

/// Local-space visual bounds of the mesh only (excludes hit proxy / selection).
struct AssetVisualBounds: Equatable, Sendable {
    var min: SIMD3<Float>
    var max: SIMD3<Float>

    var center: SIMD3<Float> {
        (min + max) * 0.5
    }

    var size: SIMD3<Float> {
        max - min
    }

    static let fallback = AssetVisualBounds(
        min: SIMD3(-0.3, 0, -0.3),
        max: SIMD3(0.3, 0.6, 0.3)
    )
}

#if DEBUG
enum VRSelectionPerfCounters {
    static var selectionGeometryCreates = 0
    static var proxyGeometryCreates = 0
    static var boundsRecalculations = 0

    static func reset() {
        selectionGeometryCreates = 0
        proxyGeometryCreates = 0
        boundsRecalculations = 0
    }
}
#endif
