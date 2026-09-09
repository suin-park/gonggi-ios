import Foundation
import SceneKit
import UIKit

/// Lightweight camera-facing billboard for 공간 연결 (Build 73/75 visual states + metadata caption).
enum SpaceHotspotNodeFactory {
    static let rootNamePrefix = "spaceHotspot:"
    static let visualName = "spaceHotspotVisual"
    static let hitProxyName = "spaceHotspotHitProxy"
    static let selectionName = "spaceHotspotSelection"
    static let captionName = "spaceHotspotCaption"

    /// Visible disc (~36pt); hit proxy separately sized (~52pt).
    static let visualTargetPoints: Float = 36
    static let hitTargetPoints: Float = 52
    static let captionTargetPoints: Float = 52

    static let blueFill = UIColor(red: 0.20, green: 0.48, blue: 1.0, alpha: 1.0)
    static let blueStroke = UIColor(red: 0.85, green: 0.92, blue: 1.0, alpha: 1)
    static let yellowFill = UIColor(red: 1.0, green: 0.84, blue: 0.12, alpha: 1.0)
    static let yellowStroke = UIColor(red: 1.0, green: 0.95, blue: 0.55, alpha: 1)

    #if DEBUG
    /// Build 75: oversized magenta marker to separate transform vs material issues.
    static var debugForceVisibleMarker = false
    #endif

    static func makeNode(
        link: SpaceLink,
        selected: Bool,
        pulse: Bool,
        targetSpaceName: String? = nil
    ) -> SCNNode {
        let root = SCNNode()
        root.name = rootNamePrefix + link.id
        root.categoryBitMask = VRPlacedAssetCategory.spaceLink
        root.isHidden = false
        root.opacity = 1

        let pos = SpaceLinkMath.worldPosition(
            yawDeg: link.yawDeg,
            pitchDeg: link.pitchDeg,
            radius: link.radius
        )
        root.position = SCNVector3(pos.x, pos.y, pos.z)

        #if DEBUG
        let forceDebug = debugForceVisibleMarker
        #else
        let forceDebug = false
        #endif

        let visualDiameter: Float = forceDebug ? 0.55 : 0.32
        let plane = SCNPlane(width: CGFloat(visualDiameter), height: CGFloat(visualDiameter))
        let mat = makeUnlitMaterial(
            image: forceDebug
                ? makeDiscImage(fill: .magenta, stroke: .white)
                : makeDiscImage(
                    fill: selected ? yellowFill : blueFill,
                    stroke: selected ? yellowStroke : blueStroke
                )
        )
        plane.firstMaterial = mat

        let visual = SCNNode(geometry: plane)
        visual.name = visualName
        visual.categoryBitMask = VRPlacedAssetCategory.spaceLink
        visual.renderingOrder = forceDebug ? 200 : 100
        visual.opacity = 1
        visual.isHidden = false
        root.addChildNode(visual)

        let billboard = SCNBillboardConstraint()
        billboard.freeAxes = .all
        root.constraints = [billboard]

        let hitRadius = CGFloat(visualDiameter * 1.2)
        let proxy = SCNNode(geometry: SCNSphere(radius: hitRadius))
        proxy.name = hitProxyName
        let proxyMat = SCNMaterial()
        proxyMat.diffuse.contents = UIColor.clear
        proxyMat.transparency = 0.02
        proxyMat.writesToDepthBuffer = false
        proxyMat.readsFromDepthBuffer = false
        proxyMat.lightingModel = .constant
        proxy.geometry?.firstMaterial = proxyMat
        proxy.categoryBitMask = VRPlacedAssetCategory.spaceLink
        proxy.renderingOrder = forceDebug ? 201 : 101
        root.addChildNode(proxy)

        if selected || forceDebug {
            let ringPlane = SCNPlane(
                width: CGFloat(visualDiameter * 1.55),
                height: CGFloat(visualDiameter * 1.55)
            )
            let ringMat = makeUnlitMaterial(
                image: forceDebug ? makeRingImage(color: .white) : makeRingImage(color: yellowStroke)
            )
            ringPlane.firstMaterial = ringMat
            let ring = SCNNode(geometry: ringPlane)
            ring.name = selectionName
            ring.categoryBitMask = VRPlacedAssetCategory.selection
            ring.renderingOrder = forceDebug ? 202 : 102
            root.addChildNode(ring)
        }

        if let caption = SpaceLinkExternalURL.hotspotCaption(
            displayName: link.label,
            externalUrl: link.externalUrl,
            targetSpaceName: targetSpaceName
        ), !forceDebug {
            attachCaption(caption, to: root, above: visualDiameter)
        }

        if pulse, !selected, !forceDebug, link.status == .linked {
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

    /// Update blue/yellow + ring without recreating the root (Build 74 drag selection).
    static func applySelected(_ selected: Bool, on root: SCNNode) {
        #if DEBUG
        if debugForceVisibleMarker { return }
        #endif
        if let visual = root.childNode(withName: visualName, recursively: false) {
            visual.geometry?.firstMaterial?.diffuse.contents = makeDiscImage(
                fill: selected ? yellowFill : blueFill,
                stroke: selected ? yellowStroke : blueStroke
            )
            visual.geometry?.firstMaterial?.emission.contents = selected ? yellowFill : blueFill
            visual.removeAllActions()
            visual.scale = SCNVector3(1, 1, 1)
        }
        root.childNode(withName: selectionName, recursively: false)?.removeFromParentNode()
        if selected {
            let visualD: Float = {
                if let visual = root.childNode(withName: visualName, recursively: false),
                   let plane = visual.geometry as? SCNPlane {
                    return Float(plane.width)
                }
                return 0.32
            }()
            let ringPlane = SCNPlane(
                width: CGFloat(visualD * 1.55),
                height: CGFloat(visualD * 1.55)
            )
            ringPlane.firstMaterial = makeUnlitMaterial(image: makeRingImage(color: yellowStroke))
            let ring = SCNNode(geometry: ringPlane)
            ring.name = selectionName
            ring.categoryBitMask = VRPlacedAssetCategory.selection
            ring.renderingOrder = 102
            root.addChildNode(ring)
        }
    }

    static func refreshHitSize(
        on root: SCNNode,
        distance: Float,
        viewportHeight: Float,
        verticalFOVDegrees: Float
    ) {
        #if DEBUG
        if debugForceVisibleMarker { return }
        #endif
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
        let captionH = SpaceLinkMath.billboardDiameterMeters(
            distance: distance,
            viewportHeight: viewportHeight,
            verticalFOVDegrees: verticalFOVDegrees,
            targetPoints: captionTargetPoints
        )
        // Clamp caption scale so distant labels stay readable and near ones don't dominate.
        let clampedCaptionH = min(max(captionH * 0.85, 0.12), 0.42)
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
        if let caption = root.childNode(withName: captionName, recursively: false),
           let plane = caption.geometry as? SCNPlane {
            let aspect = Float(plane.width / max(plane.height, 0.001))
            plane.height = CGFloat(clampedCaptionH)
            plane.width = CGFloat(clampedCaptionH * aspect)
            caption.position = SCNVector3(0, visualD * 0.72 + clampedCaptionH * 0.55, 0)
        }
    }

    // MARK: - Materials / Images

    private static func attachCaption(_ text: String, to root: SCNNode, above visualDiameter: Float) {
        let image = makeCaptionImage(text: text)
        let aspect = image.size.width / max(image.size.height, 1)
        let height: Float = 0.22
        let width = height * Float(aspect)
        let plane = SCNPlane(width: CGFloat(width), height: CGFloat(height))
        plane.firstMaterial = makeUnlitMaterial(image: image)
        let node = SCNNode(geometry: plane)
        node.name = captionName
        node.categoryBitMask = VRPlacedAssetCategory.spaceLink
        node.renderingOrder = 103
        node.position = SCNVector3(0, visualDiameter * 0.72 + height * 0.55, 0)
        root.addChildNode(node)
    }

    private static func makeUnlitMaterial(image: UIImage) -> SCNMaterial {
        let mat = SCNMaterial()
        mat.lightingModel = .constant
        mat.isDoubleSided = true
        mat.writesToDepthBuffer = false
        mat.readsFromDepthBuffer = false
        mat.diffuse.contents = image
        mat.emission.contents = image
        mat.transparencyMode = .aOne
        mat.blendMode = .alpha
        return mat
    }

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

    private static func makeRingImage(color: UIColor = yellowStroke) -> UIImage {
        let size = CGSize(width: 128, height: 128)
        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.image { ctx in
            let rect = CGRect(x: 8, y: 8, width: 112, height: 112)
            color.setStroke()
            ctx.cgContext.setLineWidth(7)
            ctx.cgContext.strokeEllipse(in: rect)
        }
    }

    /// Compact navy / translucent caption with Gonggi cyan accent — max 2 lines, truncated.
    private static func makeCaptionImage(text: String) -> UIImage {
        let maxWidth: CGFloat = 280
        let font = UIFont.systemFont(ofSize: 22, weight: .semibold)
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.lineBreakMode = .byTruncatingTail
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: UIColor.white,
            .paragraphStyle: paragraph,
        ]
        let ns = text as NSString
        let bound = ns.boundingRect(
            with: CGSize(width: maxWidth - 28, height: 72),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: attrs,
            context: nil
        )
        let textSize = CGSize(
            width: min(maxWidth - 28, ceil(bound.width)),
            height: min(72, max(24, ceil(bound.height)))
        )
        let size = CGSize(width: textSize.width + 28, height: textSize.height + 16)
        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.image { ctx in
            let rect = CGRect(origin: .zero, size: size)
            let path = UIBezierPath(roundedRect: rect, cornerRadius: 12)
            UIColor(red: 14 / 255, green: 35 / 255, blue: 62 / 255, alpha: 0.78).setFill()
            path.fill()
            UIColor(red: 63 / 255, green: 207 / 255, blue: 228 / 255, alpha: 0.85).setStroke()
            path.lineWidth = 2
            path.stroke()
            let textRect = CGRect(x: 14, y: 8, width: textSize.width, height: textSize.height)
            ns.draw(with: textRect, options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: attrs, context: nil)
        }
    }
}
