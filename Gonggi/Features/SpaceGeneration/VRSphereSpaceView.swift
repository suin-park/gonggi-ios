import SwiftUI

/// Full-screen VR entry using canonical Quick360 inside-out sphere (no LatLong flat preview).
struct VRSphereSpaceView: View {
    let imageURL: URL
    var onClose: () -> Void

    var body: some View {
        ZStack(alignment: .topLeading) {
            Panorama360SceneOnlyView(imageURL: imageURL)
                .ignoresSafeArea()

            Button {
                GonggiHaptics.light()
                onClose()
            } label: {
                Image(systemName: "chevron.backward")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 40, height: 40)
                    .background(Color.black.opacity(0.45))
                    .clipShape(Circle())
            }
            .padding(.leading, 16)
            .padding(.top, 12)
        }
        .statusBarHidden(true)
    }
}

/// SceneKit viewer without the “360° 공간 미리보기” chrome / LatLong labeling.
private struct Panorama360SceneOnlyView: UIViewRepresentable {
    let imageURL: URL

    func makeUIView(context: Context) -> SCNHostView {
        let host = SCNHostView()
        host.configure(imageURL: imageURL)
        return host
    }

    func updateUIView(_ uiView: SCNHostView, context: Context) {}
}

import SceneKit

final class SCNHostView: UIView {
    private let scnView = SCNView()
    private var cameraNode: SCNNode?
    private var yaw: Float = 0
    private var pitch: Float = 0

    override init(frame: CGRect) {
        super.init(frame: frame)
        scnView.frame = bounds
        scnView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        scnView.backgroundColor = .black
        scnView.allowsCameraControl = false
        scnView.antialiasingMode = .multisampling4X
        addSubview(scnView)

        let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        scnView.addGestureRecognizer(pan)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:)") }

    func configure(imageURL: URL) {
        let scene = SCNScene()
        let sphere = SCNSphere(radius: 10)
        sphere.segmentCount = 192

        let material = SCNMaterial()
        material.isDoubleSided = true
        let raw = UIImage(contentsOfFile: imageURL.path)
        if let raw,
           let prepared = Quick360SphereCoordinateConvention.prepareEquirectTextureForInsideOut(uiImage: raw) {
            material.diffuse.contents = prepared
        } else if let raw {
            material.diffuse.contents = raw
        } else {
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
        cameraNode.camera?.fieldOfView = 70
        cameraNode.camera?.zNear = 0.1
        cameraNode.camera?.zFar = 100
        cameraNode.position = SCNVector3(0, 0, 0)
        cameraNode.eulerAngles = SCNVector3(0, 0, 0)
        scene.rootNode.addChildNode(cameraNode)

        scnView.scene = scene
        scnView.pointOfView = cameraNode
        self.cameraNode = cameraNode
    }

    @objc private func handlePan(_ g: UIPanGestureRecognizer) {
        let t = g.translation(in: scnView)
        g.setTranslation(.zero, in: scnView)
        let sens: Float = 0.005
        yaw += Float(t.x) * sens
        pitch = max(-1.48, min(1.48, pitch + Float(t.y) * sens))
        cameraNode?.eulerAngles = SCNVector3(pitch, yaw, 0)
    }
}
