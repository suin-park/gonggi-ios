import SceneKit
import SwiftUI

/// Inside-out equirectangular 360° viewer (SceneKit).
/// Pitch ≈ ±89° so zenith/nadir are reachable without exact-pole singularity.
/// Engine-agnostic: displays `PanoramaEngineOutput.panoramaURL` (or any equirect JPEG) only —
/// does not know Legacy vs OpenCV.
struct Panorama360ViewerView: View {
    let imageURL: URL
    @Environment(\.dismiss) private var dismiss
    @State private var fieldOfView: CGFloat = 75
    @State private var loadFailed = false

    var body: some View {
        NavigationStack {
            Group {
                if loadFailed {
                    VStack(spacing: GonggiSpacing.md) {
                        Image(systemName: "exclamationmark.triangle")
                            .font(.system(size: 36, weight: .light))
                            .foregroundStyle(GonggiColors.accentTeal)
                        Text("미리보기를 불러오지 못했어요")
                            .font(GonggiTypography.body(17))
                            .foregroundStyle(GonggiColors.textPrimary)
                        Text("파노라마 파일이 없거나 손상되었을 수 있어요.")
                            .font(GonggiTypography.caption(13))
                            .foregroundStyle(GonggiColors.textSecondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, GonggiSpacing.lg)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.black)
                } else {
                    Panorama360SceneView(
                        imageURL: imageURL,
                        fieldOfView: $fieldOfView,
                        onLoadFailed: { loadFailed = true }
                    )
                    .ignoresSafeArea()
                }
            }
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
    var onLoadFailed: () -> Void

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
        let fileExists = FileManager.default.fileExists(atPath: imageURL.path)
        let raw = fileExists ? UIImage(contentsOfFile: imageURL.path) : nil
        if let raw,
           let prepared = Quick360SphereCoordinateConvention.prepareEquirectTextureForInsideOut(uiImage: raw) {
            material.diffuse.contents = prepared
        } else if let raw {
            material.diffuse.contents = raw
        } else {
            DispatchQueue.main.async { onLoadFailed() }
            material.diffuse.contents = UIColor.darkGray
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
        // Start facing capture forward (yaw/pitch 0) — no arbitrary offset.
        cameraNode.eulerAngles = SCNVector3(0, 0, 0)
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
        private let maxPitch = Quick360Config.viewerMaxPitchRad

        @objc func handlePan(_ gesture: UIPanGestureRecognizer) {
            guard let view = gesture.view as? SCNView, let camera = cameraNode else { return }
            let translation = gesture.translation(in: view)
            if gesture.state == .began { lastPan = translation; return }
            let dx = Float(translation.x - lastPan.x) * 0.005
            let dy = Float(translation.y - lastPan.y) * 0.005
            lastPan = translation
            camera.eulerAngles.y -= dx
            camera.eulerAngles.x = max(-maxPitch, min(maxPitch, camera.eulerAngles.x - dy))
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
