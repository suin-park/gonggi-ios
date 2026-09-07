import Foundation
import ObjectiveC
import SceneKit
import UIKit

private var vrPlacedAssetContentBaseScaleKey: UInt8 = 0

enum VRPlacedAssetCategory {
    static let panorama = 1 << 0
    static let asset = 1 << 1
    static let shadow = 1 << 2
}

enum VRPlacedAssetNodeFactory {
    static let rootNamePrefix = "placedAsset:"

    static func makeNode(
        entry: VRPlacedAssetEntry,
        asset: MobileAssetDTO?,
        modelURL: URL?
    ) -> SCNNode {
        let root = SCNNode()
        root.name = rootNamePrefix + entry.id
        root.position = SCNVector3(entry.position.x, entry.position.y, entry.position.z)
        root.eulerAngles.y = entry.rotationY
        root.categoryBitMask = VRPlacedAssetCategory.asset

        let scale = VRPlacedAssetEntry.clampedScale(entry.uniformScale)
        let content: SCNNode
        let footprint: SIMD2<Float>
        if asset?.availableForPlacement != false,
           let modelURL,
           let loaded = loadModel(from: modelURL) {
            applyPhysicallyBasedMaterials(to: loaded)
            setCategoryRecursively(loaded, category: VRPlacedAssetCategory.asset)
            let rawFootprint = normalizeBottom(of: loaded)
            let physicalScale = metadataScale(asset: asset, node: loaded)
            footprint = rawFootprint * physicalScale
            let renderedScale = scale * physicalScale
            loaded.scale = SCNVector3(renderedScale, renderedScale, renderedScale)
            content = loaded
            setContentBaseScale(physicalScale, on: root)
        } else {
            let placeholder = makePlaceholder(asset: asset)
            placeholder.scale = SCNVector3(scale, scale, scale)
            footprint = placeholderFootprint(asset: asset)
            content = placeholder
            setContentBaseScale(1, on: root)
        }
        root.addChildNode(content)

        let fallbackRadius = max(footprint.x, footprint.y) * 0.55
        let shadowRadius = max(0.08, entry.shadowRadius ?? fallbackRadius)
        let shadow = makeShadow(
            radius: shadowRadius,
            opacity: entry.shadowOpacity ?? 0.25
        )
        // Uniform scale applied as node scale so pinch can resize shadow continuously.
        shadow.scale = SCNVector3(scale, scale, scale)
        root.addChildNode(shadow)
        return root
    }

    static func placedAssetID(from node: SCNNode) -> String? {
        var current: SCNNode? = node
        while let candidate = current {
            if let name = candidate.name, name.hasPrefix(rootNamePrefix) {
                return String(name.dropFirst(rootNamePrefix.count))
            }
            current = candidate.parent
        }
        return nil
    }

    static func contentBaseScale(of node: SCNNode) -> Float {
        (objc_getAssociatedObject(node, &vrPlacedAssetContentBaseScaleKey) as? NSNumber)?.floatValue ?? 1
    }

    static func setContentBaseScale(_ scale: Float, on node: SCNNode) {
        objc_setAssociatedObject(
            node,
            &vrPlacedAssetContentBaseScaleKey,
            NSNumber(value: scale),
            .OBJC_ASSOCIATION_RETAIN_NONATOMIC
        )
    }

    private static func loadModel(from url: URL) -> SCNNode? {
        // Build 65: USDZ-first via SceneKit only (no native GLB / ModelIO bridge dependency).
        guard let scene = try? SCNScene(url: url, options: nil) else { return nil }
        return container(from: scene)
    }

    private static func container(from scene: SCNScene) -> SCNNode? {
        let container = SCNNode()
        for child in scene.rootNode.childNodes {
            container.addChildNode(child.clone())
        }
        return container.childNodes.isEmpty ? nil : container
    }

    @discardableResult
    private static func normalizeBottom(of node: SCNNode) -> SIMD2<Float> {
        let bounds = node.boundingBox
        let width = max(0.1, bounds.max.x - bounds.min.x)
        let depth = max(0.1, bounds.max.z - bounds.min.z)
        node.position.y -= bounds.min.y
        return SIMD2(width, depth)
    }

    private static func makePlaceholder(asset: MobileAssetDTO?) -> SCNNode {
        let width = meters(asset?.widthCm, fallback: 0.6)
        let height = meters(asset?.heightCm, fallback: 0.6)
        let depth = meters(asset?.depthCm, fallback: 0.6)
        let box = SCNBox(
            width: CGFloat(width),
            height: CGFloat(height),
            length: CGFloat(depth),
            chamferRadius: 0.025
        )
        let material = SCNMaterial()
        material.lightingModel = .physicallyBased
        material.diffuse.contents = UIColor.systemGray
        material.roughness.contents = 0.8
        box.materials = [material]

        let node = SCNNode(geometry: box)
        node.name = "unavailableAssetPlaceholder"
        node.position.y = height * 0.5
        node.categoryBitMask = VRPlacedAssetCategory.asset
        return node
    }

    private static func placeholderFootprint(asset: MobileAssetDTO?) -> SIMD2<Float> {
        SIMD2(
            meters(asset?.widthCm, fallback: 0.6),
            meters(asset?.depthCm, fallback: 0.6)
        )
    }

    private static func meters(_ centimeters: Double?, fallback: Float) -> Float {
        guard let centimeters, centimeters > 0 else { return fallback }
        return Float(centimeters / 100)
    }

    private static func metadataScale(asset: MobileAssetDTO?, node: SCNNode) -> Float {
        guard let centimeters = asset?.heightCm, centimeters > 0 else { return 1 }
        let bounds = node.boundingBox
        let modelHeight = bounds.max.y - bounds.min.y
        guard modelHeight > 1e-4 else { return 1 }
        return min(max(Float(centimeters / 100) / modelHeight, 0.05), 20)
    }

    private static func makeShadow(radius: Float, opacity: Float) -> SCNNode {
        let plane = SCNPlane(
            width: CGFloat(radius * 2),
            height: CGFloat(radius * 1.5)
        )
        let material = SCNMaterial()
        material.lightingModel = .constant
        material.diffuse.contents = shadowTexture()
        material.transparency = CGFloat(min(max(opacity, 0), 1))
        material.isDoubleSided = true
        material.writesToDepthBuffer = false
        plane.materials = [material]

        let node = SCNNode(geometry: plane)
        node.name = "placedAssetShadow"
        node.eulerAngles.x = -.pi / 2
        node.position.y = 0.002
        node.categoryBitMask = VRPlacedAssetCategory.shadow
        node.renderingOrder = -1
        return node
    }

    private static func shadowTexture() -> UIImage {
        let size = CGSize(width: 64, height: 64)
        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.image { context in
            context.cgContext.setFillColor(UIColor.black.cgColor)
            context.cgContext.fillEllipse(in: CGRect(origin: .zero, size: size).insetBy(dx: 2, dy: 8))
        }
    }

    private static func applyPhysicallyBasedMaterials(to node: SCNNode) {
        node.enumerateChildNodes { child, _ in
            child.geometry?.materials.forEach { material in
                material.lightingModel = .physicallyBased
            }
        }
        node.geometry?.materials.forEach { material in
            material.lightingModel = .physicallyBased
        }
    }

    private static func setCategoryRecursively(_ node: SCNNode, category: Int) {
        node.categoryBitMask = category
        node.childNodes.forEach { setCategoryRecursively($0, category: category) }
    }
}
