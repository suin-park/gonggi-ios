import AVFoundation
import PhotosUI
import SwiftUI
import UIKit

/// Phase 3B create state machine (Meshy wait lives in Library, not this sheet).
enum Image3DCreatePhase: Equatable {
    case idle
    case choosingSource
    case loadingImage
    case preview
    case normalizing
    case requestingPresign
    case uploading(progress: Double?)
    case submitting
    case accepted
    case failed(message: String)
}

@MainActor
final class Image3DCreateViewModel: ObservableObject {
    @Published var phase: Image3DCreatePhase = .choosingSource
    @Published var previewImage: UIImage?
    @Published var guidanceVisible = true
    @Published var isSubmitDisabled = false
    @Published var uploadFraction: Double?

    /// Same intent keeps this UUID across network ambiguity retries.
    private(set) var clientRequestId: String = UUID().uuidString
    private var normalizedJPEG: Data?
    private var sourceKey: String?
    private let api: MobileImage3DAPIClient
    private let generationStore: AssetGenerationStore

    init(
        api: MobileImage3DAPIClient = MobileImage3DAPIClient(),
        generationStore: AssetGenerationStore = .shared
    ) {
        self.api = api
        self.generationStore = generationStore
    }

    var statusLine: String? {
        switch phase {
        case .loadingImage: return "사진을 불러오는 중…"
        case .normalizing: return "사진을 준비하는 중…"
        case .requestingPresign: return "업로드를 준비하는 중…"
        case .uploading(let p):
            if let p {
                return "사진 업로드 중 \(Int((p * 100).rounded()))%"
            }
            return "사진 업로드 중…"
        case .submitting: return "3D 생성을 시작하는 중…"
        case .failed(let m): return m
        default: return nil
        }
    }

    func resetIntent() {
        clientRequestId = UUID().uuidString
        normalizedJPEG = nil
        sourceKey = nil
        isSubmitDisabled = false
        uploadFraction = nil
    }

    func setPickedImage(_ image: UIImage) {
        previewImage = image
        phase = .preview
        normalizedJPEG = nil
        sourceKey = nil
        // New photo within same sheet before submit → new intent.
        if !isSubmitDisabled {
            clientRequestId = UUID().uuidString
        }
    }

    func beginSubmit() {
        guard !isSubmitDisabled else { return }
        guard previewImage != nil else { return }
        isSubmitDisabled = true
        Task { await runPipeline() }
    }

    /// Upload/network failure before accepted: keep clientRequestId.
    func retrySameIntent() {
        guard case .failed = phase else { return }
        isSubmitDisabled = true
        Task { await runPipeline() }
    }

    /// Explicit user retry after generation failed (Library card) uses a fresh id.
    func beginFreshIntent(with image: UIImage, jpeg: Data?) {
        resetIntent()
        previewImage = image
        normalizedJPEG = jpeg
        phase = .preview
        isSubmitDisabled = true
        Task { await runPipeline() }
    }

    func cancelToChoosing() {
        phase = .choosingSource
        previewImage = nil
        normalizedJPEG = nil
        sourceKey = nil
        isSubmitDisabled = false
        uploadFraction = nil
        clientRequestId = UUID().uuidString
    }

    private func runPipeline() async {
        do {
            if normalizedJPEG == nil {
                phase = .normalizing
                guard let image = previewImage else {
                    throw MobileImage3DAPIError.invalidSource(code: "NO_IMAGE", message: "사진을 선택해주세요")
                }
                let result = try await Image3DSourceImageNormalizer.normalizeAsync(image)
                normalizedJPEG = result.jpegData
            }
            guard let jpeg = normalizedJPEG else {
                throw MobileImage3DAPIError.invalidSource(code: "NO_JPEG", message: "사진을 준비하지 못했어요")
            }

            // Presign + PUT (retry on 403 with new presign, same JPEG + same clientRequestId).
            var putAttempts = 0
            while true {
                putAttempts += 1
                phase = .requestingPresign
                let presign = try await api.presign(contentType: "image/jpeg", contentLength: jpeg.count)
                sourceKey = presign.sourceKey
                phase = .uploading(progress: nil)
                uploadFraction = nil
                do {
                    try await api.putJPEG(uploadUrl: presign.uploadUrl, data: jpeg, headers: presign.headers)
                    break
                } catch let err as MobileImage3DAPIError {
                    if case .server(let code, _, let status) = err, (code == "PRESIGN_EXPIRED" || status == 403), putAttempts < 3 {
                        continue
                    }
                    // Spec: upload failure copy before generation POST.
                    throw MobileImage3DAPIError.server(
                        code: "UPLOAD_FAILED",
                        message: "사진을 업로드하지 못했어요",
                        status: 0
                    )
                } catch {
                    throw MobileImage3DAPIError.server(
                        code: "UPLOAD_FAILED",
                        message: "사진을 업로드하지 못했어요",
                        status: 0
                    )
                }
            }

            guard let key = sourceKey else {
                throw MobileImage3DAPIError.invalidResponse
            }

            phase = .submitting
            let response = try await api.startGeneration(
                sourceKey: key,
                clientRequestId: clientRequestId
            )
            generationStore.upsertAccepted(response, sourceThumbJPEG: jpeg)
            phase = .accepted
        } catch let err as MobileImage3DAPIError {
            #if DEBUG
            print("[Image3DCreate] fail code path (no secrets) idSuffix=\(String(clientRequestId.suffix(6)))")
            #endif
            phase = .failed(message: err.userMessage)
            isSubmitDisabled = false
        } catch {
            phase = .failed(message: "사진을 업로드하지 못했어요")
            isSubmitDisabled = false
        }
    }
}

// MARK: - Flow UI

struct CreateAssetFlowView: View {
    var onClose: () -> Void
    var onAccepted: (() -> Void)? = nil
    /// Explicit generation retry: new clientRequestId; optional reused JPEG.
    var retrySourceImage: UIImage? = nil
    var retryJPEG: Data? = nil

    @StateObject private var model = Image3DCreateViewModel()
    @State private var showCamera = false
    @State private var showCameraDenied = false
    @State private var photoItem: PhotosPickerItem?
    @State private var didApplyRetry = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                switch model.phase {
                case .choosingSource, .idle:
                    sourceChooser
                case .loadingImage:
                    ProgressView("사진을 불러오는 중…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                case .preview, .normalizing, .requestingPresign, .uploading, .submitting, .failed:
                    previewPane
                case .accepted:
                    Color.clear.onAppear {
                        onAccepted?()
                        onClose()
                    }
                }
            }
            .background(GonggiAmbientBackground(showGlow: false))
            .navigationTitle("새 3D 어셋 만들기")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("닫기") { onClose() }
                        .foregroundStyle(GonggiColors.textSecondary)
                        .disabled(isBusy)
                }
            }
            .onAppear {
                guard !didApplyRetry, let retrySourceImage else { return }
                didApplyRetry = true
                model.beginFreshIntent(with: retrySourceImage, jpeg: retryJPEG)
            }
            .fullScreenCover(isPresented: $showCamera) {
                Image3DCameraPicker(
                    onCapture: { image in
                        showCamera = false
                        model.setPickedImage(image)
                    },
                    onCancel: { showCamera = false }
                )
                .ignoresSafeArea()
            }
            .alert("카메라 접근이 필요해요", isPresented: $showCameraDenied) {
                Button("설정 열기") {
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        UIApplication.shared.open(url)
                    }
                }
                Button("닫기", role: .cancel) {}
            } message: {
                Text("설정에서 카메라 접근을 허용한 뒤 다시 시도해주세요.")
            }
            .onChange(of: photoItem) { _, item in
                guard let item else { return }
                model.phase = .loadingImage
                Task {
                    do {
                        if let data = try await item.loadTransferable(type: Data.self),
                           let image = UIImage(data: data) {
                            model.setPickedImage(image)
                        } else {
                            model.phase = .failed(message: "사진을 불러오지 못했어요")
                        }
                    } catch {
                        model.phase = .failed(message: "사진을 불러오지 못했어요")
                    }
                    photoItem = nil
                }
            }
        }
    }

    private var isBusy: Bool {
        switch model.phase {
        case .normalizing, .requestingPresign, .uploading, .submitting: return true
        default: return false
        }
    }

    private var sourceChooser: some View {
        VStack(alignment: .leading, spacing: GonggiSpacing.lg) {
            Text("물체가 화면 중앙에 잘 보이는 사진을 사용하면\n더 좋은 3D 결과를 얻을 수 있어요.")
                .font(GonggiTypography.caption(14))
                .foregroundStyle(GonggiColors.textSecondary)
                .lineSpacing(3)

            sourceRow(title: "사진 촬영", subtitle: "카메라로 한 장 찍기", icon: "camera") {
                requestCamera()
            }
            PhotosPicker(selection: $photoItem, matching: .images, photoLibrary: .shared()) {
                sourceRowLabel(title: "사진 보관함", subtitle: "앨범에서 한 장 선택", icon: "photo.on.rectangle")
            }
            .buttonStyle(GonggiPressableStyle())

            Spacer()
        }
        .padding(GonggiSpacing.lg)
    }

    private var previewPane: some View {
        VStack(alignment: .leading, spacing: GonggiSpacing.lg) {
            Text("물체가 화면 중앙에 잘 보이는 사진을 사용하면\n더 좋은 3D 결과를 얻을 수 있어요.")
                .font(GonggiTypography.caption(14))
                .foregroundStyle(GonggiColors.textSecondary)
                .lineSpacing(3)

            ZStack {
                RoundedRectangle(cornerRadius: GonggiRadius.xl, style: .continuous)
                    .fill(GonggiColors.surface)
                    .frame(maxWidth: .infinity)
                    .frame(height: 280)
                if let previewImage = model.previewImage {
                    Image(uiImage: previewImage)
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: .infinity)
                        .frame(height: 280)
                        .clipShape(RoundedRectangle(cornerRadius: GonggiRadius.xl, style: .continuous))
                }
            }

            if let line = model.statusLine {
                HStack(spacing: GonggiSpacing.sm) {
                    if isBusy { ProgressView().tint(GonggiColors.accentTeal) }
                    Text(line)
                        .font(GonggiTypography.caption(14))
                        .foregroundStyle(GonggiColors.textSecondary)
                }
            }

            if case .failed(let message) = model.phase {
                Text(message)
                    .font(GonggiTypography.body(15))
                    .foregroundStyle(GonggiColors.textPrimary)
                PrimaryButton(title: "다시 시도", icon: "arrow.clockwise") {
                    GonggiHaptics.light()
                    model.retrySameIntent()
                }
                SecondaryButton(title: "취소") {
                    model.cancelToChoosing()
                }
            } else {
                PrimaryButton(title: "3D로 만들기", icon: "cube.transparent") {
                    GonggiHaptics.medium()
                    model.beginSubmit()
                }
                .disabled(model.isSubmitDisabled || isBusy)
                .opacity(model.isSubmitDisabled || isBusy ? 0.45 : 1)

                HStack(spacing: GonggiSpacing.md) {
                    SecondaryButton(title: "다시 촬영") {
                        model.cancelToChoosing()
                        requestCamera()
                    }
                    .disabled(isBusy)
                    PhotosPicker(selection: $photoItem, matching: .images) {
                        Text("다른 사진 선택")
                            .font(GonggiTypography.body(15))
                            .foregroundStyle(GonggiColors.accentTeal)
                    }
                    .disabled(isBusy)
                }
                SecondaryButton(title: "취소") {
                    onClose()
                }
                .disabled(isBusy)

                Text("앱을 닫아도 3D 생성은 계속돼요.")
                    .font(GonggiTypography.caption(12))
                    .foregroundStyle(GonggiColors.textTertiary)
            }

            Spacer(minLength: 0)
        }
        .padding(GonggiSpacing.lg)
    }

    private func sourceRow(title: String, subtitle: String, icon: String, action: @escaping () -> Void) -> some View {
        Button {
            GonggiHaptics.medium()
            action()
        } label: {
            sourceRowLabel(title: title, subtitle: subtitle, icon: icon)
        }
        .buttonStyle(GonggiPressableStyle())
    }

    private func sourceRowLabel(title: String, subtitle: String, icon: String) -> some View {
        HStack(spacing: GonggiSpacing.md) {
            Image(systemName: icon)
                .font(.system(size: 22, weight: .light))
                .foregroundStyle(GonggiColors.accentTeal)
                .frame(width: 40)
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(GonggiTypography.body(16))
                    .foregroundStyle(GonggiColors.textPrimary)
                Text(subtitle)
                    .font(GonggiTypography.caption(13))
                    .foregroundStyle(GonggiColors.textSecondary)
            }
            Spacer()
            Image(systemName: "chevron.right")
                .foregroundStyle(GonggiColors.textTertiary)
        }
        .padding(GonggiSpacing.md)
        .background(GonggiColors.surfaceElevated.opacity(0.75))
        .clipShape(RoundedRectangle(cornerRadius: GonggiRadius.md, style: .continuous))
    }

    private func requestCamera() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            showCamera = true
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { ok in
                DispatchQueue.main.async {
                    if ok { showCamera = true } else { showCameraDenied = true }
                }
            }
        default:
            showCameraDenied = true
        }
    }
}

// MARK: - Camera (single still — not SpaceRecord / Quick360)

struct Image3DCameraPicker: UIViewControllerRepresentable {
    var onCapture: (UIImage) -> Void
    var onCancel: () -> Void

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.allowsEditing = false
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(onCapture: onCapture, onCancel: onCancel)
    }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let onCapture: (UIImage) -> Void
        let onCancel: () -> Void

        init(onCapture: @escaping (UIImage) -> Void, onCancel: @escaping () -> Void) {
            self.onCapture = onCapture
            self.onCancel = onCancel
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            onCancel()
        }

        func imagePickerController(
            _ picker: UIImagePickerController,
            didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]
        ) {
            if let image = info[.originalImage] as? UIImage {
                onCapture(image)
            } else {
                onCancel()
            }
        }
    }
}
