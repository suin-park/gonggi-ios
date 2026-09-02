import ARKit
import RealityKit
import SwiftUI

/// Minimal AR view for Quick 360 — no LiDAR wireframe or CoverageModel overlay.
///
/// Critical lifecycle rules:
/// 1. `automaticallyConfigureSession` must be `false` **before** assigning a custom `ARSession`.
/// 2. Never hop `ARFrame` / `CVPixelBuffer` to another queue — copy owned pixels first
///    (Build 3 EXC_BAD_ACCESS: `_sessionDidUpdateFrame` → main queue → stale buffer).
struct Quick360ARViewRepresentable: UIViewRepresentable {
    let session: ARSession
    let engine: Quick360CaptureEngine
    var onPayload: (Quick360FramePayload) -> Void
    var onViewReady: () -> Void

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
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator: NSObject, ARSessionDelegate {
        var engine: Quick360CaptureEngine?
        var onPayload: ((Quick360FramePayload) -> Void)?
        var onViewReady: (() -> Void)?

        func session(_ session: ARSession, didUpdate frame: ARFrame) {
            guard let engine, let onPayload else { return }
            // Owned copy while CVPixelBuffer is valid — do not capture `frame` into async.
            let payload = engine.makeOwnedPayload(from: frame)
            DispatchQueue.main.async {
                onPayload(payload)
            }
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
