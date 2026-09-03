import ARKit
import RealityKit
import SwiftUI
import UIKit

/// Minimal AR view for Hybrid Space Capture.
/// Keeps Build 4 lifetime contract: copy owned pixels before any queue hop.
struct Quick360ARViewRepresentable: UIViewRepresentable {
    let session: ARSession
    let engine: Quick360CaptureEngine
    var onPayload: (Quick360FramePayload) -> Void
    var onViewReady: () -> Void
    var showDebugFloorMarker: Bool
    /// Split debug gate: hide floor plane entity (detection/atlas still run in engine).
    var showFloorRenderer: Bool = true

    func makeUIView(context: Context) -> ARView {
        Quick360Log.stage("ARView create start")
        let view = ARView(
            frame: .zero,
            cameraMode: .ar,
            automaticallyConfigureSession: false
        )
        Quick360Log.stage("ARView created (automaticallyConfigureSession=false)")

        context.coordinator.engine = engine
        context.coordinator.onPayload = onPayload
        context.coordinator.onViewReady = onViewReady
        context.coordinator.showDebugFloorMarker = showDebugFloorMarker
        context.coordinator.showFloorRenderer = showFloorRenderer
        context.coordinator.attachHybridScene(to: view)

        view.session = session
        session.delegate = context.coordinator
        view.renderOptions = [.disablePersonOcclusion, .disableMotionBlur]
        Quick360Log.stage("ARView session assigned + delegate set")

        DispatchQueue.main.async {
            context.coordinator.onViewReady?()
        }
        return view
    }

    func updateUIView(_ uiView: ARView, context: Context) {
        context.coordinator.engine = engine
        context.coordinator.onPayload = onPayload
        context.coordinator.onViewReady = onViewReady
        context.coordinator.showDebugFloorMarker = showDebugFloorMarker
        context.coordinator.showFloorRenderer = showFloorRenderer
        context.coordinator.hybrid.setFloorRendererVisible(showFloorRenderer)
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator: NSObject, ARSessionDelegate {
        var engine: Quick360CaptureEngine?
        var onPayload: ((Quick360FramePayload) -> Void)?
        var onViewReady: (() -> Void)?
        var showDebugFloorMarker = false
        var showFloorRenderer = true
        fileprivate var hybrid = Quick360HybridSceneController()
        private var lastTexturePush: TimeInterval = 0

        func attachHybridScene(to view: ARView) {
            hybrid.attach(to: view)
            hybrid.setFloorRendererVisible(showFloorRenderer)
        }

        func session(_ session: ARSession, didUpdate frame: ARFrame) {
            guard let engine, let onPayload else { return }
            let payload = engine.makeOwnedPayload(from: frame)
            DispatchQueue.main.async {
                onPayload(payload)
                self.pushTexturesIfNeeded(now: frame.timestamp)
            }
        }

        func session(_ session: ARSession, didAdd anchors: [ARAnchor]) {
            handlePlanes(anchors)
        }

        func session(_ session: ARSession, didUpdate anchors: [ARAnchor]) {
            handlePlanes(anchors)
        }

        private func handlePlanes(_ anchors: [ARAnchor]) {
            guard let engine else { return }
            for anchor in anchors {
                guard let plane = anchor as? ARPlaneAnchor,
                      plane.alignment == .horizontal else { continue }
                let extent = simd_float3(plane.planeExtent.width, 0, plane.planeExtent.height)
                engine.ingestPlaneAnchor(
                    identifier: plane.identifier,
                    worldTransform: plane.transform,
                    extent: extent,
                    alignment: "horizontal"
                )
            }
            DispatchQueue.main.async {
                self.hybrid.syncFloor(
                    from: engine,
                    showDebugMarker: self.showDebugFloorMarker,
                    showFloorRenderer: self.showFloorRenderer
                )
            }
        }

        private func pushTexturesIfNeeded(now: TimeInterval) {
            guard let engine else { return }
            guard now - lastTexturePush >= Quick360Config.liveBrushMinIntervalSec else { return }
            lastTexturePush = now
            hybrid.syncTextures(
                from: engine,
                showDebugMarker: showDebugFloorMarker,
                showFloorRenderer: showFloorRenderer
            )
        }

        func session(_ session: ARSession, didFailWithError error: Error) {
            Quick360Log.stage("ARSession didFailWithError: \(error.localizedDescription)")
        }

        func sessionWasInterrupted(_ session: ARSession) {
            Quick360Log.stage("ARSession interrupted")
        }

        func sessionInterruptionEnded(_ session: ARSession) {
            Quick360Log.stage("ARSession interruption ended")
        }
    }
}

/// RealityKit inverted sphere + local floor plane for in-world coverage visualization.
final class Quick360HybridSceneController {
    private weak var arView: ARView?
    private var rootAnchor: AnchorEntity?
    private var sphereEntity: ModelEntity?
    private var floorEntity: ModelEntity?
    private var debugMarker: ModelEntity?
    private var sphereMaterial = UnlitMaterial(color: .gray)
    private var floorMaterial = UnlitMaterial(color: UIColor(white: 0.55, alpha: 1))

    func attach(to view: ARView) {
        arView = view
        let anchor = AnchorEntity(world: .zero)
        view.scene.addAnchor(anchor)
        rootAnchor = anchor

        // Inside-out via negative X (iOS 17–safe). Compensate horizontal mirror when applying texture.
        let sphere = ModelEntity(
            mesh: .generateSphere(radius: 8),
            materials: [sphereMaterial]
        )
        sphere.scale = Quick360SphereCoordinateConvention.insideOutScale
        sphere.name = "hybridSphere"
        anchor.addChild(sphere)
        sphereEntity = sphere
    }

    func syncTextures(
        from engine: Quick360CaptureEngine,
        showDebugMarker: Bool,
        showFloorRenderer: Bool = true
    ) {
        let snap = engine.snapshotBrushCGImages()
        // Align sphere local frame with capture origin so relative yaw=0 → texture U≈0.5 in view.
        if let origin = snap.originTransform {
            sphereEntity?.transform.matrix = origin
            // Re-apply inside-out scale after setting full transform.
            sphereEntity?.scale = Quick360SphereCoordinateConvention.insideOutScale
        }
        if let cg = snap.sphere,
           let display = Quick360SphereCoordinateConvention.prepareEquirectTextureForInsideOut(cg),
           let resource = try? TextureResource.generate(from: display, options: .init(semantic: .color)) {
            var mat = UnlitMaterial()
            mat.color = .init(tint: .white, texture: .init(resource))
            mat.blending = .opaque
            sphereEntity?.model?.materials = [mat]
            sphereMaterial = mat
        }
        syncFloor(
            surface: snap.floorSurface,
            floorCG: snap.floor,
            showDebugMarker: showDebugMarker,
            showFloorRenderer: showFloorRenderer
        )
    }

    func setFloorRendererVisible(_ visible: Bool) {
        floorEntity?.isEnabled = visible
        if !visible {
            debugMarker?.isEnabled = false
        }
    }

    func syncFloor(
        from engine: Quick360CaptureEngine,
        showDebugMarker: Bool,
        showFloorRenderer: Bool = true
    ) {
        let snap = engine.snapshotBrushCGImages()
        syncFloor(
            surface: snap.floorSurface,
            floorCG: snap.floor,
            showDebugMarker: showDebugMarker,
            showFloorRenderer: showFloorRenderer
        )
    }

    private func syncFloor(
        surface: CapturedFloorSurface?,
        floorCG: CGImage?,
        showDebugMarker: Bool,
        showFloorRenderer: Bool
    ) {
        guard let rootAnchor, let surface else { return }

        if floorEntity == nil {
            let mesh = MeshResource.generatePlane(
                width: surface.extent.x,
                depth: surface.extent.z
            )
            let entity = ModelEntity(mesh: mesh, materials: [floorMaterial])
            entity.name = "hybridFloor"
            entity.position = SIMD3(0, 0.01, 0)
            rootAnchor.addChild(entity)
            floorEntity = entity
        }

        floorEntity?.transform.matrix = surface.worldTransform
        let mesh = MeshResource.generatePlane(
            width: max(surface.extent.x, 0.5),
            depth: max(surface.extent.z, 0.5)
        )
        floorEntity?.model?.mesh = mesh
        floorEntity?.isEnabled = showFloorRenderer

        if let cg = floorCG,
           let resource = try? TextureResource.generate(from: cg, options: .init(semantic: .color)) {
            var mat = UnlitMaterial()
            mat.color = .init(tint: .white, texture: .init(resource))
            mat.blending = .opaque
            floorEntity?.model?.materials = [mat]
            floorMaterial = mat
        }

        if showFloorRenderer, showDebugMarker {
            if debugMarker == nil {
                let marker = ModelEntity(
                    mesh: .generateBox(size: 0.08),
                    materials: [SimpleMaterial(color: .cyan, isMetallic: false)]
                )
                marker.name = "floorDebugMarker"
                rootAnchor.addChild(marker)
                debugMarker = marker
            }
            var t = surface.worldTransform
            t.columns.3.y += 0.05
            debugMarker?.transform.matrix = t
            debugMarker?.isEnabled = true
        } else {
            debugMarker?.isEnabled = false
        }
    }
}
