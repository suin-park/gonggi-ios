import SwiftUI

/// Entry for Scan tab — presents full-screen capture flow.
struct CaptureContainerView: View {
    @EnvironmentObject private var appState: AppState
    @State private var isCapturing = false

    var body: some View {
        NavigationStack {
            ZStack {
                GonggiAmbientBackground()
                if isCapturing {
                    CaptureFlowView(onClose: { isCapturing = false })
                } else {
                    startPrompt
                }
            }
            .navigationBarHidden(true)
        }
    }

    private var startPrompt: some View {
        VStack(spacing: GonggiSpacing.xl) {
            Spacer()
            ZStack {
                Circle()
                    .fill(GonggiColors.accentTeal.opacity(0.12))
                    .frame(width: 120, height: 120)
                Image(systemName: "viewfinder")
                    .font(.system(size: 52, weight: .ultraLight))
                    .foregroundStyle(GonggiColors.accentTeal)
            }
            VStack(spacing: GonggiSpacing.sm) {
                Text("새 공간 기록")
                    .font(GonggiTypography.title(26))
                    .foregroundStyle(GonggiColors.textPrimary)
                Text("벽면, 구석, 천장을 골고루\n천천히 촬영해 주세요")
                    .font(GonggiTypography.body(15))
                    .foregroundStyle(GonggiColors.textSecondary)
                    .multilineTextAlignment(.center)
                    .lineSpacing(4)
            }
            PrimaryButton(title: "촬영 시작", icon: "camera.fill") {
                GonggiHaptics.medium()
                isCapturing = true
            }
            .padding(.horizontal, GonggiSpacing.lg)
            if appState.isMockMode {
                Text("Mock 모드 · 커버리지 오버레이 확인 가능")
                    .font(GonggiTypography.caption(11))
                    .foregroundStyle(GonggiColors.textTertiary)
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
                MockCameraBackground(quality: viewModel.guidance.quality)
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
                .presentationDragIndicator(.visible)
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

#Preview("Start prompt") {
    CaptureContainerView()
        .environmentObject(AppState(isMockMode: true))
}

#Preview("Capture flow") {
    CaptureFlowView(onClose: {})
        .environmentObject(AppState(isMockMode: true))
}
