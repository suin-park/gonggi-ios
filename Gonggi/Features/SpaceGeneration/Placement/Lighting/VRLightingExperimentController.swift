import Foundation
import SceneKit
import simd
import UIKit

/// Applies Build 69 lighting experiment modes without recreating the whole VR scene.
final class VRLightingExperimentController {
    private weak var scene: SCNScene?
    private weak var placedAssetsRoot: SCNNode?
    private var directionalNode: SCNNode?
    private var receiverNode: SCNNode?
    private var lastEstimate = VRDominantLightEstimate.empty
    private var lastPanoramaURL: URL?
    private var floorY: Float = VRPlacementLayout.defaultFloorY

    private(set) var mode: VRLightingExperimentMode = .baseline
    private(set) var iblIntensity: Float = 0.7

    var latestEstimate: VRDominantLightEstimate { lastEstimate }

    func attach(scene: SCNScene, placedAssetsRoot: SCNNode) {
        self.scene = scene
        self.placedAssetsRoot = placedAssetsRoot
        ensureNodes(in: scene)
    }

    func setFloorY(_ y: Float) {
        floorY = y
        receiverNode?.position.y = y + 0.001
    }

    func apply(
        mode: VRLightingExperimentMode,
        iblIntensity: Float,
        panoramaURL: URL?,
        forceReestimate: Bool = false
    ) {
        self.mode = mode
        self.iblIntensity = iblIntensity
        guard let scene else { return }

        if let panoramaURL {
            if forceReestimate || panoramaURL != lastPanoramaURL {
                lastPanoramaURL = panoramaURL
                lastEstimate = VRDominantLightEstimator.estimate(from: panoramaURL)
            }
            // JPEG → UIImage → lightingEnvironment (SceneKit treats as sRGB LDR IBL).
            // Do not apply an extra gamma curve here.
            scene.lightingEnvironment.contents = UIImage(contentsOfFile: panoramaURL.path)
        }

        let intensity: CGFloat
        switch mode {
        case .baseline:
            intensity = SCNHostView.vrEnvironmentIntensity
        case .iblTuned, .directionalOnly, .receiver, .hybridFallback:
            intensity = CGFloat(iblIntensity)
        }
        scene.lightingEnvironment.intensity = intensity

        let wantsDirectional: Bool = {
            switch mode {
            case .baseline, .iblTuned: return false
            case .directionalOnly, .receiver, .hybridFallback:
                return lastEstimate.eligible
            }
        }()

        let wantsShadowCast = (mode == .receiver && wantsDirectional)
        let wantsReceiver = (mode == .receiver && wantsDirectional)
        let contactOpacity: Float = {
            switch mode {
            case .baseline, .iblTuned, .directionalOnly:
                return VRLightingExperimentPrefs.baselineContactOpacity
            case .receiver:
                return wantsDirectional
                    ? VRLightingExperimentPrefs.hybridContactOpacity
                    : VRLightingExperimentPrefs.baselineContactOpacity
            case .hybridFallback:
                return VRLightingExperimentPrefs.hybridContactOpacity
            }
        }()

        configureDirectional(
            enabled: wantsDirectional,
            castsShadow: wantsShadowCast,
            estimate: lastEstimate
        )
        configureReceiver(enabled: wantsReceiver)
        configureAssetShadowCasting(enabled: wantsShadowCast)
        configureContactShadows(
            opacity: contactOpacity,
            directionalOffset: mode == .hybridFallback && lastEstimate.eligible
        )

        #if DEBUG
        print(
            "[vr-light69] mode=\(mode.rawValue) ibl=\(intensity) dir=\(wantsDirectional) shadow=\(wantsShadowCast) recv=\(wantsReceiver) contact=\(contactOpacity) conf=\(String(format: "%.2f", lastEstimate.confidence))"
        )
        #endif
    }

    private func ensureNodes(in scene: SCNScene) {
        if directionalNode == nil {
            let light = SCNLight()
            light.type = .directional
            light.intensity = VRLightingExperimentPrefs.directionalSceneKitIntensity
            light.color = UIColor(white: 1, alpha: 1)
            light.castsShadow = false
            light.shadowMode = .deferred
            light.shadowColor = UIColor(white: 0, alpha: 0.22)
            light.shadowRadius = 3
            light.shadowSampleCount = 8
            light.automaticallyAdjustsShadowProjection = true
            // Leave default categoryBitMask so transparent receiver can be illuminated.

            let node = SCNNode()
            node.name = "vrExperimentDirectional"
            node.light = light
            node.isHidden = true
            scene.rootNode.addChildNode(node)
            directionalNode = node
        }

        if receiverNode == nil {
            let plane = SCNPlane(width: 12, height: 12)
            let material = SCNMaterial()
            material.lightingModel = .constant
            material.diffuse.contents = UIColor.white
            material.transparency = 0.01
            material.writesToDepthBuffer = true
            material.readsFromDepthBuffer = true
            material.isDoubleSided = false
            // Invisible floor: write depth only so soft shadows can land without tint.
            material.colorBufferWriteMask = []
            plane.materials = [material]

            let node = SCNNode(geometry: plane)
            node.name = "vrExperimentShadowReceiver"
            node.eulerAngles.x = -.pi / 2
            node.position = SCNVector3(0, floorY + 0.001, 0)
            node.categoryBitMask = VRPlacedAssetCategory.shadowReceiver
            node.castsShadow = false
            node.isHidden = true
            scene.rootNode.addChildNode(node)
            receiverNode = node
        }
    }

    private func configureDirectional(
        enabled: Bool,
        castsShadow: Bool,
        estimate: VRDominantLightEstimate
    ) {
        guard let node = directionalNode, let light = node.light else { return }
        node.isHidden = !enabled
        light.castsShadow = castsShadow
        light.intensity = VRLightingExperimentPrefs.directionalSceneKitIntensity
        if enabled {
            let e = VREnvironmentLightMapping.directionalNodeEulerYXZ(
                yawDeg: estimate.dominantYawDeg,
                pitchDeg: max(estimate.dominantPitchDeg, 15)
            )
            node.eulerAngles = SCNVector3(e.x, e.y, e.z)
        }
    }

    private func configureReceiver(enabled: Bool) {
        receiverNode?.isHidden = !enabled
        receiverNode?.position.y = floorY + 0.001
    }

    private func configureAssetShadowCasting(enabled: Bool) {
        guard let root = placedAssetsRoot else { return }
        for placementRoot in root.childNodes {
            placementRoot.castsShadow = false
            for child in placementRoot.childNodes {
                let name = child.name ?? ""
                if name == VRPlacedAssetNodeFactory.hitProxyName
                    || name == VRPlacedAssetNodeFactory.selectionVisualName
                    || name == "placedAssetShadow" {
                    child.castsShadow = false
                    child.enumerateChildNodes { n, _ in n.castsShadow = false }
                    continue
                }
                child.castsShadow = enabled
                child.enumerateChildNodes { n, _ in
                    if (n.categoryBitMask & VRPlacedAssetCategory.selection) != 0
                        || (n.categoryBitMask & VRPlacedAssetCategory.interaction) != 0
                        || (n.categoryBitMask & VRPlacedAssetCategory.shadow) != 0 {
                        n.castsShadow = false
                    } else {
                        n.castsShadow = enabled
                    }
                }
            }
        }
    }

    private func configureContactShadows(opacity: Float, directionalOffset: Bool) {
        guard let root = placedAssetsRoot else { return }
        let yaw = lastEstimate.dominantYawDeg
        let opposite = VREnvironmentLightMapping.oppositeYawDeg(yaw)
        let rad = opposite * .pi / 180
        let offsetXZ = SIMD2(sin(rad), -cos(rad)) * 0.08

        root.enumerateChildNodes { node, _ in
            guard node.name == "placedAssetShadow" else { return }
            node.geometry?.firstMaterial?.transparency = CGFloat(opacity)
            node.castsShadow = false
            if directionalOffset, lastEstimate.eligible {
                node.position.x = offsetXZ.x
                node.position.z = offsetXZ.y
            } else {
                node.position.x = 0
                node.position.z = 0
            }
            node.position.y = 0.002
        }
    }
}
