import Combine
import SwiftUI
import AVFoundation

/// Full-screen VR with long-press → selective repair flow.
struct VRSphereSpaceView: View {
    let imageURL: URL
    let sessionId: String
    var baseRevisionId: String = "rev-0-base"
    var onClose: () -> Void
    /// Called when a repair revision is ready locally (file URL).
    var onRepairCompleted: ((URL) -> Void)? = nil

    @State private var pendingTarget: RepairTarget?
    @State private var showConfirmSheet = false
    @State private var showCapture = false
    @State private var markerYawDeg: Float?
    @State private var markerPitchDeg: Float?
    @State private var repairBusy = false
    @State private var repairStatusText: String?
    @State private var repairError: String?
    @State private var toastText: String?

    private let repairRuntime = SpaceRepairRuntime()

    var body: some View {
        ZStack(alignment: .topLeading) {
            Panorama360SceneOnlyView(
                imageURL: imageURL,
                markerYawDeg: markerYawDeg,
                markerPitchDeg: markerPitchDeg,
                onLongPress: { yaw, pitch in
                    GonggiHaptics.medium()
                    let target = RepairTarget.make(
                        sessionId: sessionId,
                        baseRevisionId: baseRevisionId,
                        targetYawDeg: Double(yaw),
                        targetPitchDeg: Double(pitch)
                    )
                    pendingTarget = target
                    markerYawDeg = yaw
                    markerPitchDeg = pitch
                    showConfirmSheet = true
                }
            )
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

            if let repairStatusText {
                Text(repairStatusText)
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Color.black.opacity(0.55))
                    .clipShape(Capsule())
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                    .padding(.bottom, 28)
            }

            if let toastText {
                Text(toastText)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(Color.black.opacity(0.7))
                    .clipShape(Capsule())
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    .padding(.top, 64)
            }
        }
        .statusBarHidden(true)
        .sheet(isPresented: $showConfirmSheet, onDismiss: {
            if !showCapture {
                markerYawDeg = nil
                markerPitchDeg = nil
                pendingTarget = nil
            }
        }) {
            RepairConfirmSheet(
                onRecapture: {
                    showConfirmSheet = false
                    showCapture = true
                },
                onCancel: {
                    showConfirmSheet = false
                    markerYawDeg = nil
                    markerPitchDeg = nil
                    pendingTarget = nil
                }
            )
            .presentationDetents([.height(220)])
        }
        .fullScreenCover(isPresented: $showCapture) {
            if let pendingTarget {
                RepairOneShotCaptureView(
                    target: pendingTarget,
                    onCancel: {
                        showCapture = false
                        markerYawDeg = nil
                        markerPitchDeg = nil
                        self.pendingTarget = nil
                    },
                    onReadyToRepair: { image, yaw, elev in
                        showCapture = false
                        Task { await runRepair(target: pendingTarget, image: image, yaw: yaw, elev: elev) }
                    }
                )
            }
        }
        .alert("부분 수정에 실패했어요", isPresented: Binding(
            get: { repairError != nil },
            set: { if !$0 { repairError = nil } }
        )) {
            Button("확인", role: .cancel) { repairError = nil }
        } message: {
            Text(repairError ?? "")
        }
    }

    private func runRepair(target: RepairTarget, image: UIImage, yaw: Float, elev: Float) async {
        repairBusy = true
        repairStatusText = "선택한 부분을 수정하고 있어요"
        defer {
            repairBusy = false
            repairStatusText = nil
        }
        do {
            let job = try await repairRuntime.submitRepair(
                target: target,
                image: image,
                capturedYawDeg: yaw,
                capturedElevationDeg: elev,
                repairMode: "ai_local_repair"
            )
            let done = try await repairRuntime.pollUntilComplete(
                repairJobId: job.repairJobId,
                sessionId: target.sessionId
            )
            markerYawDeg = nil
            markerPitchDeg = nil
            pendingTarget = nil
            toastText = "수정 완료"
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { toastText = nil }
            if let path = done.localLatLongPath {
                onRepairCompleted?(URL(fileURLWithPath: path))
            }
        } catch {
            repairError = "부분 수정에 실패했어요"
            markerYawDeg = nil
            markerPitchDeg = nil
        }
    }
}

private struct RepairConfirmSheet: View {
    var onRecapture: () -> Void
    var onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("이 부분을 다시 기록할까요?")
                .font(.headline)
            Text("현재 위치에서 이 방향을 한 장 다시 촬영하면\n선택한 부분만 더 정확하게 수정할 수 있어요.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            HStack(spacing: 12) {
                Button("취소", action: onCancel)
                    .buttonStyle(.bordered)
                Button("다시 촬영", action: onRecapture)
                    .buttonStyle(.borderedProminent)
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(20)
    }
}

struct RepairOneShotCaptureView: View {
    let target: RepairTarget
    var onCancel: () -> Void
    var onReadyToRepair: (UIImage, Float, Float) -> Void

    @StateObject private var model = RepairOneShotCaptureModel()
    @State private var captured: (UIImage, Float, Float)?

    var body: some View {
        ZStack {
            RepairCameraPreview(session: model.engine.session)
                .ignoresSafeArea()

            VStack(spacing: 16) {
                Text("선택한 부분을 다시 촬영해주세요.")
                    .font(.headline)
                    .foregroundStyle(.white)
                    .shadow(radius: 2)
                Text("처음 기록했던 위치에서 화면의 원을 맞춰주세요.")
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.9))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)

                Spacer()

                ZStack {
                    Circle()
                        .stroke(model.isAligned ? Color.green : Color.white.opacity(0.85), lineWidth: 3)
                        .frame(width: 88, height: 88)
                    Circle()
                        .fill(Color.white.opacity(0.35))
                        .frame(width: 8, height: 8)
                }

                Text(model.guideText)
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(.white)
                    .padding(.bottom, 8)

                if let captured {
                    Button("이 부분 수정하기") {
                        onReadyToRepair(captured.0, captured.1, captured.2)
                    }
                    .buttonStyle(.borderedProminent)
                    .padding(.bottom, 28)
                } else {
                    Button("취소", action: onCancel)
                        .foregroundStyle(.white)
                        .padding(.bottom, 28)
                }
            }
            .padding(.top, 48)
        }
        .onAppear {
            model.configure(target: target)
            model.start()
            model.onCaptured = { img, yaw, elev in
                captured = (img, yaw, elev)
            }
        }
        .onDisappear { model.stop() }
    }
}

@MainActor
final class RepairOneShotCaptureModel: ObservableObject {
    let engine = RepairOneShotCaptureEngine()
    @Published var guideText = ""
    @Published var isAligned = false
    var onCaptured: ((UIImage, Float, Float) -> Void)?

    func configure(target: RepairTarget) {
        engine.targetEquirectYawDeg = Float(target.targetYawDeg)
        engine.targetPitchDeg = Float(target.targetPitchDeg)
        engine.onUIUpdate = { [weak self] in
            Task { @MainActor in
                self?.guideText = self?.engine.guideText ?? ""
                self?.isAligned = self?.engine.isAligned ?? false
            }
        }
        engine.onCaptured = { [weak self] img, yaw, elev in
            Task { @MainActor in
                self?.onCaptured?(img, yaw, elev)
            }
        }
    }

    func start() {
        do {
            try engine.prepareCamera(mockMode: false)
            engine.start()
        } catch {
            guideText = "카메라를 열 수 없어요"
        }
    }

    func stop() { engine.stop() }
}

private struct RepairCameraPreview: UIViewRepresentable {
    let session: AVCaptureSession

    func makeUIView(context: Context) -> PreviewView {
        let v = PreviewView()
        v.previewLayer.session = session
        v.previewLayer.videoGravity = .resizeAspectFill
        return v
    }

    func updateUIView(_ uiView: PreviewView, context: Context) {
        uiView.previewLayer.session = session
    }

    final class PreviewView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
    }
}

/// SceneKit viewer with long-press → equirect yaw/pitch callback.
private struct Panorama360SceneOnlyView: UIViewRepresentable {
    let imageURL: URL
    var markerYawDeg: Float?
    var markerPitchDeg: Float?
    var onLongPress: (Float, Float) -> Void

    func makeUIView(context: Context) -> SCNHostView {
        let host = SCNHostView()
        host.onLongPressEquirect = onLongPress
        host.configure(imageURL: imageURL)
        host.updateMarker(yawDeg: markerYawDeg, pitchDeg: markerPitchDeg)
        return host
    }

    func updateUIView(_ uiView: SCNHostView, context: Context) {
        uiView.onLongPressEquirect = onLongPress
        uiView.updateMarker(yawDeg: markerYawDeg, pitchDeg: markerPitchDeg)
    }
}

import SceneKit

final class SCNHostView: UIView {
    private let scnView = SCNView()
    private var cameraNode: SCNNode?
    private var markerNode: SCNNode?
    private var yaw: Float = 0
    private var pitch: Float = 0

    var onLongPressEquirect: ((Float, Float) -> Void)?

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

        let longPress = UILongPressGestureRecognizer(target: self, action: #selector(handleLongPress(_:)))
        longPress.minimumPressDuration = 0.45
        scnView.addGestureRecognizer(longPress)
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
        } else if let raw, raw.cgImage != nil {
            material.diffuse.contents = raw
        } else {
            material.diffuse.contents = UIColor(white: 0.12, alpha: 1)
            #if DEBUG
            assertionFailure("VRSphere opened without readable latlong at \(imageURL.path)")
            #endif
        }
        material.diffuse.wrapS = .repeat
        material.diffuse.wrapT = .clamp
        sphere.firstMaterial = material
        sphere.firstMaterial?.cullMode = .front

        let sphereNode = SCNNode(geometry: sphere)
        let s = Quick360SphereCoordinateConvention.insideOutScale
        sphereNode.scale = SCNVector3(s.x, s.y, s.z)
        sphereNode.name = "sphere"
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

    func updateMarker(yawDeg: Float?, pitchDeg: Float?) {
        markerNode?.removeFromParentNode()
        markerNode = nil
        guard let yawDeg, let pitchDeg, let scene = scnView.scene else { return }

        // Place a small marker on the inside of the sphere (equirect right-positive → camera convention).
        let camYaw = -yawDeg * .pi / 180
        let camPitch = -pitchDeg * .pi / 180
        let r: Float = 9.2
        let x = sin(camYaw) * cos(camPitch) * r
        let y = sin(camPitch) * r
        let z = -cos(camYaw) * cos(camPitch) * r

        let marker = SCNNode(geometry: SCNSphere(radius: 0.12))
        marker.geometry?.firstMaterial?.diffuse.contents = UIColor.systemYellow
        marker.geometry?.firstMaterial?.emission.contents = UIColor.systemYellow
        marker.position = SCNVector3(x, y, z)
        scene.rootNode.addChildNode(marker)
        markerNode = marker
    }

    @objc private func handlePan(_ g: UIPanGestureRecognizer) {
        let t = g.translation(in: scnView)
        g.setTranslation(.zero, in: scnView)
        let sens: Float = 0.005
        yaw += Float(t.x) * sens
        pitch = max(-1.48, min(1.48, pitch + Float(t.y) * sens))
        cameraNode?.eulerAngles = SCNVector3(pitch, yaw, 0)
    }

    @objc private func handleLongPress(_ g: UILongPressGestureRecognizer) {
        guard g.state == .began else { return }
        let point = g.location(in: scnView)
        let (yawDeg, pitchDeg) = VRSphereEquirectBridge.equirectDegreesFromScreenPoint(
            point: point,
            viewSize: scnView.bounds.size,
            cameraYawRad: yaw,
            cameraPitchRad: pitch,
            fieldOfViewDeg: 70
        )
        onLongPressEquirect?(yawDeg, pitchDeg)
    }
}
