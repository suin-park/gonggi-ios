import ARKit
import OSLog
import SwiftUI
import UIKit

@MainActor
final class ProcessingViewModel: ObservableObject {
    @Published var status: GenerationJobStatus?
    @Published var pipelineSteps: [ClientPipelineStepState] = ClientGenerationPipelineStep.allCases.map {
        ClientPipelineStepState(kind: $0, status: .waiting)
    }
    @Published var errorMessage: String?
    @Published var isComplete = false
    /// Async handoff: upload+start succeeded — leave Processing UI for Library.
    @Published var handoff: (jobId: String, spaceId: String)?
    /// Same-capture retry only when original package/video is still on device.
    @Published private(set) var canRetrySameCapture = false
    @Published private(set) var isRunning = false

    private let spaceService: SpaceGenerationService
    private var pollTask: Task<Void, Never>?
    private let log = Logger(subsystem: "com.whik.gonggi", category: "Processing")

    init(spaceService: SpaceGenerationService) {
        self.spaceService = spaceService
    }

    func start(
        summary: CaptureSessionSummary,
        qualityProfile: String = "capture_dense_v2",
        allowStubVideoInMock: Bool = false
    ) {
        // Cancel local work only — never DELETE the server draft job (idempotent retry reuses it).
        pollTask?.cancel()
        pollTask = nil

        errorMessage = nil
        handoff = nil
        isComplete = false
        canRetrySameCapture = false
        isRunning = true
        resetPipelineSteps()

        pollTask = Task { [weak self] in
            guard let self else { return }
            // Keep create → upload → start running when the app is backgrounded or the screen
            // locks, for as long as iOS allows. If iOS ends the time, the upload is cancelled,
            // the card shows "업로드 중단" and the same capture can be retried from Library.
            let background = UploadBackgroundTask(name: "gonggi.3d-record.upload") { [weak self] in
                self?.cancel()
            }
            defer { background.end() }
            await self.runPipeline(
                summary: summary,
                qualityProfile: qualityProfile,
                allowStubVideoInMock: allowStubVideoInMock
            )
        }
    }

    func retrySameCapture(
        summary: CaptureSessionSummary,
        qualityProfile: String,
        allowStubVideoInMock: Bool
    ) {
        guard canRetrySameCapture else { return }
        start(
            summary: summary,
            qualityProfile: qualityProfile,
            allowStubVideoInMock: allowStubVideoInMock
        )
    }

    /// Cancels in-flight upload/create Task. Preserves on-device capture and server draft job.
    func cancel() {
        pollTask?.cancel()
        pollTask = nil
        // isRunning stays true until the cancelled Task finishes cleanup (retry flags / copy).
    }

    private func runPipeline(
        summary: CaptureSessionSummary,
        qualityProfile: String,
        allowStubVideoInMock: Bool
    ) async {
        var generation = CaptureDiagnosticsStore.loadGenerationDiagnostics(sessionId: summary.sessionId)
        if generation.idempotencyKey == nil {
            generation = .empty
        }
        var currentStage: ClientGenerationPipelineStep = .preparePackage
        /// Set once the server job exists — Library card + active-upload tracking use it.
        var createdSpaceId: String?
        defer {
            if let createdSpaceId {
                GaussianGenerationStore.shared.endActiveUpload(spaceId: createdSpaceId)
            }
        }

        func persistGeneration() {
            CaptureDiagnosticsStore.writeGenerationDiagnostics(
                generation,
                sessionId: summary.sessionId
            )
        }

        do {
            let foundation = summary.dataFoundation
            let useSpatialPackage =
                GonggiFeatureFlags.show3DGSCaptureFlows
                && (foundation?.spatialCapturePackageValid == true)
            let packageRoot = foundation?.spatialCapturePackageURL
                ?? (try? CaptureSessionStore.spatialCapturePackageDirectory(sessionId: summary.sessionId))

            let packageRetained: Bool
            if useSpatialPackage {
                packageRetained = CapturePackageRetention.hasRetainedSpatialPackage(
                    sessionId: summary.sessionId,
                    packageRootHint: packageRoot
                )
                if !packageRetained {
                    canRetrySameCapture = false
                    setStep(.preparePackage, .failed("원본 없음"))
                    errorMessage = SpaceGenerationErrorPresenter.packageMissingUnrecoverable
                    isRunning = false
                    generation.failedStage = "prepare_package"
                    generation.backendErrorCode = "package_missing"
                    persistGeneration()
                    return
                }
            } else {
                packageRetained = CapturePackageRetention.hasRetainedVideo(
                    sessionId: summary.sessionId,
                    videoURL: summary.videoURL
                )
            }

            try Task.checkCancellation()
            currentStage = .preparePackage
            setStep(.preparePackage, .active(progress: nil))

            let uploadURL: URL
            let byteSize: Int
            let createRequest: CreateSpaceRequest
            let resolvedProfile: String
            var zipCreateSec: Double?

            if useSpatialPackage, let packageRoot {
                let zipDir = FileManager.default.temporaryDirectory
                    .appendingPathComponent("spatial-zip-\(UUID().uuidString)", isDirectory: true)
                let zipped = try SpatialCapturePackageZipper.buildArchive(
                    packageRoot: packageRoot,
                    destinationDirectory: zipDir
                )
                uploadURL = zipped.zipURL
                byteSize = zipped.byteSize
                zipCreateSec = zipped.createDurationSec
                resolvedProfile = ServerGenerationProfileMapper.spatialPackageProfile
                generation.createRequestProfile = resolvedProfile
                createRequest = CreateSpaceRequest(
                    name: summary.suggestedName,
                    visibility: "private",
                    videoByteSize: byteSize,
                    videoFilename: SpatialCapturePackageZipper.archiveFileName,
                    videoContentType: "application/zip",
                    durationSec: summary.duration,
                    qualityProfile: resolvedProfile,
                    idempotencyKey: nil,
                    frameCount: zipped.frameCount
                )
                log.info(
                    "spatial zip ready bytes=\(byteSize) frames=\(zipped.frameCount) createSec=\(zipped.createDurationSec)"
                )
            } else {
                resolvedProfile = ServerGenerationProfileMapper.resolveServerProfile(
                    guideQualityProfile: qualityProfile
                )
                generation.createRequestProfile = resolvedProfile

                let videoURL = summary.videoURL
                    ?? (try? CaptureSessionStore.videoURL(sessionId: summary.sessionId))
                let resolvedURL: URL? = {
                    guard let videoURL, FileManager.default.fileExists(atPath: videoURL.path) else {
                        return nil
                    }
                    return videoURL
                }()

                if let resolvedURL,
                   let attrs = try? FileManager.default.attributesOfItem(atPath: resolvedURL.path),
                   let size = (attrs[.size] as? NSNumber)?.intValue,
                   size > 1024 {
                    byteSize = size
                    uploadURL = resolvedURL
                } else if allowStubVideoInMock {
                    let tmp = FileManager.default.temporaryDirectory
                        .appendingPathComponent("mock-capture-\(UUID().uuidString).mov")
                    try Data(repeating: 0, count: 2048).write(to: tmp)
                    byteSize = 2048
                    uploadURL = tmp
                } else {
                    canRetrySameCapture = false
                    throw SpaceGenerationError.unknown(SpaceGenerationErrorPresenter.packageMissingUnrecoverable)
                }
                createRequest = CreateSpaceRequest(
                    name: summary.suggestedName,
                    visibility: "private",
                    videoByteSize: byteSize,
                    durationSec: summary.duration,
                    qualityProfile: resolvedProfile,
                    idempotencyKey: nil
                )
            }

            try Task.checkCancellation()
            setStep(.preparePackage, .completed)
            currentStage = .upload
            setStep(.upload, .active(progress: nil))

            let idempotencyKey = CapturePackageRetention.resolveIdempotencyKey(
                captureId: summary.captureId,
                sessionId: summary.sessionId
            )
            generation.idempotencyKey = idempotencyKey
            persistGeneration()

            var request = createRequest
            request.idempotencyKey = idempotencyKey
            let created = try await spaceService.createSpace(request)
            try Task.checkCancellation()
            generation.createStatus = 200
            generation.idempotencyKey = created.idempotencyKey ?? idempotencyKey
            generation.spaceId = created.spaceId
            generation.jobId = created.jobId
            persistGeneration()

            createdSpaceId = created.spaceId
            GaussianGenerationStore.shared.beginActiveUpload(spaceId: created.spaceId)
            guard created.uploadURL != nil else {
                throw SpaceGenerationError.uploadFailed
            }

            // Show in Library immediately (before upload finishes) as uploading.
            let thumb = packageRoot.flatMap { SpatialCaptureConfig.firstKeyframeJPEG(packageRoot: $0) }
            GaussianGenerationStore.shared.upsert(
                spaceId: created.spaceId,
                jobId: created.jobId,
                name: summary.suggestedName,
                qualityProfile: resolvedProfile,
                status: "uploading",
                captureId: summary.captureId,
                sessionId: summary.sessionId,
                stage: useSpatialPackage ? "uploading_package" : "uploading",
                progress: 0.05,
                thumbnailSourceJPEG: thumb
            )

            let meta = CaptureUploadMetadata(
                durationSec: summary.duration,
                coverage: summary.quality.overallCoverage,
                frameCount: summary.dataFoundation?.poseSamples
                    ?? Int(summary.duration * 30),
                deviceHasLiDAR: ARKitSupport.hasLiDAR,
                qualitySummary: [
                    "blur": summary.quality.blurScore,
                    "parallax": summary.quality.parallaxScore,
                    "viewAngleDiversity": summary.quality.viewAngleDiversity,
                    "overlapAvailable": summary.quality.overlapAvailable ? 1 : 0,
                    "maxBaselineM": summary.dataFoundation?.maxBaselineM ?? 0,
                    "zipCreateSec": zipCreateSec ?? -1,
                ]
            )
            generation.uploadStarted = true
            persistGeneration()
            try await spaceService.uploadCapture(
                UploadCaptureRequest(jobId: created.jobId, localCaptureURL: uploadURL, metadata: meta)
            )
            try Task.checkCancellation()
            generation.uploadFinished = true
            persistGeneration()
            setStep(.upload, .completed)

            GaussianGenerationStore.shared.applyRemote(
                spaceId: created.spaceId,
                status: "queued",
                stage: "package_uploaded",
                progress: 0.15,
                failureCode: nil
            )

            currentStage = .requestGeneration
            setStep(.requestGeneration, .active(progress: nil))
            try await spaceService.startGeneration(jobId: created.jobId)
            try Task.checkCancellation()
            generation.generationStarted = true
            generation.failedStage = nil
            generation.backendErrorCode = nil
            persistGeneration()
            setStep(.requestGeneration, .completed)

            GaussianGenerationStore.shared.applyRemote(
                spaceId: created.spaceId,
                status: "processing",
                stage: "queued",
                progress: 0.2,
                failureCode: nil
            )
            GaussianGenerationStore.shared.markHandedOff(spaceId: created.spaceId)

            // Async UX: do not wait on Processing screen for reconstruction.
            handoff = (created.jobId, created.spaceId)
            status = GenerationJobStatus(
                jobId: created.jobId,
                spaceId: created.spaceId,
                steps: [],
                estimatedMinutesRemaining: 8,
                overallProgress: 0.2
            )
            isRunning = false
            canRetrySameCapture = false
        } catch is CancellationError {
            generation.failedStage = "cancelled"
            generation.backendErrorCode = "cancelled"
            persistGeneration()
            failActiveStep(currentStage, message: "중단됨")
            if let createdSpaceId {
                GaussianGenerationStore.shared.markInterrupted(spaceId: createdSpaceId)
            }
            // Preserve original capture; allow resume when package still on device.
            canRetrySameCapture = CapturePackageRetention.hasRetainedSpatialPackage(
                sessionId: summary.sessionId,
                packageRootHint: summary.dataFoundation?.spatialCapturePackageURL
            ) || CapturePackageRetention.hasRetainedVideo(
                sessionId: summary.sessionId,
                videoURL: summary.videoURL
            )
            errorMessage = SpaceGenerationErrorPresenter.uploadCancelled
            isRunning = false
            log.info("pipeline cancelled captureId=\(summary.captureId, privacy: .public)")
        } catch {
            if let gen = error as? SpaceGenerationError {
                if let status = gen.httpStatus {
                    generation.createStatus = status
                }
                generation.backendErrorCode = gen.backendErrorCode
            } else {
                generation.backendErrorCode = error.localizedDescription
            }
            generation.failedStage = currentStage.diagnosticsStageName
            persistGeneration()
            // Library card shows the real state: a server-confirmed code (e.g. NATIVE_UNAVAILABLE)
            // or "업로드 중단" when the device never finished upload / start.
            if let createdSpaceId {
                if case .server(let code, _) = error as? SpaceGenerationError {
                    GaussianGenerationStore.shared.applyRemote(
                        spaceId: createdSpaceId, status: "failed", stage: nil, progress: 0, failureCode: code
                    )
                } else {
                    GaussianGenerationStore.shared.markInterrupted(spaceId: createdSpaceId)
                }
            }
            // Never delete Captures/{sessionId} on failure — original stays for retry.
            let retained = CapturePackageRetention.hasRetainedSpatialPackage(
                sessionId: summary.sessionId,
                packageRootHint: summary.dataFoundation?.spatialCapturePackageURL
            ) || CapturePackageRetention.hasRetainedVideo(
                sessionId: summary.sessionId,
                videoURL: summary.videoURL
            )
            canRetrySameCapture = retained
            let failLabel: String = {
                switch currentStage {
                case .preparePackage:
                    return "준비 실패"
                case .upload:
                    if case .uploadFailed = error as? SpaceGenerationError {
                        return "업로드 실패"
                    }
                    if SpaceGenerationErrorPresenter.looksLikeUploadNetworkLoss(error.localizedDescription) {
                        return "업로드 실패"
                    }
                    // createSpace failure while on upload stage
                    return "요청 실패"
                case .requestGeneration:
                    return "요청 실패"
                }
            }()
            failActiveStep(currentStage, message: failLabel)
            SpaceGenerationErrorPresenter.logFailure(
                error: error,
                requestProfile: generation.createRequestProfile ?? qualityProfile,
                idempotencyKey: generation.idempotencyKey
            )
            log.error(
                "create/upload/start failed stage=\(currentStage.diagnosticsStageName, privacy: .public) code=\(generation.backendErrorCode ?? "nil", privacy: .public)"
            )
            if retained {
                errorMessage = SpaceGenerationErrorPresenter.userMessage(for: error)
            } else {
                errorMessage = SpaceGenerationErrorPresenter.packageMissingUnrecoverable
            }
            isRunning = false
        }
    }

    private func resetPipelineSteps() {
        pipelineSteps = ClientGenerationPipelineStep.allCases.map {
            ClientPipelineStepState(kind: $0, status: .waiting)
        }
    }

    private func setStep(_ kind: ClientGenerationPipelineStep, _ status: ProcessingStepStatus) {
        guard let idx = pipelineSteps.firstIndex(where: { $0.kind == kind }) else { return }
        pipelineSteps[idx].status = status
    }

    private func failActiveStep(_ kind: ClientGenerationPipelineStep, message: String) {
        setStep(kind, .failed(message))
    }

    var completedSpaceId: String?
}

enum ARKitSupport {
    static var hasLiDAR: Bool {
        ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh)
    }
}

struct ProcessingView: View {
    let summary: CaptureSessionSummary
    let spaceService: SpaceGenerationService
    let qualityProfile: String
    let sourceLatLongSessionId: String?
    let allowStubVideoInMock: Bool
    let onComplete: (String, String) -> Void
    /// Called when upload+start succeeded — navigate to Library (async reconstruction).
    let onHandedOff: (String, String) -> Void
    let onDismiss: () -> Void
    /// DEBUG screenshot mode only — freezes UI without starting pipeline.
    private let screenshotFrozenStatus: GenerationJobStatus?

    @StateObject private var viewModel: ProcessingViewModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @State private var showDiagShare = false
    @State private var diagShareItems: [URL] = []
    @State private var diagShareError: String?
    @State private var showOriginalShare = false
    @State private var originalShareItems: [URL] = []
    @State private var originalShareError: String?
    @State private var isExportingOriginal = false
    @State private var didStart = false

    init(
        summary: CaptureSessionSummary,
        spaceService: SpaceGenerationService,
        qualityProfile: String = "capture_dense_v2",
        sourceLatLongSessionId: String? = nil,
        allowStubVideoInMock: Bool = false,
        screenshotFrozenStatus: GenerationJobStatus? = nil,
        onComplete: @escaping (String, String) -> Void,
        onHandedOff: @escaping (String, String) -> Void = { _, _ in },
        onDismiss: @escaping () -> Void
    ) {
        self.summary = summary
        self.spaceService = spaceService
        self.qualityProfile = qualityProfile
        self.sourceLatLongSessionId = sourceLatLongSessionId
        self.allowStubVideoInMock = allowStubVideoInMock
        self.screenshotFrozenStatus = screenshotFrozenStatus
        self.onComplete = onComplete
        self.onHandedOff = onHandedOff
        self.onDismiss = onDismiss
        _viewModel = StateObject(wrappedValue: ProcessingViewModel(spaceService: spaceService))
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: GonggiSpacing.xl) {
                    header
                    clientPipelineSection
                    if let status = viewModel.status {
                        progressHero(status.overallProgress)
                        if !status.steps.isEmpty {
                            stepsList(status.steps)
                        }
                        if let mins = status.estimatedMinutesRemaining, mins > 0 {
                            estimatedTimeBanner(minutes: mins)
                        }
                    } else if let err = viewModel.errorMessage {
                        errorBanner(err)
                        if viewModel.canRetrySameCapture {
                            PrimaryButton(title: "같은 촬영으로 다시 시도", icon: "arrow.clockwise") {
                                GonggiHaptics.light()
                                viewModel.retrySameCapture(
                                    summary: summary,
                                    qualityProfile: qualityProfile,
                                    allowStubVideoInMock: allowStubVideoInMock
                                )
                            }
                        }
                        SecondaryButton(title: "촬영 진단 공유 (사진 제외)", icon: "doc.text") {
                            shareDiagnostics()
                        }
                        if viewModel.canRetrySameCapture || CapturePackageRetention.hasRetainedSpatialPackage(
                            sessionId: summary.sessionId,
                            packageRootHint: summary.dataFoundation?.spatialCapturePackageURL
                        ) {
                            SecondaryButton(
                                title: isExportingOriginal ? "원본 패키지 준비 중…" : "원본 패키지 내보내기",
                                icon: "square.and.arrow.up"
                            ) {
                                shareOriginalPackage()
                            }
                            .disabled(isExportingOriginal)
                        }
                        if let diagShareError {
                            Text(diagShareError)
                                .font(GonggiTypography.caption(12))
                                .foregroundStyle(GonggiColors.warning)
                        }
                        if let originalShareError {
                            Text(originalShareError)
                                .font(GonggiTypography.caption(12))
                                .foregroundStyle(GonggiColors.warning)
                        }
                    }

                    if viewModel.isComplete,
                       let spaceId = viewModel.completedSpaceId {
                        let jobId = viewModel.status?.jobId ?? spaceId
                        PrimaryButton(title: "3D 공간 둘러보기", icon: "move.3d") {
                            GonggiHaptics.success()
                            onComplete(jobId, spaceId)
                        }
                        .padding(.top, GonggiSpacing.sm)
                    }
                }
                .padding(GonggiSpacing.lg)
                .padding(.bottom, GonggiSpacing.xxl)
            }
            .background(GonggiAmbientBackground(showGlow: false))
            .navigationTitle("3D 공간 기록")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("닫기") {
                        onDismiss()
                    }
                    .foregroundStyle(GonggiColors.textSecondary)
                }
            }
        }
        .sheet(isPresented: $showDiagShare) {
            CaptureExportShareSheet(items: diagShareItems) {
                showDiagShare = false
            }
        }
        .sheet(isPresented: $showOriginalShare) {
            CaptureExportShareSheet(items: originalShareItems) {
                showOriginalShare = false
            }
        }
        .onAppear {
            #if DEBUG
            if let frozen = screenshotFrozenStatus {
                viewModel.status = frozen
                return
            }
            #endif
            guard !didStart else { return }
            didStart = true
            viewModel.start(
                summary: summary,
                qualityProfile: qualityProfile,
                allowStubVideoInMock: allowStubVideoInMock
            )
        }
        .onChange(of: viewModel.handoff?.spaceId) { _, spaceId in
            guard let spaceId, let handoff = viewModel.handoff else { return }
            GonggiHaptics.success()
            onHandedOff(handoff.jobId, spaceId)
        }
        // Leaving the screen / app does not cancel the upload: it continues under a background
        // task while iOS allows it; the Library card tracks it (업로드 중 → 생성 중 / 업로드 중단).
    }

    private func shareDiagnostics() {
        diagShareError = nil
        do {
            let folder = try CaptureDiagnosticsStore.buildSharePackage(
                sessionId: summary.sessionId,
                captureId: summary.captureId,
                includeVideo: false
            )
            diagShareItems = [folder]
            showDiagShare = true
        } catch {
            diagShareError = "진단 공유 준비에 실패했어요. (원본 사진은 포함되지 않습니다)"
        }
    }

    private func shareOriginalPackage() {
        originalShareError = nil
        isExportingOriginal = true
        let sessionId = summary.sessionId
        let captureId = summary.captureId
        Task {
            defer { isExportingOriginal = false }
            do {
                let folder = try await Task.detached(priority: .userInitiated) {
                    try CaptureDiagnosticsStore.buildFullSpatialPackageShare(
                        sessionId: sessionId,
                        captureId: captureId
                    )
                }.value
                originalShareItems = [folder]
                showOriginalShare = true
            } catch {
                originalShareError = "원본 패키지를 내보낼 수 없어요. 패키지가 완전한지 확인해 주세요."
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: GonggiSpacing.sm) {
            Text("「\(summary.suggestedName)」")
                .font(GonggiTypography.headline(18))
                .foregroundStyle(GonggiColors.accentTeal)
            Text(viewModel.errorMessage == nil ? "공간을 생성하고 있어요" : "생성을 완료하지 못했어요")
                .font(GonggiTypography.title(26))
                .foregroundStyle(GonggiColors.textPrimary)
            Text(
                viewModel.errorMessage == nil
                    ? "패키지를 준비하고 업로드한 뒤 생성 요청을 보낼게요."
                    : "원본 촬영 데이터는 실패 후에도 기기에 남아 있어요."
            )
                .font(GonggiTypography.body(15))
                .foregroundStyle(GonggiColors.textSecondary)
                .lineSpacing(4)
        }
    }

    private var clientPipelineSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("진행 단계")
                .font(GonggiTypography.caption(13))
                .foregroundStyle(GonggiColors.textTertiary)
                .padding(.bottom, GonggiSpacing.sm)
            GonggiElevatedCard {
                VStack(spacing: GonggiSpacing.md) {
                    ForEach(Array(viewModel.pipelineSteps.enumerated()), id: \.element.id) { index, step in
                        StatusStepRow(
                            title: step.kind.title,
                            status: step.status,
                            isLast: index == viewModel.pipelineSteps.count - 1
                        )
                    }
                }
            }
        }
    }

    private func progressHero(_ value: Double) -> some View {
        HStack(spacing: GonggiSpacing.lg) {
            ProgressRing(progress: value, lineWidth: 6, label: "전체", compact: true)
                .frame(width: 88, height: 88)
            VStack(alignment: .leading, spacing: GonggiSpacing.xs) {
                Text(viewModel.isComplete ? "완료되었어요" : "진행 중")
                    .font(GonggiTypography.headline(17))
                    .foregroundStyle(viewModel.isComplete ? GonggiColors.successGreen : GonggiColors.textPrimary)
                Text("전체 \(Int(value * 100))%")
                    .font(GonggiTypography.caption(14))
                    .foregroundStyle(GonggiColors.textSecondary)
            }
            Spacer(minLength: 0)
        }
        .padding(GonggiSpacing.md)
        .background(GonggiColors.surfaceElevated)
        .overlay(
            RoundedRectangle(cornerRadius: GonggiRadius.lg, style: .continuous)
                .stroke(GonggiColors.border, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: GonggiRadius.lg, style: .continuous))
        .animation(reduceMotion ? nil : GonggiMotion.standard, value: value)
    }

    private func stepsList(_ steps: [ProcessingStepState]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("서버 진행")
                .font(GonggiTypography.caption(13))
                .foregroundStyle(GonggiColors.textTertiary)
                .padding(.bottom, GonggiSpacing.sm)
            GonggiElevatedCard {
                VStack(spacing: GonggiSpacing.md) {
                    ForEach(Array(steps.enumerated()), id: \.element.id) { index, step in
                        StatusStepRow(
                            step: step,
                            isLast: index == steps.count - 1
                        )
                    }
                }
            }
        }
    }

    private func estimatedTimeBanner(minutes: Int) -> some View {
        HStack(spacing: GonggiSpacing.sm) {
            Image(systemName: "clock")
                .foregroundStyle(GonggiColors.accentTeal)
            Text("약 \(minutes)분 후에 완료될 예정이에요")
                .font(GonggiTypography.caption(14))
                .foregroundStyle(GonggiColors.textSecondary)
        }
        .padding(GonggiSpacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(GonggiColors.accentTeal.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: GonggiRadius.sm, style: .continuous))
    }

    private func errorBanner(_ message: String) -> some View {
        HStack(alignment: .top, spacing: GonggiSpacing.sm) {
            Image(systemName: "exclamationmark.circle.fill")
                .foregroundStyle(GonggiColors.error)
            Text(message)
                .font(GonggiTypography.caption(14))
                .foregroundStyle(GonggiColors.textSecondary)
        }
        .padding(GonggiSpacing.md)
        .background(GonggiColors.error.opacity(0.1))
        .clipShape(RoundedRectangle(cornerRadius: GonggiRadius.sm, style: .continuous))
    }
}

#Preview {
    ProcessingView(
        summary: GonggiPreviewSamples.sampleSummary,
        spaceService: MockSpaceGenerationService(),
        onComplete: { _, _ in },
        onDismiss: {}
    )
}
