import ARKit
import RealityKit
import SwiftUI

/// Minimal AR view for Quick 360 — no LiDAR wireframe or CoverageModel overlay.
///
/// Critical: `automaticallyConfigureSession` must be `false` **before** assigning a custom
/// `ARSession`. Default `ARView(frame:)` uses `true`, which races with an already-running
/// session from the view model and can terminate the process on entry (non-LiDAR devices).
struct Quick360ARViewRepresentable: UIViewRepresentable {
    let session: ARSession
    var onFrame: (ARFrame) -> Void
    var onViewReady: () -> Void

    func makeUIView(context: Context) -> ARView {
        Quick360Log.stage("ARView create start")
        let view = ARView(
            frame: .zero,
            cameraMode: .ar,
            automaticallyConfigureSession: false
        )
        Quick360Log.stage("ARView created (automaticallyConfigureSession=false)")

        context.coordinator.onFrame = onFrame
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
        context.coordinator.onFrame = onFrame
        context.coordinator.onViewReady = onViewReady
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator: NSObject, ARSessionDelegate {
        var onFrame: ((ARFrame) -> Void)?
        var onViewReady: (() -> Void)?

        func session(_ session: ARSession, didUpdate frame: ARFrame) {
            // ARKit delivers frames off the main queue; hop for @MainActor view model.
            if Thread.isMainThread {
                onFrame?(frame)
            } else {
                DispatchQueue.main.async { [onFrame] in
                    onFrame?(frame)
                }
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
