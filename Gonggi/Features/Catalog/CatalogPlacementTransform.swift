import Foundation
import simd

/// Applies Catalog placementSpec transforms for SceneKit (column-vector, right-multiply).
/// Conceptual order: axis mapping → orientation → placement scale → bottom offset
/// → user rotation (Y) → user position.
enum CatalogPlacementTransform {
    /// SceneKit / simd: M = T * R_user * T_bottom * S * R_orient * A
    static func modelMatrix(
        spec: CatalogPlacementSpec,
        userPosition: SIMD3<Float>,
        userRotationY: Float
    ) -> simd_float4x4 {
        let axis = axisMappingMatrix(spec.axisMapping)
        let orient = quaternionMatrix(spec.orientation)
        let scale = simd_float4x4(diagonal: SIMD4(
            Float(spec.scaleX),
            Float(spec.scaleY),
            Float(spec.scaleZ),
            1
        ))
        let bottom = translationMatrix(SIMD3(0, Float(spec.bottomOffsetMeters), 0))
        let userR = rotationYMatrix(userRotationY)
        let userT = translationMatrix(userPosition)
        return userT * userR * bottom * scale * orient * axis
    }

    /// Scale factors that map canonical bounds size to product mm (should be ~1 when approved).
    /// Must NOT be combined again with placementSpec.scale* when displaying rulers.
    static func metersFromMm(_ mm: Int) -> Float {
        Float(mm) / 1000
    }

    static func rulerEndpoints(spec: CatalogPlacementSpec) -> (
        width: (SIMD3<Float>, SIMD3<Float>),
        depth: (SIMD3<Float>, SIMD3<Float>),
        height: (SIMD3<Float>, SIMD3<Float>)
    ) {
        let min = SIMD3(
            Float(spec.canonicalBounds.min.x),
            Float(spec.canonicalBounds.min.y),
            Float(spec.canonicalBounds.min.z)
        )
        let max = SIMD3(
            Float(spec.canonicalBounds.max.x),
            Float(spec.canonicalBounds.max.y),
            Float(spec.canonicalBounds.max.z)
        )
        let frontZ = min.z
        let rightX = max.x
        let width = (SIMD3(min.x, min.y, frontZ), SIMD3(max.x, min.y, frontZ))
        let depth = (SIMD3(min.x, min.y, min.z), SIMD3(min.x, min.y, max.z))
        let height = (SIMD3(rightX, min.y, frontZ), SIMD3(rightX, max.y, frontZ))
        return (width, depth, height)
    }

    static func axisMappingMatrix(_ mapping: CatalogAxisMapping) -> simd_float4x4 {
        // Columns are images of unit X/Y/Z after remapping product W/H/D axes into SceneKit.
        func unit(_ axis: String) -> SIMD3<Float> {
            switch axis.lowercased() {
            case "x": return SIMD3(1, 0, 0)
            case "y": return SIMD3(0, 1, 0)
            case "z": return SIMD3(0, 0, 1)
            default: return SIMD3(0, 0, 0)
            }
        }
        // Identity WHD→XYZ when width=x,height=y,depth=z:
        // product local X (width) → scene X, Y→Y, Z→Z
        let col0 = unit(mapping.width)  // where +X (width) goes
        let col1 = unit(mapping.height)
        let col2 = unit(mapping.depth)
        return simd_float4x4(
            SIMD4(col0.x, col0.y, col0.z, 0),
            SIMD4(col1.x, col1.y, col1.z, 0),
            SIMD4(col2.x, col2.y, col2.z, 0),
            SIMD4(0, 0, 0, 1)
        )
    }

    static func quaternionMatrix(_ q: CatalogQuaternion) -> simd_float4x4 {
        let quat = simd_quatf(
            ix: Float(q.x),
            iy: Float(q.y),
            iz: Float(q.z),
            r: Float(q.w)
        )
        return simd_float4x4(quat)
    }

    static func translationMatrix(_ t: SIMD3<Float>) -> simd_float4x4 {
        var m = matrix_identity_float4x4
        m.columns.3 = SIMD4(t.x, t.y, t.z, 1)
        return m
    }

    static func rotationYMatrix(_ radians: Float) -> simd_float4x4 {
        let c = cos(radians)
        let s = sin(radians)
        return simd_float4x4(
            SIMD4(c, 0, -s, 0),
            SIMD4(0, 1, 0, 0),
            SIMD4(s, 0, c, 0),
            SIMD4(0, 0, 0, 1)
        )
    }

    /// Floor alignment after placement scale (design §11.4): y = floorY - minY * sY
    static func floorAlignedY(floorY: Float, localMinY: Float, scaleY: Float) -> Float {
        floorY - localMinY * scaleY
    }
}
