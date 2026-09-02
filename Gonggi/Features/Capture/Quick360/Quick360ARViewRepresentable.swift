import ARKit
import SwiftUI

/// Minimal AR view for Quick 360 — no LiDAR wireframe or CoverageModel overlay.
struct Quick360ARViewRepresentable: UIViewRepresentable {
    let session: ARSession
    var onFrame: (ARFrame) -> Void

    func makeUIView(context: Context) -> ARView {
        let view = ARView(frame: .zero)
        view.session = session
        view.automaticallyConfigureSession = false
        session.delegate = context.coordinator
        view.renderOptions = [.disablePersonOcclusion, .disableMotionBlur]
        return view
    }

    func updateUIView(_ uiView: ARView, context: Context) {
        context.coordinator.onFrame = onFrame
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator: NSObject, ARSessionDelegate {
        var onFrame: ((ARFrame) -> Void)?

        func session(_ session: ARSession, didUpdate frame: ARFrame) {
            onFrame?(frame)
        }
    }
}
