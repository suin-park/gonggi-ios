import Combine
import SwiftUI
import AVFoundation
import SceneKit

/// Full-screen VR with long-press → selective repair flow (async after HTTP 202).
struct VRSphereSpaceView: View {
    let imageURL: URL
    let sessionId: String
    var baseRevisionId: String = "rev-0-base"
    var onClose: () -> Void
    /// Optional: notify parent of new local texture path (do not recreate viewer — orientation preserved in-place).
    var onRepairCompleted: ((URL) -> Void)? = nil

    @StateObject private var repairController: RepairSessionController
    @State private var pendingTarget: RepairTarget?
    @State private var showConfirmSheet = false
    @State private var captureTarget: RepairTarget?
    @State private var markerYawDeg: Float?
    @State private var markerPitchDeg: Float?
    @State private var textureURL: URL
    @State private var textureGeneration: Int = 0
    @State private var uploadError: String?

    init(
        imageURL: URL,
        sessionId: String,
        baseRevisionId: String = "rev-0-base",
        onClose: @escaping () -> Void,
        onRepairCompleted: ((URL) -> Void)? = nil
    ) {
        self.imageURL = imageURL
        self.sessionId = sessionId
        self.baseRevisionId = baseRevisionId
        self.onClose = onClose
        self.onRepairCompleted = onRepairCompleted
        _textureURL = State(initialValue: imageURL)
        _repairController = StateObject(wrappedValue: RepairSessionController(sessionId: sessionId))
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            Panorama360SceneOnlyView(
                imageURL: textureURL,
                textureGeneration: textureGeneration,
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
            .allowsHitTesting(true)

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

            repairBanner
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                .padding(.bottom, 28)
                .allowsHitTesting(true)
        }
        .statusBarHidden(true)
        .onChange(of: repairController.completedTextureURL) { _, newURL in
            guard let newURL else { return }
            applyCompletedTexture(newURL)
        }
        .onAppear {
            repairController.refreshFromStore()
            if let url = repairController.completedTextureURL {
                applyCompletedTexture(url)
            }
        }
        .sheet(isPresented: $showConfirmSheet, onDismiss: {
            if captureTarget == nil {
                clearRepairSelection()
            }
        }) {
            RepairConfirmSheet(
                onRecapture: {
                    guard let target = pendingTarget else { return }
                    showConfirmSheet = false
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
        .fullScreenCover(item: $captureTarget) { target in
            RepairManualCaptureView(
                target: target,
                onCancel: {
                    captureTarget = nil
                    clearRepairSelection()
                },
                onSubmitted: {
                    // HTTP 202 already persisted + polling started — return to interactive VR.
                    captureTarget = nil
                    markerYawDeg = nil
                    markerPitchDeg = nil
                    pendingTarget = nil
                    repairController.refreshFromStore()
                }
            )
        }
        .alert("부분 수정에 실패했어요", isPresented: Binding(
            get: { uploadError != nil },
            set: { if !$0 { uploadError = nil } }
        )) {
            Button("확인", role: .cancel) { uploadError = nil }
        } message: {
            Text(uploadError ?? "")
        }
    }

    @ViewBuilder
    private var repairBanner: some View {
        switch repairController.banner {
        case .none:
            EmptyView()
        case .repairing:
            HStack(spacing: 10) {
                ProgressView()
                    .tint(.white)
                Text("선택한 부분을 수정하고 있어요")
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(.white)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(Color.black.opacity(0.55))
            .clipShape(Capsule())
        case .completed:
            HStack(spacing: 8) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Text("선택한 부분을 수정했어요.")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.white)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(Color.black.opacity(0.7))
            .clipShape(Capsule())
            .onTapGesture { repairController.dismissCompletedBanner() }
        case .failed(let retryTarget):
            HStack(spacing: 12) {
                Text("부분 수정에 실패했어요.")
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(.white)
                if let retryTarget {
                    Button("다시 시도") {
                        repairController.clearFailedBanner()
                        pendingTarget = retryTarget
                        captureTarget = retryTarget
                    }
                    .font(.footnote.weight(.semibold))
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(Color.black.opacity(0.65))
            .clipShape(Capsule())
        }
    }

    private func clearRepairSelection() {
        markerYawDeg = nil
        markerPitchDeg = nil
        pendingTarget = nil
    }

    private func applyCompletedTexture(_ url: URL) {
        guard SpaceLatLongStore.isValidLocalFile(at: url.path) else { return }
        // In-place reload — SCNHostView keeps yaw/pitch.
        if textureURL != url {
            textureURL = url
            textureGeneration += 1
            onRepairCompleted?(url)
        } else {
            textureGeneration += 1
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

// MARK: - Manual repair camera + preview + upload-to-202

private enum RepairCameraPhase: Equatable {
    case camera
    case preview
    case uploading
}

struct RepairManualCaptureView: View {
    let target: RepairTarget
    var onCancel: () -> Void
    /// Called only after HTTP 202 + job persisted (dismiss to VR).
    var onSubmitted: () -> Void

    @StateObject private var model = RepairManualCaptureModel()
    @State private var phase: RepairCameraPhase = .camera
    @State private var previewImage: UIImage?
    @State private var previewYaw: Float = 0
    @State private var previewElev: Float = 0
    @State private var showSoftWarning = false
    @State private var submitError: String?

    var body: some View {
        ZStack {
            if phase == .preview || phase == .uploading, let previewImage {
                previewLayer(image: previewImage)
            } else {
                cameraLayer
            }
        }
        .background(Color.black.ignoresSafeArea())
        .alert("업로드에 실패했어요", isPresented: Binding(
            get: { submitError != nil },
            set: { if !$0 { submitError = nil } }
        )) {
            Button("확인", role: .cancel) { submitError = nil }
        } message: {
            Text(submitError ?? "")
        }
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
            // Only cancel camera hardware — do not cancel server job after submit.
            if phase != .uploading {
                model.cancelAndStop()
            } else {
                model.stop()
            }
        }
    }

    private var cameraLayer: some View {
        ZStack {
            RepairCameraPreview(session: model.engine.session)
                .ignoresSafeArea()

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

            if showSoftWarning, phase == .preview {
                Text("선택한 부분이 화면에 잘 보이는지 확인해주세요.")
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(.yellow)
                    .padding(.top, 8)
            }

            if phase == .uploading {
                HStack(spacing: 10) {
                    ProgressView().tint(.white)
                    Text("사진을 올리고 있어요…")
                        .font(.footnote.weight(.medium))
                        .foregroundStyle(.white)
                }
                .padding(.vertical, 12)
            }

            HStack(spacing: 12) {
                Button("취소") {
                    GonggiHaptics.light()
                    guard phase != .uploading else { return }
                    model.cancelAndStop()
                    onCancel()
                }
                .buttonStyle(.bordered)
                .disabled(phase == .uploading)

                Button("다시 촬영") {
                    GonggiHaptics.light()
                    guard phase != .uploading else { return }
                    previewImage = nil
                    phase = .camera
                    model.retake()
                }
                .buttonStyle(.bordered)
                .disabled(phase == .uploading)

                Button("이 사진으로 수정") {
                    GonggiHaptics.medium()
                    Task { await submit(image: image) }
                }
                .buttonStyle(.borderedProminent)
                .disabled(phase == .uploading)
            }
            .padding(16)
            .padding(.bottom, 20)
        }
    }

    private func submit(image: UIImage) async {
        phase = .uploading
        model.stop()
        do {
            let job = try await SpaceRepairRuntime.shared.submitRepair(
                target: target,
                image: image,
                capturedYawDeg: previewYaw,
                capturedElevationDeg: previewElev,
                repairMode: "ai_local_repair"
            )
            await SpaceRepairRuntime.shared.ensurePolling(
                repairJobId: job.repairJobId,
                sessionId: job.sessionId
            )
            onSubmitted()
        } catch {
            phase = .preview
            model.start()
            submitError = "사진을 올리지 못했어요. 다시 시도해주세요."
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
    var textureGeneration: Int
    var markerYawDeg: Float?
    var markerPitchDeg: Float?
    var onLongPress: (Float, Float) -> Void

    func makeUIView(context: Context) -> SCNHostView {
        let host = SCNHostView()
        host.onLongPressEquirect = onLongPress
        host.configure(imageURL: imageURL)
        host.updateMarker(yawDeg: markerYawDeg, pitchDeg: markerPitchDeg)
        context.coordinator.lastGeneration = textureGeneration
        context.coordinator.lastURL = imageURL
        return host
    }

    func updateUIView(_ uiView: SCNHostView, context: Context) {
        uiView.onLongPressEquirect = onLongPress
        if textureGeneration != context.coordinator.lastGeneration
            || imageURL != context.coordinator.lastURL {
            uiView.reloadTexture(from: imageURL)
            context.coordinator.lastGeneration = textureGeneration
            context.coordinator.lastURL = imageURL
        }
        uiView.updateMarker(yawDeg: markerYawDeg, pitchDeg: markerPitchDeg)
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var lastGeneration: Int = -1
        var lastURL: URL?
    }
}

final class SCNHostView: UIView {
    private let scnView = SCNView()
    private var cameraNode: SCNNode?
    private var sphereNode: SCNNode?
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
        applyTexture(to: material, imageURL: imageURL)
        material.diffuse.wrapS = .repeat
        material.diffuse.wrapT = .clamp
        sphere.firstMaterial = material
        sphere.firstMaterial?.cullMode = .front

        let sphereNode = SCNNode(geometry: sphere)
        let s = Quick360SphereCoordinateConvention.insideOutScale
        sphereNode.scale = SCNVector3(s.x, s.y, s.z)
        sphereNode.name = "sphere"
        scene.rootNode.addChildNode(sphereNode)
        self.sphereNode = sphereNode

        let cameraNode = SCNNode()
        cameraNode.camera = SCNCamera()
        cameraNode.camera?.fieldOfView = 70
        cameraNode.camera?.zNear = 0.1
        cameraNode.camera?.zFar = 100
        cameraNode.position = SCNVector3(0, 0, 0)
        cameraNode.eulerAngles = SCNVector3(pitch, yaw, 0)
        scene.rootNode.addChildNode(cameraNode)

        scnView.scene = scene
        scnView.pointOfView = cameraNode
        self.cameraNode = cameraNode
    }

    /// Reload equirect texture without resetting camera yaw/pitch.
    func reloadTexture(from imageURL: URL) {
        guard let material = sphereNode?.geometry?.firstMaterial else {
            configure(imageURL: imageURL)
            cameraNode?.eulerAngles = SCNVector3(pitch, yaw, 0)
            return
        }
        applyTexture(to: material, imageURL: imageURL)
        cameraNode?.eulerAngles = SCNVector3(pitch, yaw, 0)
    }

    private func applyTexture(to material: SCNMaterial, imageURL: URL) {
        let raw = UIImage(contentsOfFile: imageURL.path)
        if let raw,
           let prepared = Quick360SphereCoordinateConvention.prepareEquirectTextureForInsideOut(uiImage: raw) {
            material.diffuse.contents = prepared
        } else if let raw, raw.cgImage != nil {
            material.diffuse.contents = raw
        } else {
            material.diffuse.contents = UIColor(white: 0.12, alpha: 1)
        }
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
