import Foundation
import SceneKit
import UIKit

/// Lightweight camera-facing billboard for 공간 연결 (Build 73 visual states).
enum SpaceHotspotNodeFactory {
    static let rootNamePrefix = "spaceHotspot:"
    static let visualName = "spaceHotspotVisual"
    static let hitProxyName = "spaceHotspotHitProxy"
    static let selectionName = "spaceHotspotSelection"

    /// Visible disc (~28pt); hit proxy separately sized (~52pt).
    static let visualTargetPoints: Float = 28
    static let hitTargetPoints: Float = 52

    static let blueFill = UIColor(red: 0.20, green: 0.48, blue: 1.0, alpha: 0.92)
    static let blueStroke = UIColor(red: 0.75, green: 0.88, blue: 1.0, alpha: 1)
    static let yellowFill = UIColor(red: 1.0, green: 0.84, blue: 0.12, alpha: 0.95)
    static let yellowStroke = UIColor(red: 1.0, green: 0.95, blue: 0.55, alpha: 1)

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

        let visualDiameter: Float = 0.22
        let plane = SCNPlane(width: CGFloat(visualDiameter), height: CGFloat(visualDiameter))
        let mat = SCNMaterial()
        mat.lightingModel = .constant
        mat.isDoubleSided = true
        mat.writesToDepthBuffer = false
        mat.diffuse.contents = makeDiscImage(
            fill: selected ? yellowFill : blueFill,
            stroke: selected ? yellowStroke : blueStroke
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

        // Invisible hit target — larger than visual (Build 67 proxy pattern).
        let hitRadius = CGFloat(visualDiameter * 1.15)
        let proxy = SCNNode(geometry: SCNSphere(radius: hitRadius))
        proxy.name = hitProxyName
        let proxyMat = SCNMaterial()
        proxyMat.diffuse.contents = UIColor.clear
        proxyMat.transparency = 0.02
        proxyMat.writesToDepthBuffer = false
        proxyMat.lightingModel = .constant
        proxy.geometry?.firstMaterial = proxyMat
        proxy.categoryBitMask = VRPlacedAssetCategory.spaceLink
        proxy.renderingOrder = 21
        root.addChildNode(proxy)

        if selected {
            let ringPlane = SCNPlane(
                width: CGFloat(visualDiameter * 1.55),
                height: CGFloat(visualDiameter * 1.55)
            )
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

        if pulse, !selected, link.status == .linked {
            let scaleUp = SCNAction.scale(to: 1.06, duration: 1.2)
            scaleUp.timingMode = .easeInEaseOut
            let scaleDown = SCNAction.scale(to: 1.0, duration: 1.2)
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
        let visualD = SpaceLinkMath.billboardDiameterMeters(
            distance: distance,
            viewportHeight: viewportHeight,
            verticalFOVDegrees: verticalFOVDegrees,
            targetPoints: visualTargetPoints
        )
        let hitD = SpaceLinkMath.billboardDiameterMeters(
            distance: distance,
            viewportHeight: viewportHeight,
            verticalFOVDegrees: verticalFOVDegrees,
            targetPoints: hitTargetPoints
        )
        if let visual = root.childNode(withName: visualName, recursively: false),
           let plane = visual.geometry as? SCNPlane {
            plane.width = CGFloat(visualD)
            plane.height = CGFloat(visualD)
        }
        if let proxy = root.childNode(withName: hitProxyName, recursively: false),
           let sphere = proxy.geometry as? SCNSphere {
            sphere.radius = CGFloat(hitD * 0.5)
        }
        if let ring = root.childNode(withName: selectionName, recursively: false),
           let plane = ring.geometry as? SCNPlane {
            plane.width = CGFloat(visualD * 1.55)
            plane.height = CGFloat(visualD * 1.55)
        }
    }

    // MARK: - Images

    private static func makeDiscImage(fill: UIColor, stroke: UIColor) -> UIImage {
        let size = CGSize(width: 128, height: 128)
        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.image { ctx in
            let rect = CGRect(x: 14, y: 14, width: 100, height: 100)
            fill.setFill()
            ctx.cgContext.fillEllipse(in: rect)
            stroke.setStroke()
            ctx.cgContext.setLineWidth(8)
            ctx.cgContext.strokeEllipse(in: rect.insetBy(dx: 2, dy: 2))
        }
    }

    private static func makeRingImage() -> UIImage {
        let size = CGSize(width: 128, height: 128)
        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.image { ctx in
            let rect = CGRect(x: 8, y: 8, width: 112, height: 112)
            yellowStroke.setStroke()
            ctx.cgContext.setLineWidth(7)
            ctx.cgContext.strokeEllipse(in: rect)
        }
    }
}
