import ARKit
import RealityKit
import SwiftUI

/// AR camera + mesh wireframe overlay. Forwards full frames for recording + telemetry.
struct ARCaptureViewRepresentable: UIViewRepresentable {
    let session: ARSession
    var onFrame: (ARFrame) -> Void

    func makeUIView(context: Context) -> ARView {
        let view = ARView(frame: .zero)
        view.session = session
        view.automaticallyConfigureSession = false
        session.delegate = context.coordinator
        view.environment.sceneUnderstanding.options = [.occlusion, .physics]
        view.renderOptions = [.disablePersonOcclusion, .disableMotionBlur]
        context.coordinator.arView = view
        context.coordinator.onFrame = onFrame
        context.coordinator.installCoachingOverlay(on: view)
        return view
    }

    func updateUIView(_ uiView: ARView, context: Context) {
        context.coordinator.onFrame = onFrame
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator: NSObject, ARSessionDelegate {
        weak var arView: ARView?
        var onFrame: ((ARFrame) -> Void)?
        private var meshAnchorIds = Set<UUID>()

        func installCoachingOverlay(on view: ARView) {
            let coaching = ARCoachingOverlayView()
            coaching.goal = .horizontalPlane
            coaching.session = view.session
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

        private func updateMeshVisualization(frame: ARFrame) {
            guard let arView else { return }
            let meshAnchors = frame.anchors.compactMap { $0 as? ARMeshAnchor }
            for anchor in meshAnchors {
                guard !meshAnchorIds.contains(anchor.identifier) else { continue }
                let meshResource = ARMeshGeometryBuilder.meshResource(from: anchor.geometry)
                guard let meshResource else { continue }
                meshAnchorIds.insert(anchor.identifier)
                var material = SimpleMaterial()
                material.color = .init(
                    tint: UIColor(GonggiColors.accentCyan).withAlphaComponent(0.15),
                    texture: nil
                )
                material.metallic = 0
                material.roughness = 1
                let model = ModelEntity(mesh: meshResource, materials: [material])
                model.name = anchor.identifier.uuidString
                let anchorEntity = AnchorEntity(.anchor(identifier: anchor.identifier))
                anchorEntity.addChild(model)
                arView.scene.addAnchor(anchorEntity)
            }
        }
    }
}
