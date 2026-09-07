import CoreMotion
import Foundation
import SceneKit
import simd
import UIKit

// MARK: - SceneKit VR host (Build 64 motion-first)

final class SCNHostView: UIView, UIGestureRecognizerDelegate {
    static let vrEnvironmentIntensity: CGFloat = 0.7

    private let scnView = VRSCNView()
    private var cameraNode: SCNNode?
    private var sphereNode: SCNNode?
    private var markerNode: SCNNode?
    private var maskOutlineNode: SCNNode?
    private let placedAssetsRoot = SCNNode()
    private var selectionIndicatorNode: SCNNode?
    /// Tracks selected placement root for create-once selection visual (Build 68).
    private var selectedPlacementRoot: SCNNode?
    private weak var repairLongPressRecognizer: UILongPressGestureRecognizer?
    private var editModeActive = false
    private var editTool: VREditTool = .none
    private var selectedPlacementID: String?
    private var placementFloorY = VRPlacementLayout.defaultFloorY
    private var gestureStartScale: Float = 1
    private var gestureStartRotationY: Float = 0
    private var oneFingerOwner: EditOneFingerOwner = .none
    private var moveGrabOffset = SIMD2<Float>(0, 0)
    private var lastValidFloorHit: SIMD3<Float>?
    private weak var pinchRecognizer: UIPinchGestureRecognizer?
    private weak var rotationRecognizer: UIRotationGestureRecognizer?
    private weak var panRecognizer: UIPanGestureRecognizer?

    /// Build 69 lighting/shadow PoC — nodes reused across View/Edit (no flicker recreate).
    private let lightingExperiment = VRLightingExperimentController()
    private var lightingPanoramaURL: URL?
    private var lightingMode: VRLightingExperimentMode = .baseline
    private var lightingIBLIntensity: Float = 0.7
    private var lastLightingApplyKey: String = ""

    // Pinch/rotate smoothing targets (Build 67).
    private var smoothingPlacementID: String?
    private var targetUniformScale: Float?
    private var targetRotationY: Float?
    private var renderedUniformScale: Float = 1
    private var renderedRotationY: Float = 0
    private var pinchGestureActive = false
    private var rotationGestureActive = false
    private var transformDisplayLink: CADisplayLink?

    private var look = VRLookComposer()
    private let motionManager = CMMotionManager()
    private let motionQueue = OperationQueue()
    private var referenceAttitude: CMAttitude?
    private var motionHardwareAvailable = false
    private var motionUpdatesRunning = false

    private var freezeFingerDown = false
    private var freezePan = false
    private var freezeLongPress = false
    private var freezeConfirmSheet = false
    private var freezeAppBackground = false
    private var freezeEditMode = false

    /// Desired motion from SwiftUI (user toggle). Hardware may still force off.
    private var motionDesiredEnabled = true

    var onLongPressEquirect: ((Float, Float) -> Void)?
    var onMotionAvailabilityChanged: ((Bool) -> Void)?
    var onPlacedAssetTapped: ((String?) -> Void)?
    var onPlacedAssetTransformChanged: ((String, SIMD3<Float>, Float, Float) -> Void)?

    /// Effective motion tracking (desired ∧ hardware).
    private(set) var isMotionEffectivelyEnabled = false

    private var isMotionFrozen: Bool {
        freezeFingerDown || freezePan || freezeLongPress || freezeConfirmSheet || freezeAppBackground
            || freezeEditMode
    }

    /// Camera euler used by long-press fallback (composed final look).
    var composedCameraYawRad: Float { look.cameraEulerRad.yaw }
    var composedCameraPitchRad: Float { look.cameraEulerRad.pitch }

    override init(frame: CGRect) {
        super.init(frame: frame)
        motionQueue.name = "com.whik.gonggi.vr.motion"
        motionQueue.maxConcurrentOperationCount = 1
        scnView.host = self
        scnView.frame = bounds
        scnView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        scnView.backgroundColor = .black
        scnView.allowsCameraControl = false
        scnView.antialiasingMode = .multisampling4X
        addSubview(scnView)

        let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        pan.maximumNumberOfTouches = 1
        pan.minimumNumberOfTouches = 1
        pan.delegate = self
        scnView.addGestureRecognizer(pan)
        panRecognizer = pan

        let longPress = UILongPressGestureRecognizer(target: self, action: #selector(handleLongPress(_:)))
        longPress.minimumPressDuration = 0.45
        scnView.addGestureRecognizer(longPress)
        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
        tap.delegate = self
        scnView.addGestureRecognizer(tap)
        let pinch = UIPinchGestureRecognizer(target: self, action: #selector(handlePinch(_:)))
        pinch.delegate = self
        scnView.addGestureRecognizer(pinch)
        pinchRecognizer = pinch
        let rotation = UIRotationGestureRecognizer(target: self, action: #selector(handleRotation(_:)))
        rotation.delegate = self
        scnView.addGestureRecognizer(rotation)
        rotationRecognizer = rotation
        repairLongPressRecognizer = longPress
        placedAssetsRoot.name = "placedAssetsRoot"

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(appDidEnterBackground),
            name: UIApplication.didEnterBackgroundNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(appWillEnterForeground),
            name: UIApplication.willEnterForegroundNotification,
            object: nil
        )
    }

    required init?(coder: NSCoder) { fatalError("init(coder:)") }

    deinit {
        NotificationCenter.default.removeObserver(self)
        stopTransformDisplayLink()
        stopMotionUpdates()
    }

    // MARK: - Scene

    func configure(imageURL: URL) {
        let scene = SCNScene()
        let sphere = SCNSphere(radius: 10)
        sphere.segmentCount = 192

        let material = SCNMaterial()
        material.isDoubleSided = true
        material.lightingModel = .constant
        applyTexture(to: material, imageURL: imageURL)
        material.diffuse.wrapS = .repeat
        material.diffuse.wrapT = .clamp
        sphere.firstMaterial = material
        sphere.firstMaterial?.cullMode = .front

        let sphereNode = SCNNode(geometry: sphere)
        let s = Quick360SphereCoordinateConvention.insideOutScale
        sphereNode.scale = SCNVector3(s.x, s.y, s.z)
        sphereNode.name = "sphere"
        sphereNode.categoryBitMask = VRPlacedAssetCategory.panorama
        scene.rootNode.addChildNode(sphereNode)
        self.sphereNode = sphereNode

        placedAssetsRoot.removeFromParentNode()
        scene.rootNode.addChildNode(placedAssetsRoot)

        let cameraNode = SCNNode()
        cameraNode.camera = SCNCamera()
        cameraNode.camera?.fieldOfView = 70
        cameraNode.camera?.zNear = 0.1
        cameraNode.camera?.zFar = 100
        cameraNode.position = SCNVector3(0, 0, 0)
        scene.rootNode.addChildNode(cameraNode)

        scnView.scene = scene
        scnView.pointOfView = cameraNode
        self.cameraNode = cameraNode

        lightingExperiment.attach(scene: scene, placedAssetsRoot: placedAssetsRoot)
        lightingExperiment.setFloorY(placementFloorY)
        lastLightingApplyKey = ""

        look = VRLookComposer()
        referenceAttitude = nil
        applyLookToCamera()
        startMotionIfPossible()
    }

    /// Reload equirect texture without resetting look composition.
    func reloadTexture(from imageURL: URL) {
        guard let material = sphereNode?.geometry?.firstMaterial else {
            configure(imageURL: imageURL)
            return
        }
        applyTexture(to: material, imageURL: imageURL)
        applyLookToCamera()
    }

    // MARK: - Asset placement

    func setEditModeActive(_ active: Bool) {
        let wasFrozen = isMotionFrozen
        freezeEditMode = active
        editModeActive = active
        if !active {
            oneFingerOwner = .none
            stopSmoothingAndDisplayLink()
            VRPlacedAssetNodeFactory.hideAllSelectionVisuals(in: placedAssetsRoot)
            selectionIndicatorNode = nil
            selectedPlacementRoot = nil
        }
        refreshAllHitProxies(enabled: active)
        if wasFrozen, !isMotionFrozen {
            unfreezeBakeAndReanchor()
        }
        applyLookToCamera()
    }

    func setEditTool(_ tool: VREditTool, selectedId: String?, floorY: Float) {
        editTool = tool
        placementFloorY = floorY
        lightingExperiment.setFloorY(floorY)
        if selectedPlacementID != selectedId {
            selectAsset(id: selectedId)
        } else {
            selectedPlacementID = selectedId
        }
    }

    func syncPlacedAssets(
        _ entries: [VRPlacedAssetEntry],
        floorY: Float,
        metadata: [String: MobileAssetDTO],
        modelURLs: [String: URL] = [:]
    ) {
        placementFloorY = floorY
        lightingExperiment.setFloorY(floorY)
        selectionIndicatorNode?.removeFromParentNode()
        selectionIndicatorNode = nil
        placedAssetsRoot.childNodes.forEach { $0.removeFromParentNode() }

        for entry in entries.prefix(VRPlacementLayout.maxAssets) {
            var floorEntry = entry
            floorEntry.position.y = floorY
            let node = VRPlacedAssetNodeFactory.makeNode(
                entry: floorEntry,
                asset: metadata[entry.assetId],
                modelURL: modelURLs[entry.assetId]
            )
            placedAssetsRoot.addChildNode(node)
        }
        refreshAllHitProxies(enabled: editModeActive)
        selectAsset(id: selectedPlacementID)
        // Re-apply contact opacity / castsShadow after membership rebuild (nodes reused for lights).
        lastLightingApplyKey = ""
        applyLightingExperimentIfNeeded(force: true)
    }

    private func refreshAllHitProxies(enabled: Bool) {
        let cam = SIMD3(
            cameraWorldTransform.columns.3.x,
            cameraWorldTransform.columns.3.y,
            cameraWorldTransform.columns.3.z
        )
        let minExtentBase = VRGestureMath.minimumHitExtentMeters(
            distance: 2.0,
            viewportHeight: Float(max(viewportSize.height, 1)),
            verticalFOVDegrees: Float(cameraNode?.camera?.fieldOfView ?? 70)
        )
        for node in placedAssetsRoot.childNodes {
            let pos = SIMD3(node.position.x, node.position.y, node.position.z)
            let distance = max(simd_length(pos - cam), 0.5)
            let minExtent = VRGestureMath.minimumHitExtentMeters(
                distance: distance,
                viewportHeight: Float(max(viewportSize.height, 1)),
                verticalFOVDegrees: Float(cameraNode?.camera?.fieldOfView ?? 70)
            )
            // Cap growth so nearby small assets don't swallow neighbors.
            let capped = min(max(minExtent, minExtentBase * 0.85), 0.55)
            VRPlacedAssetNodeFactory.refreshHitProxy(
                on: node,
                minimumExtent: capped,
                enabled: enabled
            )
        }
    }

    func selectAsset(id: String?) {
        selectedPlacementID = id
        VRPlacedAssetNodeFactory.hideAllSelectionVisuals(in: placedAssetsRoot)
        selectionIndicatorNode = nil
        selectedPlacementRoot = nil
        guard let id,
              let assetNode = placedAssetsRoot.childNodes.first(where: {
                  VRPlacedAssetNodeFactory.placedAssetID(from: $0) == id
              })
        else { return }

        // Create-once (or unhide). Uses cached mesh bounds — never proxy-inflated root.boundingBox.
        let visual = VRPlacedAssetNodeFactory.ensureSelectionVisual(on: assetNode, visible: true)
        selectionIndicatorNode = visual
        selectedPlacementRoot = assetNode
    }

    func floorPointFromScreen(_ point: CGPoint, floorY: Float) -> SIMD3<Float> {
        VRFloorRay.floorPoint(
            screenPoint: point,
            viewportSize: viewportSize,
            cameraTransform: cameraWorldTransform,
            floorY: floorY,
            verticalFOVDegrees: Float(cameraNode?.camera?.fieldOfView ?? 70)
        )
    }

    func updatePlacedAssetTransform(
        id: String,
        position: SIMD3<Float>,
        rotationY: Float,
        uniformScale: Float
    ) {
        guard let node = assetNode(id: id) else { return }
        let scale = VRPlacedAssetEntry.clampedScale(uniformScale)
        node.position = SCNVector3(position.x, placementFloorY, position.z)
        node.eulerAngles.y = rotationY
        // Root uniform scale — selection/proxy/shadow inherit. No geometry rebuild.
        node.scale = SCNVector3(scale, scale, scale)
    }

    func removePlacedAsset(id: String) {
        assetNode(id: id)?.removeFromParentNode()
        if selectedPlacementID == id {
            selectAsset(id: nil)
        }
    }

    var cameraWorldTransform: simd_float4x4 {
        cameraNode?.presentation.simdWorldTransform ?? matrix_identity_float4x4
    }

    var viewportSize: CGSize { scnView.bounds.size }

    private func assetNode(id: String) -> SCNNode? {
        placedAssetsRoot.childNodes.first {
            VRPlacedAssetNodeFactory.placedAssetID(from: $0) == id
        }
    }

    func hitTestPlacedAsset(at point: CGPoint) -> String? {
        let mask = VRPlacedAssetCategory.asset | VRPlacedAssetCategory.interaction
        let hits = scnView.hitTest(point, options: [
            .searchMode: SCNHitTestSearchMode.closest.rawValue,
            .categoryBitMask: mask,
            .boundingBoxOnly: false,
        ])
        // Prefer real mesh hits over proxy-only when both present at similar depth.
        let meshHit = hits.first {
            $0.node.categoryBitMask & VRPlacedAssetCategory.asset != 0
                && $0.node.name != VRPlacedAssetNodeFactory.hitProxyName
        }
        if let meshHit {
            return VRPlacedAssetNodeFactory.placedAssetID(from: meshHit.node)
        }
        return hits.lazy.compactMap {
            VRPlacedAssetNodeFactory.placedAssetID(from: $0.node)
        }.first
    }

    func applyEnvironmentLighting(from imageURL: URL) {
        lightingPanoramaURL = imageURL
        applyLightingExperimentIfNeeded(force: false)
    }

    /// Build 69 PoC — mode/IBL from internal selector; default remains baseline IBL 0.7.
    func setLightingExperiment(
        mode: VRLightingExperimentMode,
        iblIntensity: Float,
        panoramaURL: URL?
    ) {
        lightingMode = mode
        lightingIBLIntensity = iblIntensity
        if let panoramaURL {
            lightingPanoramaURL = panoramaURL
        }
        #if DEBUG
        scnView.showsStatistics = mode != .baseline
        #endif
        applyLightingExperimentIfNeeded(force: false)
    }

    func lightingExperimentDebugSnapshot() -> (
        mode: VRLightingExperimentMode,
        ibl: Float,
        estimate: VRDominantLightEstimate,
        assetCount: Int
    ) {
        (
            lightingExperiment.mode,
            lightingExperiment.iblIntensity,
            lightingExperiment.latestEstimate,
            placedAssetsRoot.childNodes.count
        )
    }

    private func applyLightingExperimentIfNeeded(force: Bool) {
        guard scnView.scene != nil else { return }
        let urlPath = lightingPanoramaURL?.path ?? ""
        let key = "\(lightingMode.rawValue)|\(lightingIBLIntensity)|\(urlPath)|\(placementFloorY)"
        guard force || key != lastLightingApplyKey else { return }
        lastLightingApplyKey = key
        lightingExperiment.setFloorY(placementFloorY)
        lightingExperiment.apply(
            mode: lightingMode,
            iblIntensity: lightingIBLIntensity,
            panoramaURL: lightingPanoramaURL,
            forceReestimate: force
        )
    }

    func setRepairLongPressEnabled(_ enabled: Bool) {
        let wasFrozen = isMotionFrozen
        repairLongPressRecognizer?.isEnabled = enabled
        if !enabled {
            freezeLongPress = false
        }
        if wasFrozen, !isMotionFrozen {
            unfreezeBakeAndReanchor()
        }
    }

    private func applyTexture(to material: SCNMaterial, imageURL: URL) {
        let raw = UIImage(contentsOfFile: imageURL.path)
        if let raw,
           let prepared = Quick360SphereCoordinateConvention.prepareEquirectTextureForInsideOut(uiImage: raw) {
            material.diffuse.contents = prepared
        } else if let raw, raw.cgImage != nil {
            material.diffuse.contents = raw
        } else {
            material.diffuse.contents = UIColor(white: 0.12, alpha: 1)
        }
    }

    func updateSelection(
        yawDeg: Float?,
        pitchDeg: Float?,
        radiusYawDeg: Float,
        radiusPitchDeg: Float
    ) {
        markerNode?.removeFromParentNode()
        markerNode = nil
        maskOutlineNode?.removeFromParentNode()
        maskOutlineNode = nil
        guard let yawDeg, let pitchDeg, let scene = scnView.scene else { return }

        let r: Float = 9.2
        let p = VRSphereEquirectBridge.insideOutSpherePoint(
            yawDeg: yawDeg,
            pitchDeg: pitchDeg,
            radius: r
        )
        let marker = SCNNode(geometry: SCNSphere(radius: 0.12))
        marker.geometry?.firstMaterial?.diffuse.contents = UIColor.systemYellow
        marker.geometry?.firstMaterial?.emission.contents = UIColor.systemYellow
        marker.position = SCNVector3(p.x, p.y, p.z)
        scene.rootNode.addChildNode(marker)
        markerNode = marker

        let outline = SCNNode()
        outline.name = "repairMaskOutline"
        let rim = VRSphereEquirectBridge.maskOutlineEquirectPoints(
            centerYawDeg: yawDeg,
            centerPitchDeg: pitchDeg,
            radiusYawDeg: radiusYawDeg,
            radiusPitchDeg: radiusPitchDeg,
            samples: 56
        )
        for (i, pt) in rim.enumerated() {
            let wp = VRSphereEquirectBridge.insideOutSpherePoint(
                yawDeg: pt.yawDeg,
                pitchDeg: pt.pitchDeg,
                radius: r
            )
            let bead = SCNNode(geometry: SCNSphere(radius: 0.045))
            bead.geometry?.firstMaterial?.diffuse.contents = UIColor.systemPink.withAlphaComponent(0.9)
            bead.geometry?.firstMaterial?.emission.contents = UIColor.systemPink.withAlphaComponent(0.55)
            bead.position = SCNVector3(wp.x, wp.y, wp.z)
            outline.addChildNode(bead)

            let next = rim[(i + 1) % rim.count]
            let np = VRSphereEquirectBridge.insideOutSpherePoint(
                yawDeg: next.yawDeg,
                pitchDeg: next.pitchDeg,
                radius: r
            )
            let mid = SIMD3((wp.x + np.x) * 0.5, (wp.y + np.y) * 0.5, (wp.z + np.z) * 0.5)
            let dist = simd_length(SIMD3(np.x - wp.x, np.y - wp.y, np.z - wp.z))
            guard dist > 1e-4 else { continue }
            let cyl = SCNCylinder(radius: 0.018, height: CGFloat(dist))
            cyl.firstMaterial?.diffuse.contents = UIColor.systemPink.withAlphaComponent(0.75)
            cyl.firstMaterial?.emission.contents = UIColor.systemPink.withAlphaComponent(0.35)
            let seg = SCNNode(geometry: cyl)
            seg.position = SCNVector3(mid.x, mid.y, mid.z)
            seg.look(at: SCNVector3(np.x, np.y, np.z), up: SCNVector3(0, 1, 0), localFront: SCNVector3(0, 1, 0))
            outline.addChildNode(seg)
        }
        scene.rootNode.addChildNode(outline)
        maskOutlineNode = outline
    }

    private func applyLookToCamera() {
        let e = look.cameraEulerRad
        cameraNode?.eulerAngles = SCNVector3(e.pitch, e.yaw, 0)
    }

    // MARK: - Motion control (SwiftUI)

    func setMotionDesiredEnabled(_ enabled: Bool) {
        let was = isMotionEffectivelyEnabled
        motionDesiredEnabled = enabled
        if enabled {
            // Bake nothing — re-anchor so relative starts at zero; visual unchanged.
            if was == false {
                look.bakeMotionIntoBase()
            }
            referenceAttitude = nil
            startMotionIfPossible()
            applyLookToCamera()
        } else {
            look.bakeMotionIntoBase()
            applyLookToCamera()
            // Keep updates running only if we want quick re-enable; stop to save battery.
            // Preference: stop when OFF.
            stopMotionUpdates()
            publishAvailability()
        }
    }

    func recenterKeepingVisual() {
        look.bakeAllIntoBase()
        referenceAttitude = nil
        applyLookToCamera()
    }

    func setConfirmSheetPresented(_ presented: Bool) {
        let wasFrozen = isMotionFrozen
        freezeConfirmSheet = presented
        if wasFrozen, !isMotionFrozen {
            unfreezeBakeAndReanchor()
        } else if !wasFrozen, isMotionFrozen {
            // entering freeze — hold last motion values
        }
        applyLookToCamera()
    }

    // MARK: - CoreMotion

    private func startMotionIfPossible() {
        guard motionDesiredEnabled else {
            isMotionEffectivelyEnabled = false
            publishAvailability()
            return
        }
        guard motionManager.isDeviceMotionAvailable else {
            motionHardwareAvailable = false
            isMotionEffectivelyEnabled = false
            publishAvailability()
            return
        }
        motionHardwareAvailable = true
        if motionUpdatesRunning {
            isMotionEffectivelyEnabled = true
            publishAvailability()
            return
        }
        motionManager.deviceMotionUpdateInterval = 1.0 / 60.0
        motionManager.startDeviceMotionUpdates(using: .xArbitraryZVertical, to: motionQueue) {
            [weak self] data, error in
            guard let self else { return }
            if error != nil || data == nil {
                DispatchQueue.main.async {
                    self.motionHardwareAvailable = false
                    self.isMotionEffectivelyEnabled = false
                    self.stopMotionUpdates()
                    self.publishAvailability()
                }
                return
            }
            guard let data else { return }
            DispatchQueue.main.async {
                self.handleDeviceMotion(data.attitude)
            }
        }
        motionUpdatesRunning = true
        isMotionEffectivelyEnabled = true
        publishAvailability()
    }

    private func stopMotionUpdates() {
        if motionUpdatesRunning {
            motionManager.stopDeviceMotionUpdates()
            motionUpdatesRunning = false
        }
        isMotionEffectivelyEnabled = false
    }

    private func handleDeviceMotion(_ attitude: CMAttitude) {
        guard motionDesiredEnabled, motionHardwareAvailable else { return }
        if referenceAttitude == nil {
            referenceAttitude = attitude.copy() as? CMAttitude
            look.setMotionLook(yawDeg: 0, pitchDeg: 0)
            applyLookToCamera()
            return
        }
        guard !isMotionFrozen else { return }
        guard let reference = referenceAttitude,
              let relative = attitude.copy() as? CMAttitude
        else { return }
        relative.multiply(byInverseOf: reference)
        let delta = VRLookMath.equirectDeltaFromRelativeRotationMatrix(relative.rotationMatrix)
        look.setMotionLook(yawDeg: delta.yawDeg, pitchDeg: delta.pitchDeg)
        applyLookToCamera()
    }

    private func unfreezeBakeAndReanchor() {
        look.bakeMotionIntoBase()
        referenceAttitude = nil
        applyLookToCamera()
    }

    private func publishAvailability() {
        onMotionAvailabilityChanged?(motionHardwareAvailable)
    }

    // MARK: - Touches / freeze

    fileprivate func noteFingerDown() {
        freezeFingerDown = true
    }

    fileprivate func noteFingerUpIfClear() {
        let wasFrozen = isMotionFrozen
        freezeFingerDown = false
        // Pan/long-press may still hold freeze.
        if wasFrozen, !isMotionFrozen {
            unfreezeBakeAndReanchor()
        }
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        super.touchesBegan(touches, with: event)
    }

    @objc private func appDidEnterBackground() {
        freezeAppBackground = true
        stopMotionUpdates()
    }

    @objc private func appWillEnterForeground() {
        freezeAppBackground = false
        look.bakeMotionIntoBase()
        referenceAttitude = nil
        if motionDesiredEnabled {
            startMotionIfPossible()
        }
        applyLookToCamera()
    }

    // MARK: - Gestures

    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
    ) -> Bool {
        let pair = (gestureRecognizer, otherGestureRecognizer)
        if (pair.0 is UIPinchGestureRecognizer && pair.1 is UIRotationGestureRecognizer)
            || (pair.0 is UIRotationGestureRecognizer && pair.1 is UIPinchGestureRecognizer) {
            return editModeActive && selectedPlacementID != nil
        }
        return false
    }

    override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard editModeActive, gestureRecognizer is UIPanGestureRecognizer else { return true }
        // While a two-finger transform is active, block one-finger pan ownership flips.
        if pinchGestureActive || rotationGestureActive { return false }
        return true
    }

    @objc private func handlePan(_ g: UIPanGestureRecognizer) {
        if editModeActive {
            handleEditPan(g)
            return
        }
        switch g.state {
        case .began:
            freezePan = true
        case .changed:
            freezePan = true
            let t = g.translation(in: scnView)
            g.setTranslation(.zero, in: scnView)
            look.applyTouchTranslation(dx: t.x, dy: t.y)
            applyLookToCamera()
        case .ended, .cancelled, .failed:
            let wasFrozen = isMotionFrozen
            freezePan = false
            if wasFrozen, !isMotionFrozen {
                unfreezeBakeAndReanchor()
            }
        default:
            break
        }
    }

    @objc private func handleTap(_ gesture: UITapGestureRecognizer) {
        guard editModeActive, gesture.state == .ended else { return }
        // Don't steal selection mid-drag.
        if case .assetMove = oneFingerOwner { return }
        let id = hitTestPlacedAsset(at: gesture.location(in: scnView))
        selectAsset(id: id)
        onPlacedAssetTapped?(id)
        #if DEBUG
        print("[vr-place67] tap select=\(id ?? "nil")")
        #endif
    }

    @objc private func handlePinch(_ gesture: UIPinchGestureRecognizer) {
        guard editModeActive,
              let id = selectedPlacementID, let node = assetNode(id: id)
        else { return }
        switch gesture.state {
        case .began:
            pinchGestureActive = true
            beginSmoothing(for: id, node: node)
            gestureStartScale = renderedUniformScale
            targetUniformScale = renderedUniformScale
            #if DEBUG
            print("[vr-place67] pinch begin id=\(id) scale=\(gestureStartScale)")
            #endif
        case .changed:
            targetUniformScale = VRPlacedAssetEntry.clampedScale(
                gestureStartScale * Float(gesture.scale)
            )
            startTransformDisplayLinkIfNeeded()
        case .ended, .cancelled, .failed:
            pinchGestureActive = false
            if let target = targetUniformScale {
                renderedUniformScale = target
                applyRenderedTransform(to: node)
            }
            finishSmoothingIfIdle(id: id)
            #if DEBUG
            print("[vr-place67] pinch end id=\(id)")
            #endif
        default:
            break
        }
    }

    @objc private func handleRotation(_ gesture: UIRotationGestureRecognizer) {
        guard editModeActive,
              let id = selectedPlacementID, let node = assetNode(id: id)
        else { return }
        switch gesture.state {
        case .began:
            rotationGestureActive = true
            beginSmoothing(for: id, node: node)
            gestureStartRotationY = renderedRotationY
            targetRotationY = renderedRotationY
            #if DEBUG
            print("[vr-place67] rotate begin id=\(id)")
            #endif
        case .changed:
            // Match visual clockwise finger motion (UIKit rotation is CCW-positive).
            targetRotationY = gestureStartRotationY - Float(gesture.rotation)
            startTransformDisplayLinkIfNeeded()
        case .ended, .cancelled, .failed:
            rotationGestureActive = false
            if let target = targetRotationY {
                renderedRotationY = target
                applyRenderedTransform(to: node)
            }
            finishSmoothingIfIdle(id: id)
            #if DEBUG
            print("[vr-place67] rotate end id=\(id)")
            #endif
        default:
            break
        }
    }

    private func handleEditPan(_ gesture: UIPanGestureRecognizer) {
        let location = gesture.location(in: scnView)
        switch gesture.state {
        case .began:
            // Lock owner once — never re-hitTest on changed (Build 67 small-asset fix).
            if let hitId = hitTestPlacedAsset(at: location) {
                oneFingerOwner = .assetMove(placementId: hitId)
                selectedPlacementID = hitId
                selectAsset(id: hitId)
                onPlacedAssetTapped?(hitId)
                beginMove(id: hitId, screenPoint: location)
                #if DEBUG
                print("[vr-place67] owner=assetMove id=\(hitId)")
                #endif
            } else {
                oneFingerOwner = .cameraPan
                gesture.setTranslation(.zero, in: scnView)
                #if DEBUG
                print("[vr-place67] owner=cameraPan")
                #endif
            }
        case .changed:
            switch oneFingerOwner {
            case .assetMove(let id):
                guard let node = assetNode(id: id) else { return }
                continueMove(node: node, screenPoint: location)
            case .cameraPan:
                let t = gesture.translation(in: scnView)
                gesture.setTranslation(.zero, in: scnView)
                look.applyTouchTranslation(dx: t.x, dy: t.y)
                applyLookToCamera()
            case .none:
                break
            }
        case .ended, .cancelled, .failed:
            if case .assetMove(let id) = oneFingerOwner {
                publishTransform(for: id)
                #if DEBUG
                print("[vr-place67] move end id=\(id)")
                #endif
            }
            oneFingerOwner = .none
            lastValidFloorHit = nil
        default:
            break
        }
    }

    private func beginMove(id: String, screenPoint: CGPoint) {
        guard let node = assetNode(id: id) else { return }
        let floorHit = floorPointIfValid(screenPoint) ?? SIMD3(
            node.position.x,
            placementFloorY,
            node.position.z
        )
        lastValidFloorHit = floorHit
        moveGrabOffset = SIMD2(node.position.x - floorHit.x, node.position.z - floorHit.z)
    }

    private func continueMove(node: SCNNode, screenPoint: CGPoint) {
        guard let floorHit = floorPointIfValid(screenPoint) ?? lastValidFloorHit else { return }
        lastValidFloorHit = floorHit
        let x = floorHit.x + moveGrabOffset.x
        let z = floorHit.z + moveGrabOffset.y
        let origin = SIMD3(
            cameraWorldTransform.columns.3.x,
            placementFloorY,
            cameraWorldTransform.columns.3.z
        )
        let clamped = VRFloorRay.clampDistance(
            SIMD3(x, placementFloorY, z),
            origin: origin,
            floorY: placementFloorY
        )
        node.position = SCNVector3(clamped.x, placementFloorY, clamped.z)
    }

    private func floorPointIfValid(_ screenPoint: CGPoint) -> SIMD3<Float>? {
        VRFloorRay.floorPointIfValid(
            screenPoint: screenPoint,
            viewportSize: viewportSize,
            cameraTransform: cameraWorldTransform,
            floorY: placementFloorY,
            verticalFOVDegrees: Float(cameraNode?.camera?.fieldOfView ?? 70)
        )
    }

    private func currentUniformScale(of node: SCNNode) -> Float {
        VRPlacedAssetEntry.clampedScale(node.scale.x)
    }

    private func beginSmoothing(for id: String, node: SCNNode) {
        if smoothingPlacementID != id {
            renderedUniformScale = currentUniformScale(of: node)
            renderedRotationY = node.eulerAngles.y
            smoothingPlacementID = id
        }
        targetUniformScale = renderedUniformScale
        targetRotationY = renderedRotationY
        startTransformDisplayLinkIfNeeded()
    }

    private func applyRenderedTransform(to node: SCNNode) {
        // Parent-only transform updates — selection/proxy/shadow inherit. Zero geometry work.
        node.eulerAngles.y = renderedRotationY
        let scale = VRPlacedAssetEntry.clampedScale(renderedUniformScale)
        node.scale = SCNVector3(scale, scale, scale)
    }

    private func startTransformDisplayLinkIfNeeded() {
        guard transformDisplayLink == nil else { return }
        let link = CADisplayLink(target: self, selector: #selector(tickTransformSmoothing))
        link.add(to: .main, forMode: .common)
        transformDisplayLink = link
    }

    private func stopTransformDisplayLink() {
        transformDisplayLink?.invalidate()
        transformDisplayLink = nil
    }

    private func stopSmoothingAndDisplayLink() {
        pinchGestureActive = false
        rotationGestureActive = false
        targetUniformScale = nil
        targetRotationY = nil
        smoothingPlacementID = nil
        stopTransformDisplayLink()
    }

    private func finishSmoothingIfIdle(id: String) {
        guard !pinchGestureActive, !rotationGestureActive else {
            startTransformDisplayLinkIfNeeded()
            return
        }
        // Snap to targets then commit draft once.
        if let node = assetNode(id: id) {
            if let t = targetUniformScale { renderedUniformScale = t }
            if let t = targetRotationY { renderedRotationY = t }
            applyRenderedTransform(to: node)
            publishTransform(for: id, scale: renderedUniformScale)
        }
        targetUniformScale = nil
        targetRotationY = nil
        smoothingPlacementID = nil
        stopTransformDisplayLink()
        // Proxy refresh only after gesture settles — never during CADisplayLink frames.
    }

    @objc private func tickTransformSmoothing() {
        guard let id = smoothingPlacementID, let node = assetNode(id: id) else {
            stopTransformDisplayLink()
            return
        }
        var dirty = false
        if let target = targetUniformScale {
            let next = VRGestureMath.lerp(
                renderedUniformScale,
                target,
                alpha: VRGestureMath.pinchLerpAlpha
            )
            if abs(next - renderedUniformScale) > 1e-4 {
                renderedUniformScale = next
                dirty = true
            } else {
                renderedUniformScale = target
            }
        }
        if let target = targetRotationY {
            let next = VRGestureMath.lerpAngle(
                renderedRotationY,
                target,
                alpha: VRGestureMath.rotateLerpAlpha
            )
            if abs(VRGestureMath.shortestAngleDelta(from: renderedRotationY, to: target)) > 1e-4 {
                renderedRotationY = next
                dirty = true
            } else {
                renderedRotationY = target
            }
        }
        if dirty || pinchGestureActive || rotationGestureActive {
            applyRenderedTransform(to: node)
        }
        #if DEBUG
        // Selection/proxy must stay allocation-free on the hot path.
        #endif
        if !pinchGestureActive, !rotationGestureActive, !dirty {
            stopTransformDisplayLink()
        }
    }

    private func publishTransform(for id: String, scale explicitScale: Float? = nil) {
        guard let node = assetNode(id: id) else { return }
        let scale = explicitScale ?? currentUniformScale(of: node)
        onPlacedAssetTransformChanged?(
            id,
            SIMD3(node.position.x, placementFloorY, node.position.z),
            node.eulerAngles.y,
            scale
        )
    }

    @objc private func handleLongPress(_ g: UILongPressGestureRecognizer) {
        switch g.state {
        case .began:
            freezeLongPress = true
            resolveLongPress(at: g.location(in: scnView))
        case .ended, .cancelled, .failed:
            let wasFrozen = isMotionFrozen
            freezeLongPress = false
            if wasFrozen, !isMotionFrozen {
                unfreezeBakeAndReanchor()
            }
        default:
            break
        }
    }

    private func resolveLongPress(at point: CGPoint) {
        let hits = scnView.hitTest(point, options: [
            .searchMode: SCNHitTestSearchMode.closest.rawValue,
            .categoryBitMask: VRPlacedAssetCategory.panorama,
            .boundingBoxOnly: false
        ])
        let sphereHit = hits.first { $0.node.name == "sphere" || $0.node == sphereNode }

        let yawDeg: Float
        let pitchDeg: Float
        if let hit = sphereHit {
            let uv = hit.textureCoordinates(withMappingChannel: 0)
            let eq = VRSphereEquirectBridge.equirectDegreesFromTextureUV(
                u: Float(uv.x),
                v: Float(uv.y)
            )
            yawDeg = eq.yawDeg
            pitchDeg = eq.pitchDeg
            #if DEBUG
            let cam = look.cameraEulerRad
            print(
                "[repair-bridge] source=hitTestUV camYawDeg=\(cam.yaw * 180 / .pi) camPitchDeg=\(cam.pitch * 180 / .pi) bridgedYaw=\(yawDeg) bridgedPitch=\(pitchDeg)"
            )
            #endif
        } else {
            let cam = look.cameraEulerRad
            let eq = VRSphereEquirectBridge.equirectDegreesFromScreenPoint(
                point: point,
                viewSize: scnView.bounds.size,
                cameraYawRad: cam.yaw,
                cameraPitchRad: cam.pitch,
                fieldOfViewDeg: 70
            )
            yawDeg = eq.yawDeg
            pitchDeg = eq.pitchDeg
            #if DEBUG
            print(
                "[repair-bridge] source=cameraFallback camYawDeg=\(cam.yaw * 180 / .pi) camPitchDeg=\(cam.pitch * 180 / .pi) bridgedYaw=\(yawDeg) bridgedPitch=\(pitchDeg)"
            )
            #endif
        }
        onLongPressEquirect?(yawDeg, pitchDeg)
    }
}

/// SCNView that reports finger activity to host for motion freeze.
private final class VRSCNView: SCNView {
    weak var host: SCNHostView?

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        host?.noteFingerDown()
        super.touchesBegan(touches, with: event)
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        super.touchesEnded(touches, with: event)
        if activeTouchCount(in: event) == 0 {
            host?.noteFingerUpIfClear()
        }
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        super.touchesCancelled(touches, with: event)
        if activeTouchCount(in: event) == 0 {
            host?.noteFingerUpIfClear()
        }
    }

    private func activeTouchCount(in event: UIEvent?) -> Int {
        event?.touches(for: self)?.filter {
            $0.phase == .began || $0.phase == .moved || $0.phase == .stationary
        }.count ?? 0
    }
}
