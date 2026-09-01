import ARKit
import SwiftUI

@MainActor
final class ProcessingViewModel: ObservableObject {
    @Published var status: GenerationJobStatus?
    @Published var errorMessage: String?
    @Published var isComplete = false

    private let spaceService: SpaceGenerationService
    private var pollTask: Task<Void, Never>?

    init(spaceService: SpaceGenerationService) {
        self.spaceService = spaceService
    }

    func start(summary: CaptureSessionSummary) {
        pollTask?.cancel()
        pollTask = Task {
            do {
                let created = try await spaceService.createSpace(
                    CreateSpaceRequest(name: summary.suggestedName, visibility: "private")
                )
                let meta = CaptureUploadMetadata(
                    durationSec: summary.duration,
                    coverage: summary.quality.overallCoverage,
                    frameCount: Int(summary.duration * 30),
                    deviceHasLiDAR: ARKitSupport.hasLiDAR,
                    qualitySummary: [
                        "blur": summary.quality.blurScore,
                        "parallax": summary.quality.parallaxScore,
                        "overlap": summary.quality.overlapScore,
                    ]
                )
                let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("capture.mov")
                try? Data().write(to: tmp)
                try await spaceService.uploadCapture(
                    UploadCaptureRequest(jobId: created.jobId, localCaptureURL: tmp, metadata: meta)
                )
                try await spaceService.startGeneration(jobId: created.jobId)
                status = try await spaceService.fetchStatus(jobId: created.jobId)
                await poll(jobId: created.jobId, spaceId: created.spaceId)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func poll(jobId: String, spaceId: String) async {
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 800_000_000)
            guard let fetched = try? await spaceService.fetchStatus(jobId: jobId) else { continue }
            status = fetched
            if fetched.overallProgress >= 0.99 {
                isComplete = true
                completedSpaceId = spaceId
                break
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
    let onComplete: (String, String) -> Void
    let onDismiss: () -> Void
    /// DEBUG screenshot mode only — freezes UI without starting pipeline.
    private let screenshotFrozenStatus: GenerationJobStatus?

    @StateObject private var viewModel: ProcessingViewModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(
        summary: CaptureSessionSummary,
        spaceService: SpaceGenerationService,
        screenshotFrozenStatus: GenerationJobStatus? = nil,
        onComplete: @escaping (String, String) -> Void,
        onDismiss: @escaping () -> Void
    ) {
        self.summary = summary
        self.spaceService = spaceService
        self.screenshotFrozenStatus = screenshotFrozenStatus
        self.onComplete = onComplete
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
                    } else {
                        loadingState
                    }

                    if viewModel.isComplete,
                       let spaceId = viewModel.completedSpaceId,
                       let jobId = viewModel.status?.jobId {
                        PrimaryButton(title: "보관함에서 보기", icon: "archivebox") {
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
            .navigationTitle("공간 만들기")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("닫기") { onDismiss() }
                        .foregroundStyle(GonggiColors.textSecondary)
                }
            }
        }
        .onAppear {
            #if DEBUG
            if let frozen = screenshotFrozenStatus {
                viewModel.status = frozen
                return
            }
            #endif
            viewModel.start(summary: summary)
        }
        .onDisappear { viewModel.cancel() }
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
