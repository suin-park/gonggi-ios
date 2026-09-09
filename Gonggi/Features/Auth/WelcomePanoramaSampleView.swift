import SceneKit
import SwiftUI
import UIKit

/// Bundle resource for the official Welcome LatLong sample (read-only demo).
enum WelcomePanoramaSampleAsset {
    static let resourceName = "WelcomeLatLongSample_1774x887"
    static let resourceExt = "jpg"
    static let optimizedWidth = 1774
    static let optimizedHeight = 887
    /// Living room + floor-to-ceiling windows peak near equirect u≈0.56 → yaw ≈ +22°.
    /// Convention: inside-out sphere, equirectYaw = +cameraYaw (see `VRSphereEquirectBridge`).
    static let initialYawDegrees: Float = 22
    static let initialPitchDegrees: Float = 0

    static var bundleURL: URL? {
        Bundle.main.url(forResource: resourceName, withExtension: resourceExt)
    }

    static func loadUIImage() -> UIImage? {
        guard let url = bundleURL else { return nil }
        return UIImage(contentsOfFile: url.path)
    }

    /// Welcome-only product copy.
    static let headline = "공간을 360°로 기록하고 공유하세요."
    static let subtitle = "스마트폰으로 촬영하고 필요한 정보까지 담아보세요."
    static let accountFootnote = "공간과 3D 자산을 하나의 계정으로 관리하세요."
}

/// Welcome-only equirect sample card + fullscreen. Does not touch Space Viewer / jobs / auth.
struct WelcomePanoramaSampleView: View {
    var isActive: Bool = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @State private var fullscreenPresented = false

    private var previewAnimating: Bool {
        isActive && scenePhase == .active && !reduceMotion && !fullscreenPresented
    }

    var body: some View {
        Button {
            GonggiHaptics.light()
            fullscreenPresented = true
        } label: {
            ZStack(alignment: .topLeading) {
                WelcomePanoramaSceneRepresentable(
                    mode: .previewAutoYaw,
                    isAnimating: previewAnimating,
                    allowsUserGestures: false
                )
                .clipShape(RoundedRectangle(cornerRadius: GonggiRadius.md, style: .continuous))

                Text("360° 샘플")
                    .font(GonggiTypography.caption(11))
                    .fontWeight(.semibold)
                    .foregroundStyle(Color.white.opacity(0.95))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.black.opacity(0.45), in: Capsule())
                    .padding(10)
                    .accessibilityHidden(true)
            }
            .overlay(
                RoundedRectangle(cornerRadius: GonggiRadius.md, style: .continuous)
                    .stroke(GonggiColors.brandCyan.opacity(0.35), lineWidth: 1)
            )
            .aspectRatio(16.0 / 9.0, contentMode: .fit)
            .frame(maxWidth: 360)
            .frame(maxWidth: .infinity)
            .clipped()
        }
        .buttonStyle(.plain)
        .accessibilityLabel("360도 공간 샘플 둘러보기")
        .accessibilityAddTraits(.isButton)
        .fullScreenCover(isPresented: $fullscreenPresented) {
            WelcomePanoramaFullscreenView(isPresented: $fullscreenPresented)
        }
    }
}

private struct WelcomePanoramaFullscreenView: View {
    @Binding var isPresented: Bool
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        ZStack(alignment: .top) {
            Color.black.ignoresSafeArea()
            WelcomePanoramaSceneRepresentable(
                mode: .interactive,
                isAnimating: false,
                allowsUserGestures: true
            )
            .ignoresSafeArea()
            .opacity(scenePhase == .active ? 1 : 1)

            HStack {
                Text("360° 샘플")
                    .font(GonggiTypography.body(16))
                    .fontWeight(.semibold)
                    .foregroundStyle(.white)
                Spacer()
                Button("닫기") {
                    isPresented = false
                }
                .font(GonggiTypography.body(16))
                .foregroundStyle(.white)
                .accessibilityLabel("닫기")
            }
            .padding(.horizontal, GonggiSpacing.lg)
            .padding(.top, GonggiSpacing.md)
            .padding(.bottom, GonggiSpacing.sm)
            .background(
                LinearGradient(
                    colors: [Color.black.opacity(0.55), Color.black.opacity(0)],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
        }
        .statusBarHidden(false)
    }
}

private enum WelcomePanoramaSceneMode {
    case previewAutoYaw
    case interactive
}

/// SceneKit inside-out sphere; Welcome-only (not `Panorama360ViewerView` / Space Viewer).
private struct WelcomePanoramaSceneRepresentable: UIViewRepresentable {
    var mode: WelcomePanoramaSceneMode
    var isAnimating: Bool
    var allowsUserGestures: Bool

    func makeUIView(context: Context) -> SCNView {
        let view = SCNView()
        view.backgroundColor = .clear
        view.allowsCameraControl = false
        view.antialiasingMode = .multisampling4X
        view.isPlaying = true
        view.rendersContinuously = false

        let scene = SCNScene()
        let sphere = SCNSphere(radius: 10)
        sphere.segmentCount = 64
        let material = SCNMaterial()
        material.isDoubleSided = true
        if let raw = WelcomePanoramaSampleAsset.loadUIImage(),
           let prepared = Quick360SphereCoordinateConvention.prepareEquirectTextureForInsideOut(uiImage: raw) {
            material.diffuse.contents = prepared
        } else if let raw = WelcomePanoramaSampleAsset.loadUIImage() {
            material.diffuse.contents = raw
        } else {
            material.diffuse.contents = UIColor.darkGray
        }
        material.diffuse.wrapS = .repeat
        material.diffuse.wrapT = .clamp
        material.lightingModel = .constant
        sphere.firstMaterial = material
        sphere.firstMaterial?.cullMode = .front

        let sphereNode = SCNNode(geometry: sphere)
        let s = Quick360SphereCoordinateConvention.insideOutScale
        sphereNode.scale = SCNVector3(s.x, s.y, s.z)
        scene.rootNode.addChildNode(sphereNode)

        let cameraNode = SCNNode()
        cameraNode.camera = SCNCamera()
        cameraNode.camera?.fieldOfView = 72
        cameraNode.camera?.zNear = 0.1
        cameraNode.camera?.zFar = 100
        cameraNode.position = SCNVector3(0, 0, 0)
        cameraNode.eulerAngles = SCNVector3(
            WelcomePanoramaSampleAsset.initialPitchDegrees * .pi / 180,
            WelcomePanoramaSampleAsset.initialYawDegrees * .pi / 180,
            0
        )
        scene.rootNode.addChildNode(cameraNode)

        view.scene = scene
        view.pointOfView = cameraNode

        context.coordinator.cameraNode = cameraNode
        context.coordinator.scnView = view
        context.coordinator.mode = mode
        context.coordinator.baseYaw = WelcomePanoramaSampleAsset.initialYawDegrees * .pi / 180
        context.coordinator.configureGestures(on: view, enabled: allowsUserGestures)
        context.coordinator.setAnimating(isAnimating)
        return view
    }

    func updateUIView(_ uiView: SCNView, context: Context) {
        context.coordinator.mode = mode
        context.coordinator.configureGestures(on: uiView, enabled: allowsUserGestures)
        if !isAnimating, mode == .previewAutoYaw {
            context.coordinator.snapToForwardStatic()
        }
        context.coordinator.setAnimating(isAnimating)
        uiView.isPlaying = isAnimating || allowsUserGestures
        uiView.rendersContinuously = isAnimating
    }

    static func dismantleUIView(_ uiView: SCNView, coordinator: Coordinator) {
        coordinator.teardown()
        uiView.scene = nil
        uiView.isPlaying = false
        uiView.rendersContinuously = false
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator: NSObject {
        var cameraNode: SCNNode?
        weak var scnView: SCNView?
        var mode: WelcomePanoramaSceneMode = .previewAutoYaw
        var baseYaw: Float = WelcomePanoramaSampleAsset.initialYawDegrees * .pi / 180
        private var displayLink: CADisplayLink?
        private var animationStart: CFTimeInterval?
        private var panGesture: UIPanGestureRecognizer?
        private var pinchGesture: UIPinchGestureRecognizer?
        private var lastPan = CGPoint.zero
        private var fieldOfView: CGFloat = 72
        /// ±18° yaw around living-room heading, 14s round trip, ease-in-out.
        private let yawAmplitude: Float = 18 * .pi / 180
        private let period: CFTimeInterval = 14

        func configureGestures(on view: SCNView, enabled: Bool) {
            if enabled {
                if panGesture == nil {
                    let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
                    view.addGestureRecognizer(pan)
                    panGesture = pan
                }
                if pinchGesture == nil {
                    let pinch = UIPinchGestureRecognizer(target: self, action: #selector(handlePinch(_:)))
                    view.addGestureRecognizer(pinch)
                    pinchGesture = pinch
                }
                panGesture?.isEnabled = true
                pinchGesture?.isEnabled = true
            } else {
                panGesture?.isEnabled = false
                pinchGesture?.isEnabled = false
            }
        }

        func setAnimating(_ animating: Bool) {
            if animating {
                startDisplayLink()
            } else {
                stopDisplayLink()
                if mode == .previewAutoYaw, let camera = cameraNode {
                    camera.eulerAngles.x = 0
                }
            }
        }

        func snapToForwardStatic() {
            cameraNode?.eulerAngles = SCNVector3(0, baseYaw, 0)
        }

        func teardown() {
            stopDisplayLink()
            if let view = scnView {
                if let pan = panGesture { view.removeGestureRecognizer(pan) }
                if let pinch = pinchGesture { view.removeGestureRecognizer(pinch) }
            }
            panGesture = nil
            pinchGesture = nil
            cameraNode = nil
            scnView = nil
        }

        private func startDisplayLink() {
            guard displayLink == nil else { return }
            animationStart = CACurrentMediaTime()
            let link = CADisplayLink(target: self, selector: #selector(tick(_:)))
            link.add(to: .main, forMode: .common)
            displayLink = link
        }

        private func stopDisplayLink() {
            displayLink?.invalidate()
            displayLink = nil
            animationStart = nil
        }

        @objc private func tick(_ link: CADisplayLink) {
            guard mode == .previewAutoYaw, let camera = cameraNode else { return }
            let start = animationStart ?? link.timestamp
            if animationStart == nil { animationStart = start }
            let t = (link.timestamp - start).truncatingRemainder(dividingBy: period) / period
            let eased = 0.5 - 0.5 * cos(t * 2 * Double.pi)
            let yaw = baseYaw + yawAmplitude * Float(2 * eased - 1)
            camera.eulerAngles.y = yaw
            camera.eulerAngles.x = 0
            scnView?.setNeedsDisplay()
        }

        @objc func handlePan(_ gesture: UIPanGestureRecognizer) {
            guard let view = gesture.view as? SCNView, let camera = cameraNode else { return }
            let translation = gesture.translation(in: view)
            if gesture.state == .began { lastPan = translation; return }
            let dx = Float(translation.x - lastPan.x) * 0.005
            let dy = Float(translation.y - lastPan.y) * 0.005
            lastPan = translation
            camera.eulerAngles.y -= dx
            let maxPitch: Float = 1.4
            camera.eulerAngles.x = max(-maxPitch, min(maxPitch, camera.eulerAngles.x - dy))
            if gesture.state == .ended { lastPan = .zero }
        }

        @objc func handlePinch(_ gesture: UIPinchGestureRecognizer) {
            guard let camera = cameraNode?.camera else { return }
            if gesture.state == .changed {
                let newFOV = fieldOfView / CGFloat(gesture.scale)
                fieldOfView = min(100, max(40, newFOV))
                camera.fieldOfView = fieldOfView
                gesture.scale = 1
            }
        }
    }
}
