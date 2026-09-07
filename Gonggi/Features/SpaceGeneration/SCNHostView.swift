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
    private weak var repairLongPressRecognizer: UILongPressGestureRecognizer?
    private var editModeActive = false
    private var editTool: VREditTool = .none
    private var selectedPlacementID: String?
    private var placementFloorY = VRPlacementLayout.defaultFloorY
    private var gestureStartScale: Float = 1
    private var gestureStartRotationY: Float = 0
    private var moveLockedPlacementID: String?
    private var moveGrabOffset = SIMD2<Float>(0, 0)
    private var lastValidFloorHit: SIMD3<Float>?
    private var editCameraPanActive = false
    private weak var pinchRecognizer: UIPinchGestureRecognizer?
    private weak var rotationRecognizer: UIRotationGestureRecognizer?

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
        if wasFrozen, !isMotionFrozen {
            unfreezeBakeAndReanchor()
        }
        applyLookToCamera()
    }

    func setEditTool(_ tool: VREditTool, selectedId: String?, floorY: Float) {
        editTool = tool
        placementFloorY = floorY
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
        selectAsset(id: selectedPlacementID)
    }

    func selectAsset(id: String?) {
        selectedPlacementID = id
        selectionIndicatorNode?.removeFromParentNode()
        selectionIndicatorNode = nil
        guard let id,
              let assetNode = placedAssetsRoot.childNodes.first(where: {
                  VRPlacedAssetNodeFactory.placedAssetID(from: $0) == id
              })
        else { return }

        let bounds = assetNode.boundingBox
        let box = SCNBox(
            width: CGFloat(max(0.1, bounds.max.x - bounds.min.x)),
            height: CGFloat(max(0.1, bounds.max.y - bounds.min.y)),
            length: CGFloat(max(0.1, bounds.max.z - bounds.min.z)),
            chamferRadius: 0
        )
        let material = SCNMaterial()
        material.diffuse.contents = UIColor.systemYellow
        material.emission.contents = UIColor.systemYellow
        material.fillMode = .lines
        material.isDoubleSided = true
        box.materials = [material]

        let indicator = SCNNode(geometry: box)
        indicator.name = "placedAssetSelection"
        indicator.position = SCNVector3(
            (bounds.min.x + bounds.max.x) * 0.5,
            (bounds.min.y + bounds.max.y) * 0.5,
            (bounds.min.z + bounds.max.z) * 0.5
        )
        indicator.categoryBitMask = VRPlacedAssetCategory.shadow
        assetNode.addChildNode(indicator)
        selectionIndicatorNode = indicator
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
        node.position = SCNVector3(position.x, placementFloorY, position.z)
        node.eulerAngles.y = rotationY
        let scale = VRPlacedAssetEntry.clampedScale(uniformScale)
        if let content = node.childNodes.first(where: { $0.categoryBitMask == VRPlacedAssetCategory.asset }) {
            let base = VRPlacedAssetNodeFactory.contentBaseScale(of: node)
            content.scale = SCNVector3(scale * base, scale * base, scale * base)
        }
        if let shadow = node.childNodes.first(where: { $0.name == "placedAssetShadow" }) {
            shadow.scale = SCNVector3(scale, scale, scale)
        }
        // Avoid rebuilding selection outline every transform tick (Build 66 choppy-move fix).
        if selectedPlacementID == id, selectionIndicatorNode == nil {
            selectAsset(id: id)
        }
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
        let hits = scnView.hitTest(point, options: [
            .searchMode: SCNHitTestSearchMode.closest.rawValue,
            .categoryBitMask: VRPlacedAssetCategory.asset,
            .boundingBoxOnly: false,
        ])
        return hits.lazy.compactMap {
            VRPlacedAssetNodeFactory.placedAssetID(from: $0.node)
        }.first
    }

    func applyEnvironmentLighting(from imageURL: URL) {
        guard let scene = scnView.scene else { return }
        scene.lightingEnvironment.contents = UIImage(contentsOfFile: imageURL.path)
        scene.lightingEnvironment.intensity = Self.vrEnvironmentIntensity
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
        let id = hitTestPlacedAsset(at: gesture.location(in: scnView))
        selectAsset(id: id)
        onPlacedAssetTapped?(id)
        #if DEBUG
        print("[vr-place66] tap select=\(id ?? "nil") rootChildren=\(placedAssetsRoot.childNodes.count)")
        #endif
    }

    @objc private func handlePinch(_ gesture: UIPinchGestureRecognizer) {
        guard editModeActive,
              let id = selectedPlacementID, let node = assetNode(id: id)
        else { return }
        switch gesture.state {
        case .began:
            gestureStartScale = currentUniformScale(of: node)
            #if DEBUG
            print("[vr-place66] pinch begin id=\(id) scale=\(gestureStartScale)")
            #endif
        case .changed:
            let scale = VRPlacedAssetEntry.clampedScale(gestureStartScale * Float(gesture.scale))
            updatePlacedAssetTransform(
                id: id,
                position: SIMD3(node.position.x, placementFloorY, node.position.z),
                rotationY: node.eulerAngles.y,
                uniformScale: scale
            )
        case .ended, .cancelled, .failed:
            publishTransform(for: id)
            #if DEBUG
            print("[vr-place66] pinch end id=\(id)")
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
            gestureStartRotationY = node.eulerAngles.y
            #if DEBUG
            print("[vr-place66] rotate begin id=\(id)")
            #endif
        case .changed:
            // Match visual clockwise finger motion (UIKit rotation is CCW-positive).
            node.eulerAngles.y = gestureStartRotationY - Float(gesture.rotation)
        case .ended, .cancelled, .failed:
            publishTransform(for: id)
            #if DEBUG
            print("[vr-place66] rotate end id=\(id)")
            #endif
        default:
            break
        }
    }

    private func handleEditPan(_ gesture: UIPanGestureRecognizer) {
        let location = gesture.location(in: scnView)
        switch gesture.state {
        case .began:
            editCameraPanActive = false
            moveLockedPlacementID = nil
            if let hitId = hitTestPlacedAsset(at: location) {
                selectedPlacementID = hitId
                selectAsset(id: hitId)
                onPlacedAssetTapped?(hitId)
                beginMove(id: hitId, screenPoint: location)
            } else {
                // Empty space: camera look pan (Build 66 routing).
                editCameraPanActive = true
                gesture.setTranslation(.zero, in: scnView)
            }
        case .changed:
            if let id = moveLockedPlacementID, let node = assetNode(id: id) {
                continueMove(node: node, screenPoint: location)
            } else if editCameraPanActive {
                let t = gesture.translation(in: scnView)
                gesture.setTranslation(.zero, in: scnView)
                look.applyTouchTranslation(dx: t.x, dy: t.y)
                applyLookToCamera()
            }
        case .ended, .cancelled, .failed:
            if let id = moveLockedPlacementID {
                publishTransform(for: id)
                #if DEBUG
                print("[vr-place66] move end id=\(id) children=\(placedAssetsRoot.childNodes.count)")
                #endif
            }
            moveLockedPlacementID = nil
            editCameraPanActive = false
            lastValidFloorHit = nil
        default:
            break
        }
    }

    private func beginMove(id: String, screenPoint: CGPoint) {
        guard let node = assetNode(id: id) else { return }
        moveLockedPlacementID = id
        let floorHit = floorPointIfValid(screenPoint) ?? SIMD3(
            node.position.x,
            placementFloorY,
            node.position.z
        )
        lastValidFloorHit = floorHit
        moveGrabOffset = SIMD2(node.position.x - floorHit.x, node.position.z - floorHit.z)
        #if DEBUG
        print("[vr-place66] move begin id=\(id) grab=\(moveGrabOffset)")
        #endif
    }

    private func continueMove(node: SCNNode, screenPoint: CGPoint) {
        guard let floorHit = floorPointIfValid(screenPoint) ?? lastValidFloorHit else { return }
        lastValidFloorHit = floorHit
        let x = floorHit.x + moveGrabOffset.x
        let z = floorHit.z + moveGrabOffset.y
        // Continuous clamp around camera — no discrete snap jumps.
        let origin = SIMD3(cameraWorldTransform.columns.3.x, placementFloorY, cameraWorldTransform.columns.3.z)
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
        let rendered = node.childNodes.first(where: {
            $0.categoryBitMask == VRPlacedAssetCategory.asset
        })?.scale.x ?? 1
        let base = VRPlacedAssetNodeFactory.contentBaseScale(of: node)
        return rendered / max(base, 1e-4)
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
