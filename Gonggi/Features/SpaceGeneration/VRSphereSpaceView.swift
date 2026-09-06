import Combine
import SwiftUI
import AVFoundation
import SceneKit

/// Full-screen VR with long-press → selective repair flow.
struct VRSphereSpaceView: View {
    let imageURL: URL
    let sessionId: String
    var baseRevisionId: String = "rev-0-base"
    var onClose: () -> Void
    var onRepairCompleted: ((URL) -> Void)? = nil

    @State private var pendingTarget: RepairTarget?
    @State private var showConfirmSheet = false
    /// Item-based cover avoids sheet/fullScreenCover race that broke Cancel.
    @State private var captureTarget: RepairTarget?
    @State private var markerYawDeg: Float?
    @State private var markerPitchDeg: Float?
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
            // If user dismissed sheet without starting camera, clear marker.
            if captureTarget == nil {
                clearRepairSelection()
            }
        }) {
            RepairConfirmSheet(
                onRecapture: {
                    guard let target = pendingTarget else { return }
                    showConfirmSheet = false
                    // Present after sheet fully dismisses — fixes Cancel / cover race.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                        captureTarget = target
                    }
                },
                onCancel: {
                    showConfirmSheet = false
                    clearRepairSelection()
                }
            )
            .presentationDetents([.height(220)])
        }
        .fullScreenCover(item: $captureTarget, onDismiss: {
            // Returning to VR without submitting repair — keep marker optional clear.
            // Marker cleared only on explicit cancel from camera.
        }) { target in
            RepairManualCaptureView(
                target: target,
                onCancel: {
                    captureTarget = nil
                    clearRepairSelection()
                },
                onConfirmRepair: { image, yaw, elev in
                    let t = target
                    captureTarget = nil
                    markerYawDeg = nil
                    markerPitchDeg = nil
                    pendingTarget = nil
                    Task { await runRepair(target: t, image: image, yaw: yaw, elev: elev) }
                }
            )
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

    private func clearRepairSelection() {
        markerYawDeg = nil
        markerPitchDeg = nil
        pendingTarget = nil
    }

    private func runRepair(target: RepairTarget, image: UIImage, yaw: Float, elev: Float) async {
        repairStatusText = "선택한 부분을 수정하고 있어요"
        defer { repairStatusText = nil }
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
            toastText = "수정 완료"
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { toastText = nil }
            if let path = done.localLatLongPath {
                onRepairCompleted?(URL(fileURLWithPath: path))
            }
        } catch {
            repairError = "부분 수정에 실패했어요"
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

// MARK: - Manual repair camera + preview

private enum RepairCameraPhase: Equatable {
    case camera
    case preview
}

struct RepairManualCaptureView: View {
    let target: RepairTarget
    var onCancel: () -> Void
    var onConfirmRepair: (UIImage, Float, Float) -> Void

    @StateObject private var model = RepairManualCaptureModel()
    @State private var phase: RepairCameraPhase = .camera
    @State private var previewImage: UIImage?
    @State private var previewYaw: Float = 0
    @State private var previewElev: Float = 0
    @State private var showSoftWarning = false

    var body: some View {
        ZStack {
            if phase == .preview, let previewImage {
                previewLayer(image: previewImage)
            } else {
                cameraLayer
            }
        }
        .background(Color.black.ignoresSafeArea())
        .onAppear {
            model.configure(target: target)
            model.start()
            model.onCaptured = { img, yaw, elev, _, _ in
                previewImage = img
                previewYaw = yaw
                previewElev = elev
                showSoftWarning = model.softMisalignmentWarning
                phase = .preview
            }
        }
        .onDisappear {
            model.cancelAndStop()
        }
    }

    private var cameraLayer: some View {
        ZStack {
            RepairCameraPreview(session: model.engine.session)
                .ignoresSafeArea()

            // Subtle center guide — not an alignment reticle.
            Circle()
                .stroke(Color.white.opacity(0.22), lineWidth: 1)
                .frame(width: 28, height: 28)

            VStack(spacing: 10) {
                Text("수정할 부분을 다시 촬영해주세요.")
                    .font(.headline)
                    .foregroundStyle(.white)
                    .shadow(radius: 2)
                    .multilineTextAlignment(.center)
                Text("처음 기록했던 위치에서\n수정할 부분이 잘 보이도록 한 장 촬영해주세요.")
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.92))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)

                if model.softMisalignmentWarning {
                    Text("선택한 부분이 화면에 잘 보이는지 확인해주세요.")
                        .font(.footnote.weight(.medium))
                        .foregroundStyle(.yellow)
                        .padding(.top, 4)
                }

                Spacer()

                HStack {
                    Button("취소") {
                        GonggiHaptics.light()
                        model.cancelAndStop()
                        onCancel()
                    }
                    .foregroundStyle(.white)
                    .frame(width: 72)

                    Spacer()

                    Button {
                        GonggiHaptics.medium()
                        model.capture()
                    } label: {
                        ZStack {
                            Circle()
                                .stroke(Color.white, lineWidth: 4)
                                .frame(width: 72, height: 72)
                            Circle()
                                .fill(Color.white)
                                .frame(width: 58, height: 58)
                        }
                    }
                    .accessibilityLabel("촬영")

                    Spacer()
                    Color.clear.frame(width: 72)
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 36)
            }
            .padding(.top, 52)
        }
    }

    private func previewLayer(image: UIImage) -> some View {
        VStack(spacing: 0) {
            Image(uiImage: image)
                .resizable()
                .scaledToFit()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.black)

            if showSoftWarning {
                Text("선택한 부분이 화면에 잘 보이는지 확인해주세요.")
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(.yellow)
                    .padding(.top, 8)
            }

            HStack(spacing: 12) {
                Button("취소") {
                    GonggiHaptics.light()
                    model.cancelAndStop()
                    onCancel()
                }
                .buttonStyle(.bordered)

                Button("다시 촬영") {
                    GonggiHaptics.light()
                    previewImage = nil
                    phase = .camera
                    model.retake()
                }
                .buttonStyle(.bordered)

                Button("이 사진으로 수정") {
                    GonggiHaptics.medium()
                    model.stop()
                    onConfirmRepair(image, previewYaw, previewElev)
                }
                .buttonStyle(.borderedProminent)
            }
            .padding(16)
            .padding(.bottom, 20)
        }
    }
}

@MainActor
final class RepairManualCaptureModel: ObservableObject {
    let engine = RepairOneShotCaptureEngine()
    @Published var softMisalignmentWarning = false
    var onCaptured: ((UIImage, Float, Float, Float, Float) -> Void)?

    func configure(target: RepairTarget) {
        engine.targetEquirectYawDeg = Float(target.targetYawDeg)
        engine.targetPitchDeg = Float(target.targetPitchDeg)
        engine.onUIUpdate = { [weak self] in
            Task { @MainActor in
                self?.softMisalignmentWarning = self?.engine.softMisalignmentWarning ?? false
            }
        }
        engine.onCaptured = { [weak self] img, yaw, elev, dyaw, dpitch in
            Task { @MainActor in
                self?.softMisalignmentWarning = self?.engine.softMisalignmentWarning ?? false
                self?.onCaptured?(img, yaw, elev, dyaw, dpitch)
            }
        }
    }

    func start() {
        do {
            try engine.prepareCamera(mockMode: false)
            engine.start()
        } catch {
            softMisalignmentWarning = false
        }
    }

    func capture() { engine.captureNow() }

    func retake() { engine.resetForRetake() }

    func stop() { engine.stop() }

    func cancelAndStop() {
        engine.cancelPendingPhoto()
        engine.stop()
    }
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

// MARK: - SceneKit VR host

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
