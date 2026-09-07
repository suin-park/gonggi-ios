import Foundation
import SceneKit
import UIKit

/// Lightweight camera-facing billboard for 공간 연결 (Build 72).
enum SpaceHotspotNodeFactory {
    static let rootNamePrefix = "spaceHotspot:"
    static let visualName = "spaceHotspotVisual"
    static let hitProxyName = "spaceHotspotHitProxy"
    static let selectionName = "spaceHotspotSelection"

    static func makeNode(link: SpaceLink, selected: Bool, pulse: Bool) -> SCNNode {
        let root = SCNNode()
        root.name = rootNamePrefix + link.id
        root.categoryBitMask = VRPlacedAssetCategory.spaceLink

        let pos = SpaceLinkMath.worldPosition(
            yawDeg: link.yawDeg,
            pitchDeg: link.pitchDeg,
            radius: link.radius
        )
        root.position = SCNVector3(pos.x, pos.y, pos.z)

        let diameter: Float = 0.28
        let plane = SCNPlane(width: CGFloat(diameter), height: CGFloat(diameter))
        let mat = SCNMaterial()
        mat.lightingModel = .constant
        mat.isDoubleSided = true
        mat.writesToDepthBuffer = false
        mat.diffuse.contents = makeDiscImage(
            fill: UIColor(white: 1, alpha: link.status == .linked ? 0.55 : 0.4),
            stroke: UIColor(white: 1, alpha: 0.85)
        )
        mat.transparencyMode = .singleLayer
        mat.blendMode = .alpha
        plane.firstMaterial = mat

        let visual = SCNNode(geometry: plane)
        visual.name = visualName
        visual.categoryBitMask = VRPlacedAssetCategory.spaceLink
        visual.renderingOrder = 20
        root.addChildNode(visual)

        let billboard = SCNBillboardConstraint()
        billboard.freeAxes = .all
        root.constraints = [billboard]

        let proxy = SCNNode(geometry: SCNSphere(radius: CGFloat(diameter * 0.55)))
        proxy.name = hitProxyName
        proxy.geometry?.firstMaterial?.diffuse.contents = UIColor.clear
        proxy.geometry?.firstMaterial?.transparency = 0.01
        proxy.geometry?.firstMaterial?.writesToDepthBuffer = false
        proxy.categoryBitMask = VRPlacedAssetCategory.spaceLink
        proxy.renderingOrder = 21
        root.addChildNode(proxy)

        if selected {
            let ringPlane = SCNPlane(width: CGFloat(diameter * 1.35), height: CGFloat(diameter * 1.35))
            let ringMat = SCNMaterial()
            ringMat.lightingModel = .constant
            ringMat.isDoubleSided = true
            ringMat.writesToDepthBuffer = false
            ringMat.diffuse.contents = makeRingImage()
            ringMat.transparencyMode = .singleLayer
            ringMat.blendMode = .alpha
            ringPlane.firstMaterial = ringMat
            let ring = SCNNode(geometry: ringPlane)
            ring.name = selectionName
            ring.categoryBitMask = VRPlacedAssetCategory.selection
            ring.renderingOrder = 22
            root.addChildNode(ring)
        }

        if pulse, link.status == .linked {
            let scaleUp = SCNAction.scale(to: 1.08, duration: 1.1)
            scaleUp.timingMode = .easeInEaseOut
            let scaleDown = SCNAction.scale(to: 1.0, duration: 1.1)
            scaleDown.timingMode = .easeInEaseOut
            visual.runAction(.repeatForever(.sequence([scaleUp, scaleDown])))
        }

        return root
    }

    static func linkID(from node: SCNNode) -> String? {
        var current: SCNNode? = node
        while let n = current {
            if let name = n.name, name.hasPrefix(rootNamePrefix) {
                return String(name.dropFirst(rootNamePrefix.count))
            }
            current = n.parent
        }
        return nil
    }

    static func applyPose(on root: SCNNode, yawDeg: Float, pitchDeg: Float, radius: Float) {
        let pos = SpaceLinkMath.worldPosition(yawDeg: yawDeg, pitchDeg: pitchDeg, radius: radius)
        root.position = SCNVector3(pos.x, pos.y, pos.z)
    }

    static func refreshHitSize(
        on root: SCNNode,
        distance: Float,
        viewportHeight: Float,
        verticalFOVDegrees: Float
    ) {
        let diameter = SpaceLinkMath.billboardDiameterMeters(
            distance: distance,
            viewportHeight: viewportHeight,
            verticalFOVDegrees: verticalFOVDegrees
        )
        if let visual = root.childNode(withName: visualName, recursively: false),
           let plane = visual.geometry as? SCNPlane {
            plane.width = CGFloat(diameter)
            plane.height = CGFloat(diameter)
        }
        if let proxy = root.childNode(withName: hitProxyName, recursively: false),
           let sphere = proxy.geometry as? SCNSphere {
            sphere.radius = CGFloat(diameter * 0.55)
        }
        if let ring = root.childNode(withName: selectionName, recursively: false),
           let plane = ring.geometry as? SCNPlane {
            plane.width = CGFloat(diameter * 1.35)
            plane.height = CGFloat(diameter * 1.35)
        }
    }

    // MARK: - Images

    private static func makeDiscImage(fill: UIColor, stroke: UIColor) -> UIImage {
        let size = CGSize(width: 128, height: 128)
        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.image { ctx in
            let rect = CGRect(x: 8, y: 8, width: 112, height: 112)
            fill.setFill()
            ctx.cgContext.fillEllipse(in: rect)
            stroke.setStroke()
            ctx.cgContext.setLineWidth(6)
            ctx.cgContext.strokeEllipse(in: rect.insetBy(dx: 3, dy: 3))
        }
    }

    private static func makeRingImage() -> UIImage {
        let size = CGSize(width: 128, height: 128)
        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.image { ctx in
            let rect = CGRect(x: 10, y: 10, width: 108, height: 108)
            UIColor.systemYellow.withAlphaComponent(0.9).setStroke()
            ctx.cgContext.setLineWidth(5)
            ctx.cgContext.strokeEllipse(in: rect)
        }
    }
}
