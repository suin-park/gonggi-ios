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

    @StateObject private var viewModel: ProcessingViewModel

    init(
        summary: CaptureSessionSummary,
        spaceService: SpaceGenerationService,
        onComplete: @escaping (String, String) -> Void,
        onDismiss: @escaping () -> Void
    ) {
        self.summary = summary
        self.spaceService = spaceService
        self.onComplete = onComplete
        self.onDismiss = onDismiss
        _viewModel = StateObject(wrappedValue: ProcessingViewModel(spaceService: spaceService))
    }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: GonggiSpacing.xl) {
                header
                if let status = viewModel.status {
                    stepsList(status.steps)
                    overallProgress(status.overallProgress)
                    if let mins = status.estimatedMinutesRemaining, mins > 0 {
                        Text("공간 생성 예상 시간 \(mins)분")
                            .font(GonggiTypography.caption(14))
                            .foregroundStyle(GonggiColors.textSecondary)
                    }
                } else if let err = viewModel.errorMessage {
                    Text(err)
                        .foregroundStyle(GonggiColors.error)
                } else {
                    ProgressView("준비 중…")
                        .tint(GonggiColors.accentCyan)
                }
                Spacer()
                if viewModel.isComplete, let spaceId = viewModel.completedSpaceId, let jobId = viewModel.status?.jobId {
                    PrimaryButton(title: "보관함에서 보기", icon: "archivebox") {
                        onComplete(jobId, spaceId)
                    }
                }
            }
            .padding(GonggiSpacing.lg)
            .background(GonggiColors.backgroundPrimary.ignoresSafeArea())
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("닫기") { onDismiss() }
                        .foregroundStyle(GonggiColors.textSecondary)
                }
            }
        }
        .onAppear { viewModel.start(summary: summary) }
        .onDisappear { viewModel.cancel() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: GonggiSpacing.sm) {
            Text("공간을 생성하고 있어요")
                .font(GonggiTypography.title(26))
                .foregroundStyle(GonggiColors.textPrimary)
            Text("3D Gaussian Splatting으로 변환하여\n더 생생하게 기억할 수 있어요.")
                .font(GonggiTypography.body(15))
                .foregroundStyle(GonggiColors.textSecondary)
                .lineSpacing(3)
        }
    }

    private func stepsList(_ steps: [ProcessingStepState]) -> some View {
        VStack(spacing: GonggiSpacing.md) {
            ForEach(steps) { step in
                StatusStepRow(step: step)
            }
        }
        .padding(GonggiSpacing.md)
        .background(GonggiColors.surface.opacity(0.5))
        .clipShape(RoundedRectangle(cornerRadius: GonggiRadius.md, style: .continuous))
    }

    private func overallProgress(_ value: Double) -> some View {
        VStack(alignment: .leading, spacing: GonggiSpacing.xs) {
            Text("전체 진행률 \(Int(value * 100))%")
                .font(GonggiTypography.caption(13))
                .foregroundStyle(GonggiColors.textSecondary)
            ProgressView(value: value)
                .tint(GonggiColors.accentTeal)
        }
    }
}

#Preview {
    ProcessingView(
        summary: CaptureSessionSummary(
            id: UUID(),
            startedAt: Date(),
            endedAt: Date(),
            quality: .zero,
            fastMotionSegments: 0,
            lowTextureWarnings: 0,
            areasNeedingRevisit: 0,
            suggestedName: "테스트"
        ),
        spaceService: MockSpaceGenerationService(),
        onComplete: { _, _ in },
        onDismiss: {}
    )
}
