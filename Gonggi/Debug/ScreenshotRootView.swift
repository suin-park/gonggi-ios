#if DEBUG
import SwiftUI

/// DEBUG-only entry for CI simulator screenshots. Does not affect production builds.
struct ScreenshotRootView: View {
    @EnvironmentObject private var appState: AppState
    let screen: ScreenshotScreen

    var body: some View {
        Group {
            switch screen {
            case .home, .library, .profile:
                MainTabView()
            case .capture30, .capture68, .capture90, .fastMovement, .trackingLimited, .lowTexture:
                captureScreenshot(for: screen)
            case .captureSummary:
                CaptureSummaryView(
                    summary: GonggiPreviewSamples.sampleSummary,
                    onContinueCapture: {},
                    onCreateSpace: {}
                )
            case .processing:
                ProcessingView(
                    summary: GonggiPreviewSamples.sampleSummary,
                    spaceService: appState.spaceService,
                    screenshotFrozenStatus: ScreenshotHarness.frozenProcessingStatus,
                    onComplete: { _, _ in },
                    onDismiss: {}
                )
            case .spaceDetail:
                NavigationStack {
                    SpaceDetailView(space: SpaceRecord.sampleArchive[0])
                }
            }
        }
        .preferredColorScheme(.dark)
        .accessibilityIdentifier("gonggi-screenshot-ready")
    }

    @ViewBuilder
    private func captureScreenshot(for screen: ScreenshotScreen) -> some View {
        let config = ScreenshotHarness.captureConfig(for: screen)
        ZStack {
            MockCameraBackground(progress: config.progress)
            CaptureOverlayView(
                guidance: config.guidance,
                onClose: {},
                onFinish: {},
                onFlash: {},
                onGuide: {}
            )
        }
        .ignoresSafeArea()
    }
}

enum ScreenshotHarness {
    struct CaptureConfig {
        let progress: Double
        let guidance: CaptureGuidanceEngine
    }

    static func captureConfig(for screen: ScreenshotScreen) -> CaptureConfig {
        switch screen {
        case .capture30:
            return CaptureConfig(
                progress: 0.30,
                guidance: GonggiPreviewSamples.guidance(
                    quality: GonggiPreviewSamples.coverage30,
                    message: "이 영역을 다른 각도에서 촬영하세요"
                )
            )
        case .capture68:
            return CaptureConfig(
                progress: 0.68,
                guidance: GonggiPreviewSamples.guidance(quality: GonggiPreviewSamples.coverage68)
            )
        case .capture90:
            return CaptureConfig(
                progress: 0.90,
                guidance: GonggiPreviewSamples.guidance(
                    quality: GonggiPreviewSamples.coverage90,
                    message: "이 영역은 충분히 촬영되었습니다"
                )
            )
        case .fastMovement:
            return CaptureConfig(
                progress: 0.52,
                guidance: GonggiPreviewSamples.guidance(
                    quality: GonggiPreviewSamples.fastMovement,
                    message: GonggiPreviewSamples.coachFastMove
                )
            )
        case .trackingLimited:
            return CaptureConfig(
                progress: 0.45,
                guidance: GonggiPreviewSamples.guidance(
                    quality: GonggiPreviewSamples.trackingLimited,
                    message: GonggiPreviewSamples.coachTracking
                )
            )
        case .lowTexture:
            return CaptureConfig(
                progress: 0.40,
                guidance: GonggiPreviewSamples.guidance(
                    quality: GonggiPreviewSamples.lowTexture,
                    message: GonggiPreviewSamples.coachLowTexture
                )
            )
        default:
            return CaptureConfig(
                progress: 0.68,
                guidance: GonggiPreviewSamples.guidance(quality: GonggiPreviewSamples.coverage68)
            )
        }
    }

    static var frozenProcessingStatus: GenerationJobStatus {
        GenerationJobStatus(
            jobId: "job-screenshot",
            spaceId: "space-screenshot",
            steps: [
                ProcessingStepState(kind: .upload, status: .completed),
                ProcessingStepState(kind: .frameAnalysis, status: .completed),
                ProcessingStepState(kind: .spaceGeneration, status: .active(progress: 0.62)),
                ProcessingStepState(kind: .optimization, status: .waiting),
            ],
            estimatedMinutesRemaining: 5,
            overallProgress: 0.58
        )
    }
}
#endif
