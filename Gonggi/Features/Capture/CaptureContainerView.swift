import SwiftUI

/// Entry for Scan tab — presents full-screen capture flow.
struct CaptureContainerView: View {
    @EnvironmentObject private var appState: AppState
    @State private var isCapturing = false

    var body: some View {
        NavigationStack {
            ZStack {
                GonggiColors.backgroundPrimary.ignoresSafeArea()
                if isCapturing {
                    CaptureFlowView(onClose: { isCapturing = false })
                } else {
                    startPrompt
                }
            }
        }
    }

    private var startPrompt: some View {
        VStack(spacing: GonggiSpacing.xl) {
            Spacer()
            Image(systemName: "viewfinder.circle.fill")
                .font(.system(size: 72))
                .foregroundStyle(GonggiColors.accentCyan)
            Text("공간 스캔")
                .font(GonggiTypography.title(26))
                .foregroundStyle(GonggiColors.textPrimary)
            Text("벽면, 구석, 천장을 골고루 천천히 촬영하세요.")
                .font(GonggiTypography.body(15))
                .foregroundStyle(GonggiColors.textSecondary)
                .multilineTextAlignment(.center)
            PrimaryButton(title: "촬영 시작", icon: "camera.fill") {
                isCapturing = true
            }
            .padding(.horizontal, GonggiSpacing.lg)
            if appState.isMockMode {
                Text("Mock 모드")
                    .font(GonggiTypography.caption(11))
                    .foregroundStyle(GonggiColors.accentTeal)
            }
            Spacer()
        }
        .padding()
    }
}

struct CaptureFlowView: View {
    @EnvironmentObject private var appState: AppState
    @StateObject private var viewModel = CaptureViewModel()
    @State private var showSummary = false
    @State private var showProcessing = false
    let onClose: () -> Void

    var body: some View {
        ZStack {
            if viewModel.useMockCamera {
                MockCameraBackground(progress: viewModel.guidance.quality.overallCoverage)
            } else {
                ARCaptureViewRepresentable(session: viewModel.arSession) { frame in
                    viewModel.ingestFrame(frame)
                }
                .ignoresSafeArea()
            }

            CaptureOverlayView(
                guidance: viewModel.guidance,
                onClose: {
                    viewModel.cancelCapture()
                    onClose()
                },
                onFinish: {
                    Task {
                        await viewModel.stop()
                        showSummary = true
                    }
                },
                onFlash: { viewModel.guidance.toggleFlash() },
                onGuide: { viewModel.guidance.toggleGuide() }
            )
        }
        .onAppear { viewModel.configure(mockMode: appState.isMockMode) }
        .sheet(isPresented: $showSummary) {
            if let summary = viewModel.lastSummary {
                CaptureSummaryView(
                    summary: summary,
                    onContinueCapture: { showSummary = false; viewModel.start() },
                    onCreateSpace: {
                        showSummary = false
                        appState.pendingCapture = summary
                        showProcessing = true
                    }
                )
                .presentationDetents([.large])
            }
        }
        .fullScreenCover(isPresented: $showProcessing) {
            if let summary = appState.pendingCapture {
                ProcessingView(
                    summary: summary,
                    spaceService: appState.spaceService,
                    onComplete: { _, spaceId in
                        appState.addSpace(from: summary, jobId: spaceId)
                        appState.updateSpaceStatus(id: spaceId, status: .ready)
                        onClose()
                        appState.selectTab(.library)
                    },
                    onDismiss: { showProcessing = false }
                )
            }
        }
    }
}

#Preview {
    CaptureFlowView(onClose: {})
        .environmentObject(AppState(isMockMode: true))
}
