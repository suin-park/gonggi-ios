import ARKit
import RealityKit
import SwiftUI

/// AR camera + LiDAR mesh wireframe coverage overlay. Forwards full frames for recording + telemetry.
struct ARCaptureViewRepresentable: UIViewRepresentable {
    let session: ARSession
    let coverageSpatialIndex: CoverageSpatialIndex
    var showMeshOverlay: Bool
    /// Fired once the ARView is in a window with a non-zero bounds (safe time to `ARSession.run`).
    var onViewReady: (() -> Void)? = nil
    var onFrame: (ARFrame) -> Void

    func makeUIView(context: Context) -> GonggiCaptureARView {
        let view = GonggiCaptureARView(frame: .zero)
        view.session = session
        view.automaticallyConfigureSession = false
        session.delegate = context.coordinator
        view.environment.sceneUnderstanding.options = [.occlusion, .physics]
        view.renderOptions = [.disablePersonOcclusion, .disableMotionBlur]
        context.coordinator.arView = view
        context.coordinator.coverageSpatialIndex = coverageSpatialIndex
        context.coordinator.onFrame = onFrame
        context.coordinator.onViewReady = onViewReady
        context.coordinator.meshOverlaySupported = CaptureDeviceCapabilities.supportsLiDARMeshReconstruction
        context.coordinator.showMeshOverlay = showMeshOverlay
        context.coordinator.installCoachingOverlay(on: view)
        let coordinator = context.coordinator
        view.onAttachedToWindow = { [weak coordinator] in
            coordinator?.notifyViewReadyIfNeeded()
        }
        return view
    }

    func updateUIView(_ uiView: GonggiCaptureARView, context: Context) {
        context.coordinator.onFrame = onFrame
        context.coordinator.onViewReady = onViewReady
        context.coordinator.coverageSpatialIndex = coverageSpatialIndex
        context.coordinator.showMeshOverlay = showMeshOverlay
        let coordinator = context.coordinator
        uiView.onAttachedToWindow = { [weak coordinator] in
            coordinator?.notifyViewReadyIfNeeded()
        }
        if !context.coordinator.meshOverlaySupported || !showMeshOverlay {
            context.coordinator.clearWireframes()
        }
        // Cover presentation can attach the window after makeUIView — re-check.
        if uiView.window != nil {
            context.coordinator.notifyViewReadyIfNeeded()
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator: NSObject, ARSessionDelegate {
        weak var arView: ARView?
        var coverageSpatialIndex: CoverageSpatialIndex?
        var onFrame: ((ARFrame) -> Void)?
        var onViewReady: (() -> Void)?
        var showMeshOverlay = true
        var meshOverlaySupported = false
        private var didNotifyViewReady = false

        private var wireframeAnchors: [UUID: AnchorEntity] = [:]
        private var lastMeshUpdate: TimeInterval = 0
        private let meshUpdateInterval: TimeInterval = 0.12

        func notifyViewReadyIfNeeded() {
            guard !didNotifyViewReady else { return }
            guard let arView, arView.window != nil, arView.bounds.width > 1, arView.bounds.height > 1 else {
                return
            }
            didNotifyViewReady = true
            onViewReady?()
        }

        func installCoachingOverlay(on view: ARView) {
            let coaching = ARCoachingOverlayView()
            coaching.goal = .horizontalPlane
            coaching.session = view.session
            coaching.activatesAutomatically = true
            coaching.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(coaching)
            NSLayoutConstraint.activate([
                coaching.topAnchor.constraint(equalTo: view.topAnchor),
                coaching.bottomAnchor.constraint(equalTo: view.bottomAnchor),
                coaching.leadingAnchor.constraint(equalTo: view.leadingAnchor),
                coaching.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            ])
        }

        func session(_ session: ARSession, didUpdate frame: ARFrame) {
            onFrame?(frame)
            updateMeshVisualization(frame: frame)
        }

        func clearWireframes() {
            guard let arView else { return }
            for id in wireframeAnchors.keys {
                removeWireframe(id: id, from: arView)
            }
        }

        private func updateMeshVisualization(frame: ARFrame) {
            guard let arView, meshOverlaySupported, showMeshOverlay, let coverageSpatialIndex else {
                clearWireframes()
                return
            }

            let now = frame.timestamp
            guard now - lastMeshUpdate >= meshUpdateInterval else { return }
            lastMeshUpdate = now

            let meshAnchors = frame.anchors.compactMap { $0 as? ARMeshAnchor }
            var activeIds = Set<UUID>()

            for anchor in meshAnchors {
                activeIds.insert(anchor.identifier)
                updateWireframe(for: anchor, coverageSpatialIndex: coverageSpatialIndex, in: arView)
            }

            for id in wireframeAnchors.keys where !activeIds.contains(id) {
                removeWireframe(id: id, from: arView)
            }
        }

        private func updateWireframe(
            for anchor: ARMeshAnchor,
            coverageSpatialIndex: CoverageSpatialIndex,
            in arView: ARView
        ) {
            guard let meshes = ARMeshWireframeBuilder.wireframeMeshes(
                from: anchor.geometry,
                anchorTransform: anchor.transform,
                coverageStateAt: { coverageSpatialIndex.state(at: $0) }
            ) else { return }

            let needsEntity: ModelEntity
            let capturedEntity: ModelEntity

            if let anchorEntity = wireframeAnchors[anchor.identifier],
               let existingNeeds = anchorEntity.children.first(where: { $0.name.hasPrefix("gonggi-wireframe-needs-") }) as? ModelEntity,
               let existingCaptured = anchorEntity.children.first(where: { $0.name.hasPrefix("gonggi-wireframe-captured-") }) as? ModelEntity {
                needsEntity = existingNeeds
                capturedEntity = existingCaptured
            } else {
                needsEntity = ModelEntity()
                needsEntity.name = "gonggi-wireframe-needs-\(anchor.identifier.uuidString)"
                capturedEntity = ModelEntity()
                capturedEntity.name = "gonggi-wireframe-captured-\(anchor.identifier.uuidString)"

                let anchorEntity = AnchorEntity(.anchor(identifier: anchor.identifier))
                anchorEntity.addChild(needsEntity)
                anchorEntity.addChild(capturedEntity)
                arView.scene.addAnchor(anchorEntity)
                wireframeAnchors[anchor.identifier] = anchorEntity
            }

            applyLineMesh(meshes.needsCapture, to: needsEntity, material: CoverageMeshMaterials.needsCaptureMaterial())
            applyLineMesh(meshes.captured, to: capturedEntity, material: CoverageMeshMaterials.capturedMaterial())
        }

        private func applyLineMesh(_ lineMesh: ARMeshWireframeBuilder.LineMesh, to entity: ModelEntity, material: SimpleMaterial) {
            guard let meshResource = ARMeshWireframeBuilder.meshResource(from: lineMesh) else {
                entity.model = nil
                return
            }
            entity.model = ModelComponent(mesh: meshResource, materials: [material])
        }

        private func removeWireframe(id: UUID, from arView: ARView) {
            guard let anchorEntity = wireframeAnchors.removeValue(forKey: id) else { return }
            arView.scene.removeAnchor(anchorEntity)
        }
    }
}

/// Notifies when attached to a window so we can start `ARSession` after layout.
final class GonggiCaptureARView: ARView {
    var onAttachedToWindow: (() -> Void)?

    override func didMoveToWindow() {
        super.didMoveToWindow()
        guard window != nil else { return }
        DispatchQueue.main.async { [weak self] in
            self?.onAttachedToWindow?()
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        if window != nil, bounds.width > 1, bounds.height > 1 {
            onAttachedToWindow?()
        }
    }
}
