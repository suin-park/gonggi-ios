import Foundation
import SceneKit
import UIKit

/// Billboard dimension rulers for selected catalog furniture (product DB mm).
enum CatalogDimensionRuler {
    static let widthName = "catalogRulerWidth"
    static let heightName = "catalogRulerHeight"
    static let depthName = "catalogRulerDepth"

    static func attach(
        to root: SCNNode,
        spec: CatalogPlacementSpec,
        showDepth: Bool
    ) {
        detach(from: root)

        let ends = CatalogPlacementTransform.rulerEndpoints(spec: spec)
        let dims = spec.dimensionsMm
        let bmin = spec.canonicalBounds.min
        let bmax = spec.canonicalBounds.max
        let modelCenter = SIMD3(
            Float((bmin.x + bmax.x) * 0.5),
            Float((bmin.y + bmax.y) * 0.5),
            Float((bmin.z + bmax.z) * 0.5)
        )

        root.addChildNode(makeSegment(
            name: widthName,
            from: ends.width.0,
            to: ends.width.1,
            label: "W \(formatMm(dims.widthMm))",
            accessibilityLabel: "너비 \(dims.widthMm)밀리미터",
            modelCenter: modelCenter
        ))
        root.addChildNode(makeSegment(
            name: heightName,
            from: ends.height.0,
            to: ends.height.1,
            label: "H \(formatMm(dims.heightMm))",
            accessibilityLabel: "높이 \(dims.heightMm)밀리미터",
            modelCenter: modelCenter
        ))
        if showDepth {
            root.addChildNode(makeSegment(
                name: depthName,
                from: ends.depth.0,
                to: ends.depth.1,
                label: "D \(formatMm(dims.depthMm))",
                accessibilityLabel: "깊이 \(dims.depthMm)밀리미터",
                modelCenter: modelCenter
            ))
        }
    }

    static func detach(from root: SCNNode) {
        root.childNodes.filter {
            $0.name == widthName || $0.name == heightName || $0.name == depthName
        }.forEach { $0.removeFromParentNode() }
    }

    /// Display format: `400 mm` (Catalog mm source of truth).
    static func formatMm(_ mm: Int) -> String {
        "\(mm) mm"
    }

    @available(*, deprecated, renamed: "formatMm")
    static func formatCm(_ mm: Int) -> String {
        formatMm(mm)
    }

    /// Build a ruler-only placementSpec from stored catalog mm (identity axis / AABB).
    static func rulerSpecFromStoredEntry(_ entry: VRPlacedAssetEntry) -> CatalogPlacementSpec? {
        guard let widthMm = entry.catalogWidthMm,
              let depthMm = entry.catalogDepthMm,
              let heightMm = entry.catalogHeightMm,
              widthMm > 0, depthMm > 0, heightMm > 0
        else { return nil }

        let w = Double(CatalogPlacementTransform.metersFromMm(widthMm))
        let d = Double(CatalogPlacementTransform.metersFromMm(depthMm))
        let h = Double(CatalogPlacementTransform.metersFromMm(heightMm))
        return CatalogPlacementSpec(
            contractVersion: entry.placementSpecVersion ?? CatalogPlacementSpec.supportedContractVersion,
            coordinateConvention: CatalogPlacementSpec.supportedCoordinateConvention,
            placementType: .furniture3D,
            axisMapping: CatalogAxisMapping(width: "x", height: "y", depth: "z"),
            orientation: CatalogQuaternion(x: 0, y: 0, z: 0, w: 1),
            scaleX: 1,
            scaleY: 1,
            scaleZ: 1,
            bottomOffsetMeters: 0,
            canonicalBounds: CatalogCanonicalBounds(
                min: CatalogVec3(x: 0, y: 0, z: 0),
                max: CatalogVec3(x: w, y: h, z: d)
            ),
            dimensionsMm: CatalogDimensions(widthMm: widthMm, depthMm: depthMm, heightMm: heightMm),
            catalogAssetId: entry.catalogAssetId ?? "",
            catalogOwnedAssetId: entry.catalogOwnedAssetId ?? "",
            catalogRevision: entry.catalogRevision ?? 1,
            productRevision: entry.catalogProductId ?? "",
            variantRevision: entry.catalogVariantId,
            usdzSignedUrl: "https://example.invalid/ruler-only",
            usdzSignedUrlExpiresAt: nil
        )
    }

    private static func makeSegment(
        name: String,
        from: SIMD3<Float>,
        to: SIMD3<Float>,
        label: String,
        accessibilityLabel: String,
        modelCenter: SIMD3<Float>
    ) -> SCNNode {
        let container = SCNNode()
        container.name = name
        container.isAccessibilityElement = true
        container.accessibilityLabel = accessibilityLabel
        // Draw above furniture mesh so W/H/D labels are not clipped by the USDZ.
        container.renderingOrder = 80

        let mid = (from + to) * 0.5
        let delta = to - from
        let length = max(simd_length(delta), 0.01)
        let dir = simd_normalize(delta)

        let line = SCNCylinder(radius: 0.0035, height: CGFloat(length))
        applyOverlayMaterial(line.firstMaterial)
        line.firstMaterial?.diffuse.contents = UIColor(red: 0.25, green: 0.81, blue: 0.89, alpha: 0.95)
        let lineNode = SCNNode(geometry: line)
        lineNode.position = SCNVector3(mid.x, mid.y, mid.z)
        let yAxis = SIMD3<Float>(0, 1, 0)
        lineNode.simdOrientation = simd_quatf(from: yAxis, to: dir)
        lineNode.renderingOrder = 80
        container.addChildNode(lineNode)

        // Short end ticks perpendicular to the segment in a readable world-up bias.
        let tickLen: Float = 0.025
        let tickAxis: SIMD3<Float>
        if abs(simd_dot(dir, SIMD3(0, 1, 0))) > 0.85 {
            tickAxis = SIMD3(1, 0, 0)
        } else {
            tickAxis = simd_normalize(simd_cross(dir, SIMD3(0, 1, 0)))
        }
        for end in [from, to] {
            let tick = SCNCylinder(radius: 0.003, height: CGFloat(tickLen))
            applyOverlayMaterial(tick.firstMaterial)
            tick.firstMaterial?.diffuse.contents = UIColor(red: 0.25, green: 0.81, blue: 0.89, alpha: 0.95)
            let tickNode = SCNNode(geometry: tick)
            tickNode.position = SCNVector3(end.x, end.y, end.z)
            tickNode.simdOrientation = simd_quatf(from: yAxis, to: tickAxis)
            tickNode.renderingOrder = 80
            container.addChildNode(tickNode)
        }

        let text = SCNText(string: label, extrusionDepth: 0.15)
        text.font = UIFont.systemFont(ofSize: 14, weight: .semibold)
        text.flatness = 0.15
        applyOverlayMaterial(text.firstMaterial)
        text.firstMaterial?.diffuse.contents = UIColor.white
        let textNode = SCNNode(geometry: text)
        let scale: Float = 0.0038
        textNode.scale = SCNVector3(scale, scale, scale)
        let (minB, maxB) = textNode.boundingBox
        let textMid = SCNVector3(
            (minB.x + maxB.x) * 0.5 * scale,
            (minB.y + maxB.y) * 0.5 * scale,
            0
        )
        // Push label outward from the furniture AABB so billboards clear the mesh.
        var outward = SIMD3(mid.x - modelCenter.x, mid.y - modelCenter.y, mid.z - modelCenter.z)
        if simd_length(outward) < 1e-4 {
            outward = SIMD3(0.08, 0.04, 0)
        } else {
            outward = simd_normalize(outward) * 0.08
        }
        textNode.position = SCNVector3(
            mid.x - textMid.x + outward.x,
            mid.y - textMid.y + outward.y + 0.02,
            mid.z + outward.z
        )
        textNode.constraints = [SCNBillboardConstraint()]
        textNode.renderingOrder = 90
        container.addChildNode(textNode)
        return container
    }

    private static func applyOverlayMaterial(_ material: SCNMaterial?) {
        guard let material else { return }
        material.lightingModel = .constant
        material.isDoubleSided = true
        material.writesToDepthBuffer = false
        material.readsFromDepthBuffer = false
    }
}
