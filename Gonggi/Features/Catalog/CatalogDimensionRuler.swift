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
        root.childNodes.filter {
            $0.name == widthName || $0.name == heightName || $0.name == depthName
        }.forEach { $0.removeFromParentNode() }

        let ends = CatalogPlacementTransform.rulerEndpoints(spec: spec)
        let dims = spec.dimensionsMm

        root.addChildNode(makeSegment(
            name: widthName,
            from: ends.width.0,
            to: ends.width.1,
            label: "W \(formatCm(dims.widthMm))"
        ))
        root.addChildNode(makeSegment(
            name: heightName,
            from: ends.height.0,
            to: ends.height.1,
            label: "H \(formatCm(dims.heightMm))"
        ))
        if showDepth {
            root.addChildNode(makeSegment(
                name: depthName,
                from: ends.depth.0,
                to: ends.depth.1,
                label: "D \(formatCm(dims.depthMm))"
            ))
        }
    }

    static func formatCm(_ mm: Int) -> String {
        let cm = Double(mm) / 10.0
        if abs(cm - cm.rounded()) < 0.05 {
            return String(format: "%.0fcm", cm)
        }
        return String(format: "%.1fcm", cm)
    }

    private static func makeSegment(
        name: String,
        from: SIMD3<Float>,
        to: SIMD3<Float>,
        label: String
    ) -> SCNNode {
        let container = SCNNode()
        container.name = name

        let mid = (from + to) * 0.5
        let delta = to - from
        let length = max(simd_length(delta), 0.01)

        let line = SCNCylinder(radius: 0.004, height: CGFloat(length))
        line.firstMaterial?.diffuse.contents = UIColor(red: 0.25, green: 0.81, blue: 0.89, alpha: 0.95)
        line.firstMaterial?.lightingModel = .constant
        let lineNode = SCNNode(geometry: line)
        lineNode.position = SCNVector3(mid.x, mid.y, mid.z)
        // Align cylinder (default +Y) to segment direction.
        let yAxis = SIMD3<Float>(0, 1, 0)
        let dir = simd_normalize(delta)
        lineNode.simdOrientation = simd_quatf(from: yAxis, to: dir)
        container.addChildNode(lineNode)

        let text = SCNText(string: label, extrusionDepth: 0.2)
        text.font = UIFont.systemFont(ofSize: 12, weight: .semibold)
        text.flatness = 0.2
        text.firstMaterial?.diffuse.contents = UIColor.white
        text.firstMaterial?.lightingModel = .constant
        let textNode = SCNNode(geometry: text)
        // Screen-ish constant size: clamp scale so zoom doesn't explode text.
        let scale: Float = 0.004
        textNode.scale = SCNVector3(scale, scale, scale)
        let (minB, maxB) = textNode.boundingBox
        let textMid = SCNVector3(
            (minB.x + maxB.x) * 0.5 * scale,
            (minB.y + maxB.y) * 0.5 * scale,
            0
        )
        textNode.position = SCNVector3(mid.x - textMid.x, mid.y - textMid.y + 0.03, mid.z)
        textNode.constraints = [SCNBillboardConstraint()]
        container.addChildNode(textNode)
        return container
    }
}
