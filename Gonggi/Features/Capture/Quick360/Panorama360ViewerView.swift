import SceneKit
import SwiftUI

/// Inside-out equirectangular 360° viewer (SceneKit).
struct Panorama360ViewerView: View {
    let imageURL: URL
    @Environment(\.dismiss) private var dismiss
    @State private var fieldOfView: CGFloat = 75

    var body: some View {
        NavigationStack {
            Panorama360SceneView(imageURL: imageURL, fieldOfView: $fieldOfView)
                .ignoresSafeArea()
                .navigationTitle("360° 공간 미리보기")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("닫기") { dismiss() }
                    }
                }
        }
    }
}

private struct Panorama360SceneView: UIViewRepresentable {
    let imageURL: URL
    @Binding var fieldOfView: CGFloat

    func makeUIView(context: Context) -> SCNView {
        let view = SCNView()
        view.backgroundColor = .black
        view.allowsCameraControl = false
        view.antialiasingMode = .multisampling4X

        let scene = SCNScene()
        let sphere = SCNSphere(radius: 10)
        sphere.segmentCount = 96

        let material = SCNMaterial()
        material.isDoubleSided = true
        // Raw equirect + insideOutScale only (same as live capture RealityKit).
        if let raw = UIImage(contentsOfFile: imageURL.path),
           let prepared = Quick360SphereCoordinateConvention.prepareEquirectTextureForInsideOut(uiImage: raw) {
            material.diffuse.contents = prepared
        } else {
            material.diffuse.contents = UIImage(contentsOfFile: imageURL.path)
        }
        material.diffuse.wrapS = .repeat
        material.diffuse.wrapT = .clamp
        sphere.firstMaterial = material
        sphere.firstMaterial?.cullMode = .front

        let sphereNode = SCNNode(geometry: sphere)
        let s = Quick360SphereCoordinateConvention.insideOutScale
        sphereNode.scale = SCNVector3(s.x, s.y, s.z)
        scene.rootNode.addChildNode(sphereNode)

        let cameraNode = SCNNode()
        cameraNode.camera = SCNCamera()
        cameraNode.camera?.fieldOfView = fieldOfView
        cameraNode.camera?.zNear = 0.1
        cameraNode.camera?.zFar = 100
        cameraNode.position = SCNVector3(0, 0, 0)
        scene.rootNode.addChildNode(cameraNode)

        view.scene = scene
        view.pointOfView = cameraNode

        let pan = UIPanGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handlePan(_:)))
        let pinch = UIPinchGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handlePinch(_:)))
        view.addGestureRecognizer(pan)
        view.addGestureRecognizer(pinch)

        context.coordinator.cameraNode = cameraNode
        context.coordinator.fieldOfViewBinding = $fieldOfView
        return view
    }

    func updateUIView(_ uiView: SCNView, context: Context) {
        context.coordinator.fieldOfViewBinding = $fieldOfView
        context.coordinator.cameraNode?.camera?.fieldOfView = fieldOfView
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator: NSObject {
        var cameraNode: SCNNode?
        var fieldOfViewBinding: Binding<CGFloat>?
        private var lastPan = CGPoint.zero

        @objc func handlePan(_ gesture: UIPanGestureRecognizer) {
            guard let view = gesture.view as? SCNView, let camera = cameraNode else { return }
            let translation = gesture.translation(in: view)
            if gesture.state == .began { lastPan = translation; return }
            let dx = Float(translation.x - lastPan.x) * 0.005
            let dy = Float(translation.y - lastPan.y) * 0.005
            lastPan = translation
            camera.eulerAngles.y -= dx
            camera.eulerAngles.x = max(-.pi / 3, min(.pi / 3, camera.eulerAngles.x - dy))
            if gesture.state == .ended { lastPan = .zero }
        }

        @objc func handlePinch(_ gesture: UIPinchGestureRecognizer) {
            guard let binding = fieldOfViewBinding else { return }
            if gesture.state == .changed {
                let newFOV = binding.wrappedValue / CGFloat(gesture.scale)
                binding.wrappedValue = min(100, max(40, newFOV))
                gesture.scale = 1
            }
        }
    }
}
