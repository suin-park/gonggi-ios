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
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator: NSObject, ARSessionDelegate {
        var engine: Quick360CaptureEngine?
        var onPayload: ((Quick360FramePayload) -> Void)?
        var onViewReady: (() -> Void)?
        var showDebugFloorMarker = false
        private var hybrid = Quick360HybridSceneController()
        private var lastTexturePush: TimeInterval = 0

        func attachHybridScene(to view: ARView) {
            hybrid.attach(to: view)
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
                self.hybrid.syncFloor(from: engine, showDebugMarker: self.showDebugFloorMarker)
            }
        }

        private func pushTexturesIfNeeded(now: TimeInterval) {
            guard let engine else { return }
            guard now - lastTexturePush >= Quick360Config.liveBrushMinIntervalSec else { return }
            lastTexturePush = now
            hybrid.syncTextures(from: engine, showDebugMarker: showDebugFloorMarker)
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
        sphere.scale = SIMD3<Float>(-1, 1, 1)
        sphere.name = "hybridSphere"
        anchor.addChild(sphere)
        sphereEntity = sphere
    }

    func syncTextures(from engine: Quick360CaptureEngine, showDebugMarker: Bool) {
        let snap = engine.snapshotBrushCGImages()
        // Align sphere local frame with capture origin so relative yaw=0 → texture U≈0.5 in view.
        if let origin = snap.originTransform {
            sphereEntity?.transform.matrix = origin
            // Re-apply inside-out scale after setting full transform.
            sphereEntity?.scale = SIMD3<Float>(-1, 1, 1)
        }
        if let cg = snap.sphere,
           let display = Self.horizontallyMirrored(cg),
           let resource = try? TextureResource.generate(from: display, options: .init(semantic: .color)) {
            var mat = UnlitMaterial()
            mat.color = .init(tint: .white, texture: .init(resource))
            mat.blending = .opaque
            sphereEntity?.model?.materials = [mat]
            sphereMaterial = mat
        }
        syncFloor(surface: snap.floorSurface, floorCG: snap.floor, showDebugMarker: showDebugMarker)
    }

    /// Cancels UV mirror introduced by `scale.x = -1` without flipping sphere yaw math.
    private static func horizontallyMirrored(_ image: CGImage) -> CGImage? {
        let w = image.width
        let h = image.height
        guard let ctx = CGContext(
            data: nil,
            width: w,
            height: h,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        ctx.translateBy(x: CGFloat(w), y: 0)
        ctx.scaleBy(x: -1, y: 1)
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage()
    }

    func syncFloor(from engine: Quick360CaptureEngine, showDebugMarker: Bool) {
        let snap = engine.snapshotBrushCGImages()
        syncFloor(surface: snap.floorSurface, floorCG: snap.floor, showDebugMarker: showDebugMarker)
    }

    private func syncFloor(surface: CapturedFloorSurface?, floorCG: CGImage?, showDebugMarker: Bool) {
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

        if let cg = floorCG,
           let resource = try? TextureResource.generate(from: cg, options: .init(semantic: .color)) {
            var mat = UnlitMaterial()
            mat.color = .init(tint: .white, texture: .init(resource))
            mat.blending = .opaque
            floorEntity?.model?.materials = [mat]
            floorMaterial = mat
        }

        if showDebugMarker {
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
