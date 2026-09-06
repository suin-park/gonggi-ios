import Combine
import SwiftUI
import AVFoundation
import SceneKit
import simd
import UIKit

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
    @State private var panoramaReady = false
    @State private var showSelectiveRepairHint = false
    @State private var selectiveRepairHintOpacity: Double = 0
    /// True only after fade-in has started and markSeen ran for this presentation.
    @State private var selectiveRepairHintBecameVisible = false
    @State private var selectiveRepairHintTask: Task<Void, Never>?

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
                maskRadiusYawDeg: Float(pendingTarget?.radiusYawDeg
                    ?? Double(VRSphereEquirectBridge.defaultYawRadiusDeg)),
                maskRadiusPitchDeg: Float(pendingTarget?.radiusPitchDeg
                    ?? Double(VRSphereEquirectBridge.defaultPitchRadiusDeg)),
                onViewerReady: {
                    panoramaReady = true
                    scheduleSelectiveRepairHintIfNeeded()
                },
                onLongPress: { yaw, pitch in
                    GonggiHaptics.medium()
                    markSelectiveRepairHintSeenAndHide()
                    let target = RepairTarget.make(
                        sessionId: sessionId,
                        baseRevisionId: baseRevisionId,
                        targetYawDeg: Double(yaw),
                        targetPitchDeg: Double(pitch)
                    )
                    pendingTarget = target
                    markerYawDeg = yaw
                    markerPitchDeg = pitch
                    #if DEBUG
                    print(
                        "[repair-bridge] long-press equirect yaw=\(yaw) pitch=\(pitch) session=\(sessionId)"
                    )
                    #endif
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
            .zIndex(2)

            if showSelectiveRepairHint {
                SelectiveRepairHintPill()
                    .opacity(selectiveRepairHintOpacity)
                    .padding(.horizontal, 64)
                    .padding(.top, 14)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    .allowsHitTesting(false)
                    .accessibilityHidden(selectiveRepairHintOpacity < 0.05)
                    .zIndex(1)
            }

            #if DEBUG
            if VRSphereEquirectBridge.debugOverlayEnabled,
               let my = markerYawDeg,
               let mp = markerPitchDeg {
                VStack(alignment: .leading, spacing: 4) {
                    Text("repair target")
                        .font(.caption2.weight(.semibold))
                    Text(String(format: "yaw %+.1f°  pitch %+.1f°", my, mp))
                        .font(.caption.monospacedDigit())
                    Text(
                        "mask ±\(Int(VRSphereEquirectBridge.defaultYawRadiusDeg))° / ±\(Int(VRSphereEquirectBridge.defaultPitchRadiusDeg))° · 넓게 적용됨"
                    )
                        .font(.caption2)
                }
                .foregroundStyle(.white)
                .padding(10)
                .background(Color.black.opacity(0.55))
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .padding(.trailing, 16)
                .padding(.top, 12)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                .allowsHitTesting(false)
            }
            #endif

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
            if panoramaReady {
                scheduleSelectiveRepairHintIfNeeded()
            }
        }
        .onDisappear {
            cancelSelectiveRepairHintTask(resetIfNotYetVisible: true)
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
                    // 202 + persist + success feedback already shown in capture.
                    // Dismiss capture + VR; SpaceRepairRuntime polling keeps running.
                    captureTarget = nil
                    markerYawDeg = nil
                    markerPitchDeg = nil
                    pendingTarget = nil
                    // Do not set repairing banner — user leaves VR; card shows “수정 중”.
                    onClose()
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

    /// Gate (user-global, any VR entry via this view):
    /// panorama ready → 0.5s delay → fade in → markSeen → 4.5s hold → fade out.
    /// Does not check whether the space is new; only `hintSeen`.
    private func scheduleSelectiveRepairHintIfNeeded() {
        guard panoramaReady else { return }
        guard !SelectiveRepairHintPreferences.hasSeen else { return }
        guard selectiveRepairHintTask == nil else { return }

        selectiveRepairHintBecameVisible = false
        showSelectiveRepairHint = false
        selectiveRepairHintOpacity = 0

        selectiveRepairHintTask = Task { @MainActor in
            let delayNs = UInt64(SelectiveRepairHintPreferences.postReadyDelaySeconds * 1_000_000_000)
            try? await Task.sleep(nanoseconds: delayNs)
            guard !Task.isCancelled else { return }
            guard !SelectiveRepairHintPreferences.hasSeen else { return }

            showSelectiveRepairHint = true
            selectiveRepairHintOpacity = 0
            withAnimation(.easeIn(duration: SelectiveRepairHintPreferences.fadeInDurationSeconds)) {
                selectiveRepairHintOpacity = 1
            }
            // Persist only once the fade-in has begun (hint is on-screen).
            SelectiveRepairHintPreferences.markSeen()
            selectiveRepairHintBecameVisible = true

            let holdNs = UInt64(SelectiveRepairHintPreferences.displayDurationSeconds * 1_000_000_000)
            try? await Task.sleep(nanoseconds: holdNs)
            guard !Task.isCancelled else { return }

            withAnimation(.easeOut(duration: SelectiveRepairHintPreferences.fadeOutDurationSeconds)) {
                selectiveRepairHintOpacity = 0
            }
            let fadeNs = UInt64(SelectiveRepairHintPreferences.fadeOutDurationSeconds * 1_000_000_000)
            try? await Task.sleep(nanoseconds: fadeNs)
            guard !Task.isCancelled else { return }
            showSelectiveRepairHint = false
            selectiveRepairHintTask = nil
        }
    }

    private func cancelSelectiveRepairHintTask(resetIfNotYetVisible: Bool) {
        selectiveRepairHintTask?.cancel()
        selectiveRepairHintTask = nil
        if resetIfNotYetVisible, !selectiveRepairHintBecameVisible {
            // Dismissed before visible → keep seen=false; allow reschedule on next entry.
            showSelectiveRepairHint = false
            selectiveRepairHintOpacity = 0
        }
    }

    private func markSelectiveRepairHintSeenAndHide() {
        SelectiveRepairHintPreferences.markSeen()
        selectiveRepairHintBecameVisible = true
        selectiveRepairHintTask?.cancel()
        selectiveRepairHintTask = nil
        if showSelectiveRepairHint {
            withAnimation(.easeOut(duration: 0.2)) {
                selectiveRepairHintOpacity = 0
            }
            showSelectiveRepairHint = false
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
    /// HTTP 202 + SpaceRepairStore persist succeeded — show feedback then leave VR.
    case accepted
}

/// Auto-return delay after repair 202 acceptance (seconds).
enum RepairAcceptedNavigation {
    static let autoDismissDelayNanoseconds: UInt64 = 1_200_000_000
}

struct RepairManualCaptureView: View {
    let target: RepairTarget
    var onCancel: () -> Void
    /// Called only after HTTP 202 + job persisted + success feedback delay.
    /// Parent must dismiss capture + VR; must NOT cancel the repair job.
    var onSubmitted: () -> Void

    @StateObject private var model = RepairManualCaptureModel()
    @State private var phase: RepairCameraPhase = .camera
    @State private var previewImage: UIImage?
    @State private var previewYaw: Float = 0
    @State private var previewElev: Float = 0
    @State private var showSoftWarning = false
    @State private var submitError: String?
    @State private var acceptNavigateTask: Task<Void, Never>?

    var body: some View {
        ZStack {
            if phase == .accepted {
                acceptedLayer
            } else if phase == .preview || phase == .uploading, let previewImage {
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
            acceptNavigateTask?.cancel()
            // Never cancel the server job — only release camera hardware.
            if phase == .uploading || phase == .accepted {
                model.stop()
            } else {
                model.cancelAndStop()
            }
        }
    }

    private var acceptedLayer: some View {
        ZStack {
            if let previewImage {
                Image(uiImage: previewImage)
                    .resizable()
                    .scaledToFill()
                    .ignoresSafeArea()
                    .opacity(0.35)
            }
            Color.black.opacity(0.55).ignoresSafeArea()
            VStack(spacing: 12) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 44))
                    .foregroundStyle(Color.green.opacity(0.95))
                Text("수정을 시작했어요")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.white)
                Text("완료되면 보관함에서 확인할 수 있어요.")
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.88))
                    .multilineTextAlignment(.center)
            }
            .padding(28)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("수정을 시작했어요. 완료되면 보관함에서 확인할 수 있어요.")
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
                    guard phase == .preview || phase == .camera else { return }
                    model.cancelAndStop()
                    onCancel()
                }
                .buttonStyle(.bordered)
                .disabled(phase == .uploading || phase == .accepted)

                Button("다시 촬영") {
                    GonggiHaptics.light()
                    guard phase == .preview else { return }
                    previewImage = nil
                    phase = .camera
                    model.retake()
                }
                .buttonStyle(.bordered)
                .disabled(phase == .uploading || phase == .accepted)

                Button("이 사진으로 수정") {
                    GonggiHaptics.medium()
                    Task { await submit(image: image) }
                }
                .buttonStyle(.borderedProminent)
                .disabled(phase == .uploading || phase == .accepted)
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
                repairMode: "marked_region_direct_edit"
            )
            // Gate: 202 create + durable store upsert already done inside submitRepair.
            guard SpaceRepairStore.shared.job(repairJobId: job.repairJobId) != nil else {
                phase = .preview
                model.start()
                submitError = "수정 요청을 저장하지 못했어요. 다시 시도해주세요."
                return
            }
            await SpaceRepairRuntime.shared.ensurePolling(
                repairJobId: job.repairJobId,
                sessionId: job.sessionId
            )
            GonggiHaptics.success()
            phase = .accepted
            acceptNavigateTask?.cancel()
            acceptNavigateTask = Task { @MainActor in
                try? await Task.sleep(nanoseconds: RepairAcceptedNavigation.autoDismissDelayNanoseconds)
                guard !Task.isCancelled else { return }
                // Leave capture + VR; polling continues in SpaceRepairRuntime (not cancelled).
                onSubmitted()
            }
        } catch {
            // POST failed — stay on preview; do not auto-dismiss.
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
    var maskRadiusYawDeg: Float
    var maskRadiusPitchDeg: Float
    var onViewerReady: (() -> Void)? = nil
    var onLongPress: (Float, Float) -> Void

    func makeUIView(context: Context) -> SCNHostView {
        let host = SCNHostView()
        host.onLongPressEquirect = onLongPress
        host.configure(imageURL: imageURL)
        host.updateSelection(
            yawDeg: markerYawDeg,
            pitchDeg: markerPitchDeg,
            radiusYawDeg: maskRadiusYawDeg,
            radiusPitchDeg: maskRadiusPitchDeg
        )
        context.coordinator.lastGeneration = textureGeneration
        context.coordinator.lastURL = imageURL
        // Defer one runloop so the SCNView is in the hierarchy / first frame can paint.
        DispatchQueue.main.async {
            context.coordinator.didNotifyReady = true
            onViewerReady?()
        }
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
        uiView.updateSelection(
            yawDeg: markerYawDeg,
            pitchDeg: markerPitchDeg,
            radiusYawDeg: maskRadiusYawDeg,
            radiusPitchDeg: maskRadiusPitchDeg
        )
        if !context.coordinator.didNotifyReady {
            context.coordinator.didNotifyReady = true
            DispatchQueue.main.async {
                onViewerReady?()
            }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var lastGeneration: Int = -1
        var lastURL: URL?
        var didNotifyReady = false
    }
}

final class SCNHostView: UIView {
    private let scnView = SCNView()
    private var cameraNode: SCNNode?
    private var sphereNode: SCNNode?
    private var markerNode: SCNNode?
    private var maskOutlineNode: SCNNode?
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

    /// Target marker + elliptical mask outline on the inside-out sphere (debug / selection preview).
    func updateSelection(
        yawDeg: Float?,
        pitchDeg: Float?,
        radiusYawDeg: Float,
        radiusPitchDeg: Float
    ) {
        markerNode?.removeFromParentNode()
        markerNode = nil
        maskOutlineNode?.removeFromParentNode()
        maskOutlineNode = nil
        guard let yawDeg, let pitchDeg, let scene = scnView.scene else { return }

        let r: Float = 9.2
        let p = VRSphereEquirectBridge.insideOutSpherePoint(
            yawDeg: yawDeg,
            pitchDeg: pitchDeg,
            radius: r
        )
        let marker = SCNNode(geometry: SCNSphere(radius: 0.12))
        marker.geometry?.firstMaterial?.diffuse.contents = UIColor.systemYellow
        marker.geometry?.firstMaterial?.emission.contents = UIColor.systemYellow
        marker.position = SCNVector3(p.x, p.y, p.z)
        scene.rootNode.addChildNode(marker)
        markerNode = marker

        let outline = SCNNode()
        outline.name = "repairMaskOutline"
        let rim = VRSphereEquirectBridge.maskOutlineEquirectPoints(
            centerYawDeg: yawDeg,
            centerPitchDeg: pitchDeg,
            radiusYawDeg: radiusYawDeg,
            radiusPitchDeg: radiusPitchDeg,
            samples: 56
        )
        for (i, pt) in rim.enumerated() {
            let wp = VRSphereEquirectBridge.insideOutSpherePoint(
                yawDeg: pt.yawDeg,
                pitchDeg: pt.pitchDeg,
                radius: r
            )
            let bead = SCNNode(geometry: SCNSphere(radius: 0.045))
            bead.geometry?.firstMaterial?.diffuse.contents = UIColor.systemPink.withAlphaComponent(0.9)
            bead.geometry?.firstMaterial?.emission.contents = UIColor.systemPink.withAlphaComponent(0.55)
            bead.position = SCNVector3(wp.x, wp.y, wp.z)
            outline.addChildNode(bead)

            let next = rim[(i + 1) % rim.count]
            let np = VRSphereEquirectBridge.insideOutSpherePoint(
                yawDeg: next.yawDeg,
                pitchDeg: next.pitchDeg,
                radius: r
            )
            let mid = SIMD3((wp.x + np.x) * 0.5, (wp.y + np.y) * 0.5, (wp.z + np.z) * 0.5)
            let dist = simd_length(SIMD3(np.x - wp.x, np.y - wp.y, np.z - wp.z))
            guard dist > 1e-4 else { continue }
            let cyl = SCNCylinder(radius: 0.018, height: CGFloat(dist))
            cyl.firstMaterial?.diffuse.contents = UIColor.systemPink.withAlphaComponent(0.75)
            cyl.firstMaterial?.emission.contents = UIColor.systemPink.withAlphaComponent(0.35)
            let seg = SCNNode(geometry: cyl)
            seg.position = SCNVector3(mid.x, mid.y, mid.z)
            seg.look(at: SCNVector3(np.x, np.y, np.z), up: SCNVector3(0, 1, 0), localFront: SCNVector3(0, 1, 0))
            outline.addChildNode(seg)
        }
        scene.rootNode.addChildNode(outline)
        maskOutlineNode = outline
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

        // Preferred: texture UV under finger (ground truth for displayed latlong).
        let hits = scnView.hitTest(point, options: [
            .searchMode: SCNHitTestSearchMode.closest.rawValue,
            .boundingBoxOnly: false
        ])
        let sphereHit = hits.first { $0.node.name == "sphere" || $0.node == sphereNode }

        let yawDeg: Float
        let pitchDeg: Float
        let source: String
        if let hit = sphereHit {
            let uv = hit.textureCoordinates(withMappingChannel: 0)
            let eq = VRSphereEquirectBridge.equirectDegreesFromTextureUV(
                u: Float(uv.x),
                v: Float(uv.y)
            )
            yawDeg = eq.yawDeg
            pitchDeg = eq.pitchDeg
            source = "hitTestUV"
            #if DEBUG
            let local = hit.localCoordinates
            let rawLon = atan2(Float(local.x), Float(local.z)) * 180 / .pi
            print(
                """
                [repair-bridge] source=\(source) \
                camYawDeg=\(yaw * 180 / .pi) camPitchDeg=\(pitch * 180 / .pi) \
                hitLocal=(\(local.x),\(local.y),\(local.z)) rawAtan2XZ=\(rawLon) \
                uv=(\(uv.x),\(uv.y)) bridgedYaw=\(yawDeg) bridgedPitch=\(pitchDeg)
                """
            )
            #endif
        } else {
            let eq = VRSphereEquirectBridge.equirectDegreesFromScreenPoint(
                point: point,
                viewSize: scnView.bounds.size,
                cameraYawRad: yaw,
                cameraPitchRad: pitch,
                fieldOfViewDeg: 70
            )
            yawDeg = eq.yawDeg
            pitchDeg = eq.pitchDeg
            source = "cameraFallback"
            #if DEBUG
            print(
                """
                [repair-bridge] source=\(source) \
                camYawDeg=\(yaw * 180 / .pi) camPitchDeg=\(pitch * 180 / .pi) \
                bridgedYaw=\(yawDeg) bridgedPitch=\(pitchDeg)
                """
            )
            #endif
        }
        _ = source
        onLongPressEquirect?(yawDeg, pitchDeg)
    }
}
