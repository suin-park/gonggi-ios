import ARKit
import OSLog
import SwiftUI

@MainActor
final class ProcessingViewModel: ObservableObject {
    @Published var status: GenerationJobStatus?
    @Published var errorMessage: String?
    @Published var isComplete = false
    /// Async handoff: upload+start succeeded — leave Processing UI for Library.
    @Published var handoff: (jobId: String, spaceId: String)?

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
        pollTask?.cancel()
        pollTask = Task {
            var generation = CaptureGenerationDiagnostics.empty

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
                        throw SpaceGenerationError.unknown("촬영 동영상(original.mov)을 찾을 수 없어요. 다시 촬영해 주세요.")
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

                let idempotencyKey = "gonggi-\(UUID().uuidString)"
                generation.idempotencyKey = idempotencyKey
                persistGeneration()

                var request = createRequest
                request.idempotencyKey = idempotencyKey
                let created = try await spaceService.createSpace(request)
                generation.createStatus = 200
                generation.idempotencyKey = created.idempotencyKey ?? idempotencyKey
                persistGeneration()

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
                generation.uploadFinished = true
                persistGeneration()

                GaussianGenerationStore.shared.applyRemote(
                    spaceId: created.spaceId,
                    status: "queued",
                    stage: "package_uploaded",
                    progress: 0.15,
                    failureCode: nil
                )

                try await spaceService.startGeneration(jobId: created.jobId)
                generation.generationStarted = true
                persistGeneration()

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
            } catch {
                if let gen = error as? SpaceGenerationError {
                    if let status = gen.httpStatus {
                        generation.createStatus = status
                    }
                    generation.backendErrorCode = gen.backendErrorCode
                } else {
                    generation.backendErrorCode = error.localizedDescription
                }
                persistGeneration()
                SpaceGenerationErrorPresenter.logFailure(
                    error: error,
                    requestProfile: generation.createRequestProfile ?? qualityProfile,
                    idempotencyKey: generation.idempotencyKey
                )
                log.error(
                    "create/upload/start failed code=\(generation.backendErrorCode ?? "nil", privacy: .public)"
                )
                errorMessage = SpaceGenerationErrorPresenter.userMessage(for: error)
            }
        }
    }

    var completedSpaceId: String?

    func cancel() {
        pollTask?.cancel()
    }
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
    @State private var showDiagShare = false
    @State private var diagShareItems: [URL] = []
    @State private var diagShareError: String?

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
                    if let status = viewModel.status {
                        progressHero(status.overallProgress)
                        stepsList(status.steps)
                        if let mins = status.estimatedMinutesRemaining, mins > 0 {
                            estimatedTimeBanner(minutes: mins)
                        }
                    } else if let err = viewModel.errorMessage {
                        errorBanner(err)
                        SecondaryButton(title: "촬영 진단 공유", icon: "square.and.arrow.up") {
                            shareDiagnostics()
                        }
                        if let diagShareError {
                            Text(diagShareError)
                                .font(GonggiTypography.caption(12))
                                .foregroundStyle(GonggiColors.warning)
                        }
                    } else {
                        loadingState
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
            .navigationTitle("3DGS 생성")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("닫기") { onDismiss() }
                        .foregroundStyle(GonggiColors.textSecondary)
                }
            }
        }
        .sheet(isPresented: $showDiagShare) {
            CaptureExportShareSheet(items: diagShareItems) {
                showDiagShare = false
            }
        }
        .onAppear {
            #if DEBUG
            if let frozen = screenshotFrozenStatus {
                viewModel.status = frozen
                return
            }
            #endif
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
        .onDisappear { viewModel.cancel() }
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
            diagShareError = "진단 공유 준비에 실패했어요."
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: GonggiSpacing.sm) {
            Text("「\(summary.suggestedName)」")
                .font(GonggiTypography.headline(18))
                .foregroundStyle(GonggiColors.accentTeal)
            Text("공간을 생성하고 있어요")
                .font(GonggiTypography.title(26))
                .foregroundStyle(GonggiColors.textPrimary)
            Text("촬영한 기억을 입체 공간으로 바꾸고 있어요.\n잠시만 기다려 주세요.")
                .font(GonggiTypography.body(15))
                .foregroundStyle(GonggiColors.textSecondary)
                .lineSpacing(4)
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
            Text("진행 단계")
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

    private var loadingState: some View {
        HStack(spacing: GonggiSpacing.md) {
            ProgressView()
                .tint(GonggiColors.accentTeal)
            Text("준비하고 있어요…")
                .font(GonggiTypography.body(15))
                .foregroundStyle(GonggiColors.textSecondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(GonggiSpacing.lg)
        .background(GonggiColors.surfaceElevated)
        .clipShape(RoundedRectangle(cornerRadius: GonggiRadius.md, style: .continuous))
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
