import Foundation
import ObjectiveC
import SceneKit
import UIKit

private var vrPlacedAssetContentBaseScaleKey: UInt8 = 0
private var vrPlacedAssetVisualBoundsKey: UInt8 = 0

enum VRPlacedAssetCategory {
    static let panorama = 1 << 0
    static let asset = 1 << 1
    static let shadow = 1 << 2
    /// Invisible Edit-only grab target (Build 67).
    static let interaction = 1 << 3
    /// Selection overlay — never hit-tested.
    static let selection = 1 << 4
    /// Build 69 shadow receiver plane — repair/asset hitTest excluded.
    static let shadowReceiver = 1 << 5
}

enum VRPlacedAssetNodeFactory {
    static let rootNamePrefix = "placedAsset:"
    static let hitProxyName = "placedAssetHitProxy"
    static let selectionVisualName = "placedAssetSelectionVisual"
    static let selectionRingName = "placedAssetSelectionRing"

    static func makeNode(
        entry: VRPlacedAssetEntry,
        asset: MobileAssetDTO?,
        modelURL: URL?
    ) -> SCNNode {
        let root = SCNNode()
        root.name = rootNamePrefix + entry.id
        root.position = SCNVector3(entry.position.x, entry.position.y, entry.position.z)
        root.eulerAngles.y = entry.rotationY
        // Uniform scale lives on root so selection/proxy/shadow inherit (Build 68).
        let uniform = VRPlacedAssetEntry.clampedScale(entry.uniformScale)
        root.scale = SCNVector3(uniform, uniform, uniform)
        root.categoryBitMask = VRPlacedAssetCategory.asset

        let content: SCNNode
        let footprint: SIMD2<Float>
        let physicalScale: Float
        if asset?.availableForPlacement != false,
           let modelURL,
           let loaded = loadModel(from: modelURL) {
            applyPhysicallyBasedMaterials(to: loaded)
            setCategoryRecursively(loaded, category: VRPlacedAssetCategory.asset)
            let rawFootprint = normalizeBottom(of: loaded)
            physicalScale = metadataScale(asset: asset, node: loaded)
            footprint = rawFootprint * physicalScale
            loaded.scale = SCNVector3(physicalScale, physicalScale, physicalScale)
            content = loaded
        } else {
            let placeholder = makePlaceholder(asset: asset)
            physicalScale = 1
            footprint = placeholderFootprint(asset: asset)
            content = placeholder
        }
        setContentBaseScale(physicalScale, on: root)
        root.addChildNode(content)

        let bounds = computeVisualBounds(content: content)
        setVisualBounds(bounds, on: root)

        let fallbackRadius = max(footprint.x, footprint.y) * 0.55
        let shadowRadius = max(0.08, entry.shadowRadius ?? fallbackRadius)
        let shadow = makeShadow(radius: shadowRadius, opacity: entry.shadowOpacity ?? 0.25)
        // Shadow scale = 1 under root — inherits root uniform scale.
        root.addChildNode(shadow)

        attachHitProxy(on: root, bounds: bounds, minimumExtent: 0.28, enabled: false)
        return root
    }

    static func setVisualBounds(_ bounds: AssetVisualBounds, on root: SCNNode) {
        objc_setAssociatedObject(
            root,
            &vrPlacedAssetVisualBoundsKey,
            [
                "minx": bounds.min.x, "miny": bounds.min.y, "minz": bounds.min.z,
                "maxx": bounds.max.x, "maxy": bounds.max.y, "maxz": bounds.max.z,
            ] as NSDictionary,
            .OBJC_ASSOCIATION_RETAIN_NONATOMIC
        )
    }

    static func readVisualBounds(from root: SCNNode) -> AssetVisualBounds? {
        guard let dict = objc_getAssociatedObject(root, &vrPlacedAssetVisualBoundsKey) as? NSDictionary,
              let minx = (dict["minx"] as? NSNumber)?.floatValue,
              let miny = (dict["miny"] as? NSNumber)?.floatValue,
              let minz = (dict["minz"] as? NSNumber)?.floatValue,
              let maxx = (dict["maxx"] as? NSNumber)?.floatValue,
              let maxy = (dict["maxy"] as? NSNumber)?.floatValue,
              let maxz = (dict["maxz"] as? NSNumber)?.floatValue
        else { return nil }
        return AssetVisualBounds(min: SIMD3(minx, miny, minz), max: SIMD3(maxx, maxy, maxz))
    }

    static func visualBoundsCached(of root: SCNNode) -> AssetVisualBounds {
        if let cached = readVisualBounds(from: root) { return cached }
        #if DEBUG
        VRSelectionPerfCounters.boundsRecalculations += 1
        #endif
        guard let content = modelContent(of: root) else { return .fallback }
        let bounds = computeVisualBounds(content: content)
        setVisualBounds(bounds, on: root)
        return bounds
    }

    /// Creates selection overlay once. Subsequent calls only toggle visibility.
    @discardableResult
    static func ensureSelectionVisual(on root: SCNNode, visible: Bool) -> SCNNode {
        if let existing = root.childNode(withName: selectionVisualName, recursively: false) {
            existing.isHidden = !visible
            return existing
        }
        #if DEBUG
        VRSelectionPerfCounters.selectionGeometryCreates += 1
        #endif
        let bounds = visualBoundsCached(of: root)
        let container = SCNNode()
        container.name = selectionVisualName
        container.categoryBitMask = VRPlacedAssetCategory.selection
        container.castsShadow = false
        container.isHidden = !visible

        // Thin wire box from mesh bounds only (not hit-proxy size).
        let size = bounds.size
        let box = SCNBox(
            width: CGFloat(max(0.05, size.x)),
            height: CGFloat(max(0.05, size.y)),
            length: CGFloat(max(0.05, size.z)),
            chamferRadius: 0
        )
        let material = SCNMaterial()
        material.lightingModel = .constant
        material.diffuse.contents = UIColor.systemYellow.withAlphaComponent(0.85)
        material.emission.contents = UIColor.systemYellow.withAlphaComponent(0.35)
        material.fillMode = .lines
        material.isDoubleSided = true
        material.writesToDepthBuffer = false
        box.materials = [material]
        let wire = SCNNode(geometry: box)
        wire.position = SCNVector3(bounds.center.x, bounds.center.y, bounds.center.z)
        wire.categoryBitMask = VRPlacedAssetCategory.selection
        wire.castsShadow = false
        container.addChildNode(wire)

        // Floor ring — cheap silhouette cue.
        let ringRadius = max(size.x, size.z) * 0.55
        let ring = SCNTube(
            innerRadius: CGFloat(max(0.02, ringRadius * 0.82)),
            outerRadius: CGFloat(max(0.03, ringRadius)),
            height: 0.008
        )
        let ringMat = SCNMaterial()
        ringMat.lightingModel = .constant
        ringMat.diffuse.contents = UIColor.systemYellow.withAlphaComponent(0.55)
        ringMat.emission.contents = UIColor.systemYellow.withAlphaComponent(0.25)
        ringMat.writesToDepthBuffer = false
        ring.materials = [ringMat]
        let ringNode = SCNNode(geometry: ring)
        ringNode.name = selectionRingName
        ringNode.position = SCNVector3(bounds.center.x, 0.004, bounds.center.z)
        ringNode.categoryBitMask = VRPlacedAssetCategory.selection
        ringNode.castsShadow = false
        container.addChildNode(ringNode)

        root.addChildNode(container)
        return container
    }

    static func setSelectionVisible(on root: SCNNode, visible: Bool) {
        if let existing = root.childNode(withName: selectionVisualName, recursively: false) {
            existing.isHidden = !visible
        } else if visible {
            ensureSelectionVisual(on: root, visible: true)
        }
    }

    static func hideAllSelectionVisuals(in placedAssetsRoot: SCNNode) {
        for child in placedAssetsRoot.childNodes {
            setSelectionVisible(on: child, visible: false)
        }
    }

    static func attachHitProxy(
        on root: SCNNode,
        bounds: AssetVisualBounds,
        minimumExtent: Float,
        enabled: Bool
    ) {
        root.childNodes.filter { $0.name == hitProxyName }.forEach { $0.removeFromParentNode() }
        #if DEBUG
        VRSelectionPerfCounters.proxyGeometryCreates += 1
        #endif

        let size = bounds.size
        let w = CGFloat(VRGestureMath.expandExtent(max(0.01, size.x), minimum: minimumExtent))
        let h = CGFloat(VRGestureMath.expandExtent(max(0.01, size.y), minimum: minimumExtent))
        let d = CGFloat(VRGestureMath.expandExtent(max(0.01, size.z), minimum: minimumExtent))

        let box = SCNBox(width: w, height: h, length: d, chamferRadius: 0)
        let material = SCNMaterial()
        material.diffuse.contents = UIColor.clear
        material.transparency = 0
        material.writesToDepthBuffer = false
        material.readsFromDepthBuffer = false
        material.isDoubleSided = true
        box.materials = [material]

        let proxy = SCNNode(geometry: box)
        proxy.name = hitProxyName
        proxy.categoryBitMask = enabled ? VRPlacedAssetCategory.interaction : 0
        proxy.castsShadow = false
        proxy.isHidden = !enabled
        proxy.renderingOrder = 10
        proxy.position = SCNVector3(bounds.center.x, bounds.center.y, bounds.center.z)
        root.addChildNode(proxy)
    }

    static func refreshHitProxy(on root: SCNNode, minimumExtent: Float, enabled: Bool) {
        let bounds = visualBoundsCached(of: root)
        attachHitProxy(on: root, bounds: bounds, minimumExtent: minimumExtent, enabled: enabled)
    }

    static func modelContent(of root: SCNNode) -> SCNNode? {
        root.childNodes.first {
            $0.name != hitProxyName
                && $0.name != selectionVisualName
                && $0.name != "placedAssetShadow"
                && ($0.categoryBitMask & VRPlacedAssetCategory.asset) != 0
        }
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

    private static func computeVisualBounds(content: SCNNode) -> AssetVisualBounds {
        let bb = content.boundingBox
        let sx = abs(content.scale.x)
        let sy = abs(content.scale.y)
        let sz = abs(content.scale.z)
        let min = SIMD3(
            bb.min.x * sx + content.position.x,
            bb.min.y * sy + content.position.y,
            bb.min.z * sz + content.position.z
        )
        let max = SIMD3(
            bb.max.x * sx + content.position.x,
            bb.max.y * sy + content.position.y,
            bb.max.z * sz + content.position.z
        )
        return AssetVisualBounds(min: min, max: max)
    }

    private static func loadModel(from url: URL) -> SCNNode? {
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
        node.castsShadow = false
        node.renderingOrder = -1
        return node
    }

    /// Soft ellipse: darker center, smoother edge alpha (Build 69 PoC — no custom shader).
    private static func shadowTexture() -> UIImage {
        let size = CGSize(width: 64, height: 64)
        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.image { ctx in
            let cg = ctx.cgContext
            cg.clear(CGRect(origin: .zero, size: size))
            let colors = [
                UIColor(white: 0, alpha: 0.95).cgColor,
                UIColor(white: 0, alpha: 0.45).cgColor,
                UIColor(white: 0, alpha: 0).cgColor,
            ] as CFArray
            let locations: [CGFloat] = [0, 0.45, 1]
            guard let gradient = CGGradient(
                colorsSpace: CGColorSpaceCreateDeviceRGB(),
                colors: colors,
                locations: locations
            ) else { return }
            let center = CGPoint(x: size.width * 0.5, y: size.height * 0.5)
            cg.saveGState()
            cg.addEllipse(in: CGRect(origin: .zero, size: size).insetBy(dx: 1, dy: 6))
            cg.clip()
            cg.drawRadialGradient(
                gradient,
                startCenter: center,
                startRadius: 0,
                endCenter: center,
                endRadius: size.width * 0.48,
                options: [.drawsAfterEndLocation]
            )
            cg.restoreGState()
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
