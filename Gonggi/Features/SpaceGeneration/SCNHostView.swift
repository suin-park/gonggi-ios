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
    private let spaceLinksRoot = SCNNode()
    private var selectionIndicatorNode: SCNNode?
    /// Tracks selected placement root for create-once selection visual (Build 68).
    private var selectedPlacementRoot: SCNNode?
    private weak var repairLongPressRecognizer: UILongPressGestureRecognizer?
    private var editModeActive = false
    private var editTool: VREditTool = .none
    private var selectedPlacementID: String?
    private var selectedSpaceLinkID: String?
    private var spaceLinkPoses: [String: (yaw: Float, pitch: Float, radius: Float)] = [:]
    /// Build 74 — grab offset so began doesn't snap hotspot to finger center.
    private var spaceLinkGrabYawOffsetDeg: Float = 0
    private var spaceLinkGrabPitchOffsetDeg: Float = 0
    private var spaceLinkPoseAtDragBegan: (yaw: Float, pitch: Float, radius: Float)?
    private var isSpaceLinkDragging = false
    #if DEBUG
    private var spaceLinkDragDebugLogged = false
    #endif
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

    /// Build 83 — idle user zoom (pinch). Transition FOV animates camera without mutating this until settle commit.
    private var userViewingFOV: Double = VRViewingFOVMath.defaultFOV
    private var pinchStartUserFOV: Double = VRViewingFOVMath.defaultFOV
    private var viewPinchActive = false
    #if DEBUG
    private var didLogViewPinchChanged = false
    #endif

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
    /// Build 81 — SpaceLink rotate/zoom/crossfade: hold gyro while camera animates.
    private var freezeSpaceLinkTransition = false
    private var spaceLinkTransitionInteractionsLocked = false
    private var transitionDisplayLink: CADisplayLink?
    private var transitionAnimStart: CFTimeInterval = 0
    private var transitionAlignDuration: TimeInterval = 0
    private var transitionZoomStartDelay: TimeInterval = 0
    private var transitionZoomDuration: TimeInterval = 0
    private var transitionStartYaw: Float = 0
    private var transitionStartPitch: Float = 0
    private var transitionEndYaw: Float = 0
    private var transitionEndPitch: Float = 0
    private var transitionStartFOV: Double = 70
    private var transitionEndFOV: Double = 70
    private var transitionCompletion: (() -> Void)?
    private var fovOnlyDisplayLink: CADisplayLink?
    private var fovOnlyStart: CFTimeInterval = 0
    private var fovOnlyDuration: TimeInterval = 0
    private var fovOnlyFrom: Double = 70
    private var fovOnlyTo: Double = 70
    private var fovOnlyCompletion: (() -> Void)?

    /// Desired motion from SwiftUI (user toggle). Hardware may still force off.
    private var motionDesiredEnabled = true

    var onLongPressEquirect: ((Float, Float) -> Void)?
    var onMotionAvailabilityChanged: ((Bool) -> Void)?
    var onPlacedAssetTapped: ((String?) -> Void)?
    var onPlacedAssetTransformChanged: ((String, SIMD3<Float>, Float, Float) -> Void)?
    /// Edit: select · View: navigate intent.
    var onSpaceLinkTapped: ((String?) -> Void)?
    /// Edit drag live — optional; prefer node-only during drag (Build 74).
    var onSpaceLinkPoseChanged: ((String, Float, Float, Float) -> Void)?
    /// Edit drag ended — persist linked pose (PATCH) / commit draft.
    var onSpaceLinkDragEnded: ((String, Float, Float, Float) -> Void)?
    /// true while hotspot drag active — hide floating actions.
    var onSpaceLinkDraggingChanged: ((Bool) -> Void)?
    /// Projected screen point of selected hotspot (Edit overlay).
    var onSpaceLinkScreenPoint: ((CGPoint?) -> Void)?
    /// PATCH fail rollback helper.
    var onSpaceLinkPoseRollback: ((String, Float, Float, Float) -> Void)?

    /// Effective motion tracking (desired ∧ hardware).
    private(set) var isMotionEffectivelyEnabled = false

    private var isMotionFrozen: Bool {
        freezeFingerDown || freezePan || freezeLongPress || freezeConfirmSheet || freezeAppBackground
            || freezeEditMode || freezeSpaceLinkTransition
    }

    /// Build 81 — true while forward SpaceLink transition owns the camera.
    var isSpaceLinkTransitionLocked: Bool { spaceLinkTransitionInteractionsLocked }

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
        spaceLinksRoot.name = "spaceLinksRoot"

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
        stopTransitionDisplayLink()
        stopFOVOnlyDisplayLink()
        stopMotionUpdates()
    }

    // MARK: - Scene

    /// - Parameters:
    ///   - imageURL: on-disk equirect (cache key / fallback).
    ///   - preparedTexture: Build 82 predecoded bitmap; skips main-thread JPEG decode when set.
    ///   - startMotion: false during SpaceLink transition lock so CoreMotion attach is deferred.
    func configure(
        imageURL: URL,
        preparedTexture: UIImage? = nil,
        startMotion: Bool = true
    ) {
        let tScene = CFAbsoluteTimeGetCurrent()
        SpaceLink82Timing.log("sceneCreate start")
        let scene = SCNScene()
        let sphere = SCNSphere(radius: 10)
        sphere.segmentCount = 192

        let material = SCNMaterial()
        material.isDoubleSided = true
        material.lightingModel = .constant
        let tTex = CFAbsoluteTimeGetCurrent()
        applyTexture(to: material, imageURL: imageURL, preparedTexture: preparedTexture)
        SpaceLink82Timing.log("textureAssign", ["ms": SpaceLink82Timing.ms(since: tTex)])
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
        spaceLinksRoot.removeFromParentNode()
        scene.rootNode.addChildNode(spaceLinksRoot)

        let cameraNode = SCNNode()
        cameraNode.camera = SCNCamera()
        cameraNode.camera?.fieldOfView = CGFloat(userViewingFOV)
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
        userViewingFOV = VRViewingFOVMath.defaultFOV
        viewPinchActive = false
        applyLookToCamera()
        applyPresentationFOV(userViewingFOV)
        SpaceLink82Timing.log("sceneCreate end", ["ms": SpaceLink82Timing.ms(since: tScene)])
        if startMotion {
            startMotionIfPossible()
        } else {
            SpaceLink82Timing.log("motionAttach deferred")
        }
    }

    /// SceneKit resource warm-up before crossfade (geometry / materials / textures).
    func prepareFirstFrameReady() async {
        guard let root = scnView.scene?.rootNode else { return }
        let t0 = CFAbsoluteTimeGetCurrent()
        SpaceLink82Timing.log("scenekitPrepare start")
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            scnView.prepare([root]) { _ in
                SpaceLink82Timing.log("scenekitPrepare end", ["ms": SpaceLink82Timing.ms(since: t0)])
                DispatchQueue.main.async {
                    cont.resume()
                }
            }
        }
        // One layout/render tick so the first presented frame is not cold.
        scnView.setNeedsDisplay()
        scnView.layoutIfNeeded()
        SpaceLink82Timing.log("firstFramePresented")
    }

    /// Reload equirect texture without resetting look composition.
    func reloadTexture(from imageURL: URL, preparedTexture: UIImage? = nil) {
        guard let material = sphereNode?.geometry?.firstMaterial else {
            configure(imageURL: imageURL, preparedTexture: preparedTexture)
            return
        }
        applyTexture(to: material, imageURL: imageURL, preparedTexture: preparedTexture)
        applyLookToCamera()
    }

    // MARK: - Asset placement

    func setEditModeActive(_ active: Bool) {
        let wasFrozen = isMotionFrozen
        freezeEditMode = active
        editModeActive = active
        if active, !wasFrozen {
            // Hold the visual look in base so spawn/drag use a stable composed pose.
            look.bakeMotionIntoBase()
            referenceAttitude = nil
        }
        if !active {
            oneFingerOwner = .none
            stopSmoothingAndDisplayLink()
            VRPlacedAssetNodeFactory.hideAllSelectionVisuals(in: placedAssetsRoot)
            selectionIndicatorNode = nil
            selectedPlacementRoot = nil
            selectedSpaceLinkID = nil
            endSpaceLinkDraggingIfNeeded()
        }
        refreshAllHitProxies(enabled: active)
        refreshSpaceLinkHitSizes()
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
            var placed = entry
            let supportY = entry.resolvedSupportY(floorY: floorY)
            placed.position.y = supportY
            let node = VRPlacedAssetNodeFactory.makeNode(
                entry: placed,
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

    /// Sync 공간 연결 billboards (sibling of placedAssetsRoot — never under assets).
    func syncSpaceLinks(
        _ links: [SpaceLink],
        selectedId: String?,
        pulseInView: Bool,
        targetNames: [String: String] = [:]
    ) {
        selectedSpaceLinkID = selectedId
        // Build 74: never tear down nodes mid-drag (would hitch / snap).
        if isSpaceLinkDragging {
            return
        }
        spaceLinkPoses = Dictionary(uniqueKeysWithValues: links.map {
            ($0.id, (yaw: $0.yawDeg, pitch: $0.pitchDeg, radius: $0.radius))
        })
        spaceLinksRoot.childNodes.forEach { $0.removeFromParentNode() }
        let showPulse = pulseInView && !editModeActive
        for link in links.prefix(SpaceLink.maxLinksPerSource) {
            let targetKey = link.targetSessionId ?? link.targetSpaceId
            let targetName = targetKey.flatMap { targetNames[$0] }
            let node = SpaceHotspotNodeFactory.makeNode(
                link: link,
                selected: editModeActive && link.id == selectedId,
                pulse: showPulse,
                targetSpaceName: targetName
            )
            spaceLinksRoot.addChildNode(node)
        }
        refreshSpaceLinkHitSizes()
        publishSelectedSpaceLinkScreenPoint()
    }

    private func refreshSpaceLinkHitSizes() {
        let cam = SIMD3(
            cameraWorldTransform.columns.3.x,
            cameraWorldTransform.columns.3.y,
            cameraWorldTransform.columns.3.z
        )
        let fov = Float(cameraNode?.camera?.fieldOfView ?? 70)
        let vh = Float(max(viewportSize.height, 1))
        for node in spaceLinksRoot.childNodes {
            let pos = SIMD3(node.position.x, node.position.y, node.position.z)
            let distance = max(simd_length(pos - cam), 0.5)
            SpaceHotspotNodeFactory.refreshHitSize(
                on: node,
                distance: distance,
                viewportHeight: vh,
                verticalFOVDegrees: fov
            )
        }
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
        // Preserve support height (Build 70) — do not snap Y to global floorY.
        let supportY = position.y
        node.position = SCNVector3(position.x, supportY, position.z)
        node.eulerAngles.y = rotationY
        // Root uniform scale — selection/proxy/shadow inherit. No geometry rebuild.
        node.scale = SCNVector3(scale, scale, scale)
    }

    /// Build 70: update support height without scene rebuild (slider hot path).
    func setPlacedAssetSupportY(id: String, supportY: Float) {
        guard let node = assetNode(id: id) else { return }
        node.position.y = supportY
        // Contact shadow is local child at y≈0.002 — follows root automatically.
    }

    func placedAssetSupportY(id: String) -> Float? {
        assetNode(id: id).map { $0.position.y }
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

    func hitTestSpaceLink(at point: CGPoint) -> String? {
        let hits = scnView.hitTest(point, options: [
            .searchMode: SCNHitTestSearchMode.closest.rawValue,
            .categoryBitMask: VRPlacedAssetCategory.spaceLink,
            .boundingBoxOnly: false,
        ])
        return hits.lazy.compactMap { SpaceHotspotNodeFactory.linkID(from: $0.node) }.first
    }

    /// Front-most among spaceLink vs asset; when both near, prefer spaceLink (smaller billboard).
    private func hitTestEditTarget(at point: CGPoint) -> EditOneFingerOwner {
        let linkMask = VRPlacedAssetCategory.spaceLink
        let assetMask = VRPlacedAssetCategory.asset | VRPlacedAssetCategory.interaction
        let combined = linkMask | assetMask
        let hits = scnView.hitTest(point, options: [
            .searchMode: SCNHitTestSearchMode.all.rawValue,
            .categoryBitMask: combined,
            .boundingBoxOnly: false,
        ])
        guard !hits.isEmpty else { return .cameraPan }

        var bestLink: (id: String, dist: Float)?
        var bestAsset: (id: String, dist: Float)?
        let cam = SIMD3(
            cameraWorldTransform.columns.3.x,
            cameraWorldTransform.columns.3.y,
            cameraWorldTransform.columns.3.z
        )
        for hit in hits {
            let wp = hit.worldCoordinates
            let dist = simd_length(SIMD3(wp.x, wp.y, wp.z) - cam)
            if hit.node.categoryBitMask & linkMask != 0,
               let id = SpaceHotspotNodeFactory.linkID(from: hit.node) {
                if bestLink == nil || dist < bestLink!.dist {
                    bestLink = (id, dist)
                }
            } else if let id = VRPlacedAssetNodeFactory.placedAssetID(from: hit.node) {
                if bestAsset == nil || dist < bestAsset!.dist {
                    bestAsset = (id, dist)
                }
            }
        }
        if let link = bestLink, let asset = bestAsset {
            // Prefer closer; within 15cm prefer spaceLink.
            if link.dist <= asset.dist + 0.15 {
                return .spaceLinkMove(linkId: link.id)
            }
            return .assetMove(placementId: asset.id)
        }
        if let link = bestLink {
            return .spaceLinkMove(linkId: link.id)
        }
        if let asset = bestAsset {
            return .assetMove(placementId: asset.id)
        }
        return .cameraPan
    }

    /// Current view center → equirect degrees.
    /// Build 75: composed look (applied to camera euler) is source of truth so stored
    /// yaw/pitch match `SpaceLinkMath.worldPosition` / camera −Z. Presentation ray is
    /// cross-checked in DEBUG only.
    func currentEquirectCenterDegrees() -> (yawDeg: Float, pitchDeg: Float) {
        applyLookToCamera()
        let fromLook = (look.finalYawDeg, look.finalPitchDeg)
        #if DEBUG
        let size = viewportSize
        let center = CGPoint(x: size.width * 0.5, y: size.height * 0.5)
        let fromRay = equirectDegreesAtScreenPoint(center)
        let dyaw = abs(VRSphereEquirectBridge.shortestDeltaDeg(from: fromRay.yawDeg, to: fromLook.0))
        if dyaw > 2 || abs(fromRay.pitchDeg - fromLook.1) > 2 {
            print(
                "[vr-spaceLink75] spawn look vs ray lookYaw=\(fromLook.0) lookPitch=\(fromLook.1) rayYaw=\(fromRay.yawDeg) rayPitch=\(fromRay.pitchDeg)"
            )
        }
        #endif
        return fromLook
    }

    // MARK: - Build 81 SpaceLink transition (rotate + FOV zoom + settle)

    func setSpaceLinkTransitionLocked(_ locked: Bool) {
        let wasFrozen = isMotionFrozen
        spaceLinkTransitionInteractionsLocked = locked
        freezeSpaceLinkTransition = locked
        if locked {
            // Bake current visual pose so animation starts from what the user sees.
            look.bakeAllIntoBase()
            referenceAttitude = nil
            applyLookToCamera()
        } else if wasFrozen, !isMotionFrozen {
            unfreezeBakeAndReanchor()
            if motionDesiredEnabled {
                SpaceLink82Timing.log("motionReanchor")
                startMotionIfPossible()
            }
        } else if !locked {
            look.bakeMotionIntoBase()
            referenceAttitude = nil
            applyLookToCamera()
            if motionDesiredEnabled {
                SpaceLink82Timing.log("motionReanchor")
                startMotionIfPossible()
            }
        }
    }

    /// Camera FOV only — used by SpaceLink transition animation. Does not mutate `userViewingFOV`.
    func applyPresentationFOV(_ fov: Double) {
        cameraNode?.camera?.fieldOfView = CGFloat(fov)
        refreshSpaceLinkHitSizes()
    }

    /// Idle user zoom source of truth + camera.
    func commitUserViewingFOV(_ fov: Double) {
        userViewingFOV = VRViewingFOVMath.clamp(fov)
        applyPresentationFOV(userViewingFOV)
    }

    func userViewingFOVDegrees() -> Double { userViewingFOV }

    /// Compatibility: presentation FOV write (transition / entry). Prefer `commitUserViewingFOV` for idle.
    func setFieldOfViewDegrees(_ fov: Double) {
        applyPresentationFOV(fov)
    }

    func currentFieldOfViewDegrees() -> Double {
        Double(cameraNode?.camera?.fieldOfView ?? CGFloat(userViewingFOV))
    }

    /// Light exit feedback on the tapped hotspot (scale up + fade).
    func pulseHotspotExit(id: String) {
        guard let root = spaceLinksRoot.childNodes.first(where: {
            SpaceHotspotNodeFactory.linkID(from: $0) == id
        }) else { return }
        let visual = root.childNode(withName: SpaceHotspotNodeFactory.visualName, recursively: false)
        SCNTransaction.begin()
        SCNTransaction.animationDuration = SpaceLinkTransitionMath.hotspotPulseDuration
        SCNTransaction.animationTimingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        visual?.scale = SCNVector3(1.15, 1.15, 1.15)
        root.opacity = 0
        SCNTransaction.commit()
    }

    /// Align camera toward hotspot (shortest yaw) and zoom FOV. No camera translation.
    func runAlignAndZoom(
        targetYawDeg: Float,
        targetPitchDeg: Float,
        targetFOV: Double,
        reduceMotion: Bool
    ) async {
        stopTransitionDisplayLink()
        look.bakeAllIntoBase()
        applyLookToCamera()

        let startYaw = look.finalYawDeg
        let startPitch = look.finalPitchDeg
        let yawDelta = SpaceLinkTransitionMath.cappedShortestYawDelta(from: startYaw, to: targetYawDeg)
        let endYaw = VRLookMath.normalizeYawDeg(startYaw + yawDelta)
        let endPitch = VRLookMath.clampPitchDeg(targetPitchDeg)
        let startFOV = currentFieldOfViewDegrees()

        if reduceMotion {
            look.baseLookYawDeg = endYaw
            look.baseLookPitchDeg = endPitch
            look.motionYawDeg = 0
            look.motionPitchDeg = 0
            look.touchYawOffsetDeg = 0
            look.touchPitchOffsetDeg = 0
            applyLookToCamera()
            // Keep FOV; zoom removed under Reduce Motion.
            return
        }

        transitionStartYaw = startYaw
        transitionStartPitch = startPitch
        transitionEndYaw = endYaw
        transitionEndPitch = endPitch
        transitionStartFOV = startFOV
        transitionEndFOV = targetFOV
        transitionAlignDuration = SpaceLinkTransitionMath.alignDuration(
            forYawDeltaDeg: yawDelta,
            reduceMotion: false
        )
        transitionZoomStartDelay = SpaceLinkTransitionMath.zoomStartDelay
        transitionZoomDuration = SpaceLinkTransitionMath.zoomDuration

        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            transitionCompletion = { cont.resume() }
            transitionAnimStart = CACurrentMediaTime()
            let link = CADisplayLink(target: self, selector: #selector(handleTransitionDisplayLink(_:)))
            link.add(to: .main, forMode: .common)
            transitionDisplayLink = link
        }
    }

    func animateFieldOfView(to target: Double, duration: TimeInterval, easeOut: Bool) async {
        stopFOVOnlyDisplayLink()
        let from = currentFieldOfViewDegrees()
        if duration <= 0.001 || abs(from - target) < 0.05 {
            applyPresentationFOV(target)
            return
        }
        fovOnlyFrom = from
        fovOnlyTo = target
        fovOnlyDuration = duration
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            fovOnlyCompletion = {
                _ = easeOut
                cont.resume()
            }
            fovOnlyStart = CACurrentMediaTime()
            let link = CADisplayLink(target: self, selector: #selector(handleFOVOnlyDisplayLink(_:)))
            link.add(to: .main, forMode: .common)
            fovOnlyDisplayLink = link
        }
    }

    /// Target load failure — restore presentation FOV to user zoom (not forced 70).
    func restoreAfterFailedSpaceLinkTransition() async {
        stopTransitionDisplayLink()
        stopFOVOnlyDisplayLink()
        await animateFieldOfView(
            to: userViewingFOV,
            duration: SpaceLinkTransitionMath.settleDuration,
            easeOut: true
        )
        setSpaceLinkTransitionLocked(false)
    }

    @objc private func handleTransitionDisplayLink(_ link: CADisplayLink) {
        let elapsed = CACurrentMediaTime() - transitionAnimStart
        let alignT = SpaceLinkTransitionMath.easeInOutCubic(elapsed / max(0.001, transitionAlignDuration))
        let yaw = transitionStartYaw
            + Float(alignT) * VRSphereEquirectBridge.shortestDeltaDeg(
                from: transitionStartYaw,
                to: transitionEndYaw
            )
        // Pitch is not circular — lerp directly after clamp ends.
        let pitch = transitionStartPitch + Float(alignT) * (transitionEndPitch - transitionStartPitch)
        look.baseLookYawDeg = VRLookMath.normalizeYawDeg(yaw)
        look.baseLookPitchDeg = VRLookMath.clampPitchDeg(pitch)
        look.motionYawDeg = 0
        look.motionPitchDeg = 0
        look.touchYawOffsetDeg = 0
        look.touchPitchOffsetDeg = 0
        applyLookToCamera()

        let zoomElapsed = elapsed - transitionZoomStartDelay
        if zoomElapsed > 0 {
            let zoomT = SpaceLinkTransitionMath.easeInOutCubic(zoomElapsed / max(0.001, transitionZoomDuration))
            let fov = transitionStartFOV + (transitionEndFOV - transitionStartFOV) * zoomT
            applyPresentationFOV(fov)
        }

        let alignDone = elapsed >= transitionAlignDuration
        let zoomDone = elapsed >= (transitionZoomStartDelay + transitionZoomDuration)
        if alignDone && zoomDone {
            look.baseLookYawDeg = transitionEndYaw
            look.baseLookPitchDeg = transitionEndPitch
            applyLookToCamera()
            applyPresentationFOV(transitionEndFOV)
            let completion = transitionCompletion
            transitionCompletion = nil
            stopTransitionDisplayLink()
            completion?()
        }
    }

    @objc private func handleFOVOnlyDisplayLink(_ link: CADisplayLink) {
        let elapsed = CACurrentMediaTime() - fovOnlyStart
        let t = SpaceLinkTransitionMath.easeOutCubic(elapsed / max(0.001, fovOnlyDuration))
        applyPresentationFOV(fovOnlyFrom + (fovOnlyTo - fovOnlyFrom) * t)
        if elapsed >= fovOnlyDuration {
            applyPresentationFOV(fovOnlyTo)
            let completion = fovOnlyCompletion
            fovOnlyCompletion = nil
            stopFOVOnlyDisplayLink()
            completion?()
        }
    }

    private func stopTransitionDisplayLink() {
        transitionDisplayLink?.invalidate()
        transitionDisplayLink = nil
        if let completion = transitionCompletion {
            transitionCompletion = nil
            completion()
        }
    }

    private func stopFOVOnlyDisplayLink() {
        fovOnlyDisplayLink?.invalidate()
        fovOnlyDisplayLink = nil
        if let completion = fovOnlyCompletion {
            fovOnlyCompletion = nil
            completion()
        }
    }

    /// Attach one hotspot immediately (visible before next SwiftUI sync).
    func upsertSpaceLinkNode(_ link: SpaceLink, selected: Bool) {
        spaceLinkPoses[link.id] = (link.yawDeg, link.pitchDeg, link.radius)
        if let existing = spaceLinksRoot.childNodes.first(where: {
            SpaceHotspotNodeFactory.linkID(from: $0) == link.id
        }) {
            existing.removeFromParentNode()
        }
        let node = SpaceHotspotNodeFactory.makeNode(
            link: link,
            selected: selected,
            pulse: false
        )
        spaceLinksRoot.addChildNode(node)
        if selected {
            selectedSpaceLinkID = link.id
            for other in spaceLinksRoot.childNodes {
                guard let id = SpaceHotspotNodeFactory.linkID(from: other), id != link.id else { continue }
                SpaceHotspotNodeFactory.applySelected(false, on: other)
            }
        }
        refreshSpaceLinkHitSizes()
        publishSelectedSpaceLinkScreenPoint()
        #if DEBUG
        let wp = SIMD3(node.position.x, node.position.y, node.position.z)
        let camT = cameraWorldTransform
        let forward4 = camT * SIMD4(0, 0, -1, 0)
        let forward = simd_normalize(SIMD3(forward4.x, forward4.y, forward4.z))
        let dir = simd_normalize(wp)
        let dot = simd_dot(forward, dir)
        let screen = projectNodeToScreen(node)
        print(
            "[vr-spaceLink75] upsert id=\(link.id) yaw=\(link.yawDeg) pitch=\(link.pitchDeg) wp=\(wp) lookDot=\(dot) screen=\(String(describing: screen)) children=\(spaceLinksRoot.childNodes.count)"
        )
        #endif
    }

    var isSpaceLinkDragInProgress: Bool { isSpaceLinkDragging }

    /// Screen point → world ray → equirect yaw/pitch (Build 76: SceneKit unproject).
    /// Uses `scnView.unprojectPoint` so vertical screen motion matches projected hotspot Y
    /// (VRFloorRay NDC Y disagreed with SceneKit camera projection for pitch).
    func equirectDegreesAtScreenPoint(_ point: CGPoint) -> (yawDeg: Float, pitchDeg: Float) {
        let near = scnView.unprojectPoint(SCNVector3(point.x, point.y, 0))
        let far = scnView.unprojectPoint(SCNVector3(point.x, point.y, 1))
        var dir = SIMD3(far.x - near.x, far.y - near.y, far.z - near.z)
        let len = simd_length(dir)
        if len < 1e-8 {
            // Fallback: presentation −Z
            let transform = cameraNode?.presentation.simdWorldTransform
                ?? cameraNode?.simdWorldTransform
                ?? matrix_identity_float4x4
            let f4 = transform * SIMD4(0, 0, -1, 0)
            dir = SIMD3(f4.x, f4.y, f4.z)
        } else {
            dir /= len
        }
        return SpaceLinkMath.equirectDegreesFromWorldDirection(dir)
    }

    // MARK: - Scene diagnostics (TestFlight export; read-only)

    struct SceneDiagnosticsSnapshot {
        struct HotspotNodeSnap {
            var id: String
            var worldPosition: [Float]
            var hitTestUV: SpaceSceneDiagnostics.UVHit?
        }

        struct PlacementNodeSnap {
            var id: String
            var worldPosition: [Float]
            var worldTransform: [Float]
            var localScale: [Float]
            var contentBaseScale: Float
        }

        var geometry: SpaceSceneDiagnostics.GeometryInfo
        var camera: SpaceSceneDiagnostics.CameraInfo
        var hotspots: [HotspotNodeSnap]
        var placements: [PlacementNodeSnap]
    }

    /// Read-only snapshot of the live SceneKit graph. Does not mutate scene or stores.
    func captureSceneDiagnosticsSnapshot() -> SceneDiagnosticsSnapshot {
        applyLookToCamera()

        let sphere = sphereNode
        let mat = sphere?.geometry?.firstMaterial
        let cull: String?
        switch mat?.cullMode {
        case .some(.front): cull = "front"
        case .some(.back): cull = "back"
        default: cull = mat == nil ? nil : "unknown"
        }
        let lighting: String?
        switch mat?.lightingModel {
        case .some(.constant): lighting = "constant"
        case .some(.physicallyBased): lighting = "physicallyBased"
        default: lighting = mat == nil ? nil : "other"
        }

        let contentsT = mat?.diffuse.contentsTransform ?? SCNMatrix4Identity
        let scale = sphere?.scale ?? SCNVector3(1, 1, 1)
        let worldT = sphere?.simdWorldTransform ?? matrix_identity_float4x4
        let radius = (sphere?.geometry as? SCNSphere)?.radius
        let segments = (sphere?.geometry as? SCNSphere)?.segmentCount

        let geometry = SpaceSceneDiagnostics.GeometryInfo(
            sphereGeometryType: sphere?.geometry.map { String(describing: type(of: $0)) } ?? "nil",
            sphereRadius: radius.map { Float($0) },
            sphereSegmentCount: segments,
            sphereLocalScale: [scale.x, scale.y, scale.z],
            sphereWorldTransform: SpaceSceneDiagnostics.matrix16(worldT),
            sphereParentName: sphere?.parent?.name,
            cullMode: cull,
            materialLightingModel: lighting,
            contentsTransform: SpaceSceneDiagnostics.scnMatrix16(contentsT),
            wrapS: wrapName(mat?.diffuse.wrapS),
            wrapT: wrapName(mat?.diffuse.wrapT),
            insideOutScaleConvention: [
                Quick360SphereCoordinateConvention.insideOutScale.x,
                Quick360SphereCoordinateConvention.insideOutScale.y,
                Quick360SphereCoordinateConvention.insideOutScale.z,
            ]
        )

        let cam = cameraNode
        let camT = cam?.presentation.simdWorldTransform ?? matrix_identity_float4x4
        let euler = cam?.presentation.eulerAngles ?? SCNVector3Zero
        let proj = cam?.camera.map { SpaceSceneDiagnostics.scnMatrix16($0.projectionTransform) }
        let camera = SpaceSceneDiagnostics.CameraInfo(
            worldTransform: SpaceSceneDiagnostics.matrix16(camT),
            eulerPitchYawRoll: [euler.x, euler.y, euler.z],
            lookFinalYawDeg: look.finalYawDeg,
            lookFinalPitchDeg: look.finalPitchDeg,
            fieldOfViewDeg: Float(cam?.camera?.fieldOfView ?? CGFloat(userViewingFOV)),
            zNear: cam?.camera.map { Float($0.zNear) },
            zFar: cam?.camera.map { Float($0.zFar) },
            viewportWidth: Float(viewportSize.width),
            viewportHeight: Float(viewportSize.height),
            projectionTransform: proj
        )

        var hotspotSnaps: [SceneDiagnosticsSnapshot.HotspotNodeSnap] = []
        for node in spaceLinksRoot.childNodes {
            guard let id = SpaceHotspotNodeFactory.linkID(from: node) else { continue }
            let wp = node.presentation.simdWorldPosition
            let pose = spaceLinkPoses[id]
            let dir: SIMD3<Float>
            if let pose {
                dir = SpaceLinkMath.lookDirection(yawDeg: pose.yaw, pitchDeg: pose.pitch)
            } else {
                let len = simd_length(wp)
                dir = len > 1e-6 ? wp / len : SIMD3(0, 0, -1)
            }
            let uv = hitTestPanoramaUV(along: dir)
            hotspotSnaps.append(
                .init(
                    id: id,
                    worldPosition: [wp.x, wp.y, wp.z],
                    hitTestUV: uv
                )
            )
        }

        var placementSnaps: [SceneDiagnosticsSnapshot.PlacementNodeSnap] = []
        for node in placedAssetsRoot.childNodes {
            guard let id = VRPlacedAssetNodeFactory.placedAssetID(from: node) else { continue }
            let wp = node.presentation.simdWorldPosition
            let sc = node.presentation.scale
            placementSnaps.append(
                .init(
                    id: id,
                    worldPosition: [wp.x, wp.y, wp.z],
                    worldTransform: SpaceSceneDiagnostics.matrix16(node.presentation.simdWorldTransform),
                    localScale: [sc.x, sc.y, sc.z],
                    contentBaseScale: VRPlacedAssetNodeFactory.contentBaseScale(of: node)
                )
            )
        }

        return SceneDiagnosticsSnapshot(
            geometry: geometry,
            camera: camera,
            hotspots: hotspotSnaps,
            placements: placementSnaps
        )
    }

    /// Ray from origin along `direction` against the panorama sphere → texture UV + equirect.
    func hitTestPanoramaUV(along direction: SIMD3<Float>) -> SpaceSceneDiagnostics.UVHit? {
        guard let sphere = sphereNode else { return nil }
        var dir = direction
        let len = simd_length(dir)
        guard len > 1e-8 else { return nil }
        dir /= len
        let to = SCNVector3(dir.x * 50, dir.y * 50, dir.z * 50)
        let hits = sphere.hitTestWithSegment(from: SCNVector3Zero, to: to, options: nil)
        guard let hit = hits.first else { return nil }
        let uv = hit.textureCoordinates(withMappingChannel: 0)
        let eq = VRSphereEquirectBridge.equirectDegreesFromTextureUV(
            u: Float(uv.x),
            v: Float(uv.y)
        )
        return SpaceSceneDiagnostics.UVHit(
            u: Float(uv.x),
            v: Float(uv.y),
            equirectYawDeg: eq.yawDeg,
            equirectPitchDeg: eq.pitchDeg,
            hitNodeName: hit.node.name
        )
    }

    private func wrapName(_ mode: SCNWrapMode?) -> String? {
        guard let mode else { return nil }
        switch mode {
        case .clamp: return "clamp"
        case .repeat: return "repeat"
        case .clampToBorder: return "clampToBorder"
        case .mirror: return "mirror"
        @unknown default: return "unknown"
        }
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
        assetCount: Int,
        directionalActive: Bool,
        contactOpacity: Float,
        floorY: Float
    ) {
        (
            lightingExperiment.mode,
            lightingExperiment.iblIntensity,
            lightingExperiment.latestEstimate,
            placedAssetsRoot.childNodes.count,
            lightingExperiment.isDirectionalActive,
            lightingExperiment.appliedContactOpacity,
            placementFloorY
        )
    }

    private func applyLightingExperimentIfNeeded(force: Bool) {
        guard scnView.scene != nil else { return }
        let urlPath = lightingPanoramaURL?.path ?? ""
        let key = "\(lightingMode.rawValue)|\(lightingIBLIntensity)|\(urlPath)|\(placementFloorY)"
        guard force || key != lastLightingApplyKey else { return }
        lastLightingApplyKey = key
        lightingExperiment.setFloorY(placementFloorY)
        let prepared = lightingPanoramaURL.flatMap {
            SpaceLinkPanoramaTextureCache.shared.cachedImage(for: $0)
        }
        let t0 = CFAbsoluteTimeGetCurrent()
        lightingExperiment.apply(
            mode: lightingMode,
            iblIntensity: lightingIBLIntensity,
            panoramaURL: lightingPanoramaURL,
            preparedPanorama: prepared,
            forceReestimate: force
        )
        SpaceLink82Timing.log("lightingApply", [
            "ms": SpaceLink82Timing.ms(since: t0),
            "cache": prepared != nil ? "hit" : "miss"
        ])
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

    private func applyTexture(
        to material: SCNMaterial,
        imageURL: URL,
        preparedTexture: UIImage? = nil
    ) {
        let t0 = CFAbsoluteTimeGetCurrent()
        let prepared = preparedTexture
            ?? SpaceLinkPanoramaTextureCache.shared.cachedImage(for: imageURL)
        if let prepared {
            material.diffuse.contents = prepared
            SpaceLink82Timing.log("textureContents", [
                "ms": SpaceLink82Timing.ms(since: t0),
                "source": "predecoded"
            ])
            return
        }
        // Fallback: may decode on calling thread (prefer predecode path).
        SpaceLink82Timing.log("textureDecodeFallback", ["thread": "caller"])
        let raw = UIImage(contentsOfFile: imageURL.path)
        if let raw,
           let ready = Quick360SphereCoordinateConvention.prepareEquirectTextureForInsideOut(uiImage: raw) {
            SpaceLinkPanoramaTextureCache.shared.store(ready, for: imageURL)
            material.diffuse.contents = ready
        } else if let raw, raw.cgImage != nil {
            SpaceLinkPanoramaTextureCache.shared.store(raw, for: imageURL)
            material.diffuse.contents = raw
        } else {
            material.diffuse.contents = UIColor(white: 0.12, alpha: 1)
        }
        SpaceLink82Timing.log("textureContents", [
            "ms": SpaceLink82Timing.ms(since: t0),
            "source": "file"
        ])
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
        publishSelectedSpaceLinkScreenPoint()
    }

    func screenPointForSpaceLink(id: String) -> CGPoint? {
        guard let node = spaceLinksRoot.childNodes.first(where: {
            SpaceHotspotNodeFactory.linkID(from: $0) == id
        }) else { return nil }
        return projectNodeToScreen(node)
    }

    private func publishSelectedSpaceLinkScreenPoint() {
        guard editModeActive, let id = selectedSpaceLinkID else {
            onSpaceLinkScreenPoint?(nil)
            return
        }
        onSpaceLinkScreenPoint?(screenPointForSpaceLink(id: id))
    }

    private func projectNodeToScreen(_ node: SCNNode) -> CGPoint? {
        let wp = node.presentation.worldPosition
        let projected = scnView.projectPoint(wp)
        // Behind camera or invalid
        guard projected.z.isFinite, projected.z > 0, projected.z < 1 else { return nil }
        let pt = CGPoint(x: CGFloat(projected.x), y: CGFloat(projected.y))
        let bounds = scnView.bounds
        guard bounds.contains(pt) || bounds.insetBy(dx: -40, dy: -40).contains(pt) else {
            return pt // still return for edge clamping in SwiftUI
        }
        return pt
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
        if gestureRecognizer is UIPinchGestureRecognizer {
            if spaceLinkTransitionInteractionsLocked { return false }
            if editModeActive {
                return selectedPlacementID != nil
            }
            return true
        }
        guard editModeActive, gestureRecognizer is UIPanGestureRecognizer else { return true }
        // While a two-finger transform is active, block one-finger pan ownership flips.
        if pinchGestureActive || rotationGestureActive { return false }
        return true
    }

    @objc private func handlePan(_ g: UIPanGestureRecognizer) {
        if spaceLinkTransitionInteractionsLocked || viewPinchActive { return }
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
        guard gesture.state == .ended else { return }
        if spaceLinkTransitionInteractionsLocked || viewPinchActive { return }
        let location = gesture.location(in: scnView)
        if editModeActive {
            // Don't steal selection mid-drag.
            if case .assetMove = oneFingerOwner { return }
            if case .spaceLinkMove = oneFingerOwner { return }
            switch hitTestEditTarget(at: location) {
            case .spaceLinkMove(let id):
                selectAsset(id: nil)
                onPlacedAssetTapped?(nil)
                selectedSpaceLinkID = id
                onSpaceLinkTapped?(id)
            case .assetMove(let id):
                selectedSpaceLinkID = nil
                onSpaceLinkTapped?(nil)
                selectAsset(id: id)
                onPlacedAssetTapped?(id)
            case .cameraPan, .none:
                selectedSpaceLinkID = nil
                onSpaceLinkTapped?(nil)
                selectAsset(id: nil)
                onPlacedAssetTapped?(nil)
            }
            #if DEBUG
            print("[vr-place72] tap edit select link=\(selectedSpaceLinkID ?? "nil") asset=\(selectedPlacementID ?? "nil")")
            #endif
            return
        }
        // View: spaceLink tap → navigate
        if let linkId = hitTestSpaceLink(at: location) {
            onSpaceLinkTapped?(linkId)
            #if DEBUG
            print("[vr-spaceLink72] view tap link=\(linkId)")
            #endif
        }
    }

    @objc private func handlePinch(_ gesture: UIPinchGestureRecognizer) {
        guard !spaceLinkTransitionInteractionsLocked else { return }
        if editModeActive {
            handleEditAssetPinch(gesture)
            return
        }
        handleViewFOVPinch(gesture)
    }

    /// View mode: two-finger pinch → camera FOV zoom (direct SceneKit update).
    private func handleViewFOVPinch(_ gesture: UIPinchGestureRecognizer) {
        switch gesture.state {
        case .began:
            viewPinchActive = true
            pinchStartUserFOV = userViewingFOV
            #if DEBUG
            didLogViewPinchChanged = false
            print("[vrZoom83] began FOV=\(String(format: "%.1f", pinchStartUserFOV))")
            #endif
        case .changed:
            let live = VRViewingFOVMath.fov(startFOV: pinchStartUserFOV, pinchScale: gesture.scale)
            userViewingFOV = live
            applyPresentationFOV(live)
            #if DEBUG
            if !didLogViewPinchChanged {
                didLogViewPinchChanged = true
                print(
                    "[vrZoom83] changed scale=\(String(format: "%.3f", Double(gesture.scale))) liveFOV=\(String(format: "%.1f", live))"
                )
            }
            #endif
        case .ended, .cancelled, .failed:
            let finalFOV = VRViewingFOVMath.fov(startFOV: pinchStartUserFOV, pinchScale: gesture.scale)
            commitUserViewingFOV(finalFOV)
            viewPinchActive = false
            #if DEBUG
            print("[vrZoom83] ended FOV=\(String(format: "%.1f", userViewingFOV))")
            didLogViewPinchChanged = false
            #endif
        default:
            break
        }
    }

    /// Edit mode: selected asset uniform scale (Build 67).
    private func handleEditAssetPinch(_ gesture: UIPinchGestureRecognizer) {
        guard let id = selectedPlacementID, let node = assetNode(id: id) else { return }
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
        guard !spaceLinkTransitionInteractionsLocked else { return }
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
        guard !spaceLinkTransitionInteractionsLocked else { return }
        let location = gesture.location(in: scnView)
        switch gesture.state {
        case .began:
            // Lock owner once — never re-hitTest on changed (Build 67 small-asset fix).
            let owner = hitTestEditTarget(at: location)
            switch owner {
            case .spaceLinkMove(let linkId):
                oneFingerOwner = .spaceLinkMove(linkId: linkId)
                selectAsset(id: nil)
                onPlacedAssetTapped?(nil)
                selectedSpaceLinkID = linkId
                onSpaceLinkTapped?(linkId)
                beginSpaceLinkMove(linkId: linkId, screenPoint: location)
                #if DEBUG
                print("[vr-spaceLink74] owner=spaceLinkMove id=\(linkId)")
                #endif
            case .assetMove(let hitId):
                endSpaceLinkDraggingIfNeeded()
                oneFingerOwner = .assetMove(placementId: hitId)
                selectedSpaceLinkID = nil
                onSpaceLinkTapped?(nil)
                selectedPlacementID = hitId
                selectAsset(id: hitId)
                onPlacedAssetTapped?(hitId)
                beginMove(id: hitId, screenPoint: location)
                #if DEBUG
                print("[vr-place67] owner=assetMove id=\(hitId)")
                #endif
            case .cameraPan, .none:
                endSpaceLinkDraggingIfNeeded()
                oneFingerOwner = .cameraPan
                gesture.setTranslation(.zero, in: scnView)
                #if DEBUG
                print("[vr-place67] owner=cameraPan")
                #endif
            }
        case .changed:
            switch oneFingerOwner {
            case .spaceLinkMove(let id):
                continueSpaceLinkMove(linkId: id, screenPoint: location)
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
            switch oneFingerOwner {
            case .spaceLinkMove(let id):
                if let pose = spaceLinkPoses[id] {
                    // Single commit to SwiftUI + optional PATCH.
                    onSpaceLinkDragEnded?(id, pose.yaw, pose.pitch, pose.radius)
                }
                endSpaceLinkDraggingIfNeeded()
                publishSelectedSpaceLinkScreenPoint()
                #if DEBUG
                print("[vr-spaceLink74] move end id=\(id)")
                #endif
            case .assetMove(let id):
                publishTransform(for: id)
                #if DEBUG
                print("[vr-place67] move end id=\(id)")
                #endif
            default:
                break
            }
            oneFingerOwner = .none
            lastValidFloorHit = nil
            spaceLinkPoseAtDragBegan = nil
        default:
            break
        }
    }

    private func beginSpaceLinkMove(linkId: String, screenPoint: CGPoint) {
        guard let pose = spaceLinkPoses[linkId] else { return }
        spaceLinkPoseAtDragBegan = pose
        let finger = equirectDegreesAtScreenPoint(screenPoint)
        spaceLinkGrabYawOffsetDeg = VRSphereEquirectBridge.shortestDeltaDeg(
            from: finger.yawDeg,
            to: pose.yaw
        )
        spaceLinkGrabPitchOffsetDeg = pose.pitch - finger.pitchDeg
        #if DEBUG
        spaceLinkDragDebugLogged = false
        #endif
        // Yellow selection without full sync (sync is skipped while dragging).
        for node in spaceLinksRoot.childNodes {
            guard let id = SpaceHotspotNodeFactory.linkID(from: node) else { continue }
            SpaceHotspotNodeFactory.applySelected(id == linkId, on: node)
        }
        if !isSpaceLinkDragging {
            isSpaceLinkDragging = true
            onSpaceLinkDraggingChanged?(true)
            onSpaceLinkScreenPoint?(nil) // hide floating actions during drag
        }
    }

    private func continueSpaceLinkMove(linkId: String, screenPoint: CGPoint) {
        guard var pose = spaceLinkPoses[linkId] else { return }
        #if DEBUG
        let near = scnView.unprojectPoint(SCNVector3(screenPoint.x, screenPoint.y, 0))
        let far = scnView.unprojectPoint(SCNVector3(screenPoint.x, screenPoint.y, 1))
        var rayDir = SIMD3(far.x - near.x, far.y - near.y, far.z - near.z)
        let rayLen = simd_length(rayDir)
        if rayLen > 1e-8 { rayDir /= rayLen }
        #endif
        let finger = equirectDegreesAtScreenPoint(screenPoint)
        pose.yaw = VRSphereEquirectBridge.normalizeYawDeg(finger.yawDeg + spaceLinkGrabYawOffsetDeg)
        pose.pitch = max(-89, min(89, finger.pitchDeg + spaceLinkGrabPitchOffsetDeg))
        spaceLinkPoses[linkId] = pose
        if let node = spaceLinksRoot.childNodes.first(where: {
            SpaceHotspotNodeFactory.linkID(from: $0) == linkId
        }) {
            SpaceHotspotNodeFactory.applyPose(
                on: node,
                yawDeg: pose.yaw,
                pitchDeg: pose.pitch,
                radius: pose.radius
            )
            SpaceHotspotNodeFactory.refreshHitSize(
                on: node,
                distance: max(simd_length(SIMD3(node.position.x, node.position.y, node.position.z)), 0.5),
                viewportHeight: Float(max(viewportSize.height, 1)),
                verticalFOVDegrees: Float(cameraNode?.camera?.fieldOfView ?? 70)
            )
            #if DEBUG
            if !spaceLinkDragDebugLogged {
                spaceLinkDragDebugLogged = true
                let rebuilt = SpaceLinkMath.lookDirection(yawDeg: pose.yaw, pitchDeg: pose.pitch)
                let wp = node.worldPosition
                let proj = scnView.projectPoint(wp)
                print(
                    "[spaceLink77] dragTrace finger=(\(screenPoint.x),\(screenPoint.y)) near=(\(near.x),\(near.y),\(near.z)) far=(\(far.x),\(far.y),\(far.z)) ray=(\(rayDir.x),\(rayDir.y),\(rayDir.z)) fingerYaw=\(finger.yawDeg) fingerPitch=\(finger.pitchDeg) grabPitch=\(spaceLinkGrabPitchOffsetDeg) storedPitch=\(pose.pitch) rebuiltY=\(rebuilt.y) wp=(\(wp.x),\(wp.y),\(wp.z)) proj=(\(proj.x),\(proj.y))"
                )
            }
            #endif
        }
        // Build 74: no per-frame SwiftUI pose publish (node-only).
    }

    private func endSpaceLinkDraggingIfNeeded() {
        guard isSpaceLinkDragging else { return }
        isSpaceLinkDragging = false
        onSpaceLinkDraggingChanged?(false)
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
        let supportY = node.position.y
        let origin = SIMD3(
            cameraWorldTransform.columns.3.x,
            supportY,
            cameraWorldTransform.columns.3.z
        )
        let clamped = VRFloorRay.clampDistance(
            SIMD3(x, supportY, z),
            origin: origin,
            floorY: supportY
        )
        node.position = SCNVector3(clamped.x, supportY, clamped.z)
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
            SIMD3(node.position.x, node.position.y, node.position.z),
            node.eulerAngles.y,
            scale
        )
    }

    @objc private func handleLongPress(_ g: UILongPressGestureRecognizer) {
        if spaceLinkTransitionInteractionsLocked || viewPinchActive { return }
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
