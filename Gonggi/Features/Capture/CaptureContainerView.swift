import SwiftUI

/// Capture mode selection — 3DGS and Quick 360 are fully independent flows.
enum CaptureMode: String, Identifiable {
    case spaceScan3DGS
    case quick360

    var id: String { rawValue }

    var title: String {
        switch self {
        case .spaceScan3DGS: return "공간 스캔 (3DGS)"
        case .quick360: return "Hybrid Space Capture"
        }
    }

    var subtitle: String {
        switch self {
        case .spaceScan3DGS: return "이동하며 multi-view 촬영"
        case .quick360: return "주변을 비추면 공간이 채워져요"
        }
    }

    var icon: String {
        switch self {
        case .spaceScan3DGS: return "viewfinder"
        case .quick360: return "circle.dashed"
        }
    }
}

/// Entry for Scan tab — presents mode selection then full-screen capture flow.
struct CaptureContainerView: View {
    @EnvironmentObject private var appState: AppState
    @State private var selectedMode: CaptureMode?
    @State private var isCapturing = false

    var body: some View {
        NavigationStack {
            ZStack {
                GonggiAmbientBackground()
                if isCapturing, let mode = selectedMode, mode != .quick360 {
                    captureFlow(for: mode)
                } else {
                    startPrompt
                }
            }
            .navigationBarHidden(true)
        }
        // Hybrid Split Debug needs the full screen — hide the main Tab Bar.
        .fullScreenCover(isPresented: Binding(
            get: { isCapturing && selectedMode == .quick360 },
            set: { presented in
                if !presented {
                    isCapturing = false
                    selectedMode = nil
                }
            }
        )) {
            Quick360FlowView(onClose: {
                isCapturing = false
                selectedMode = nil
            })
            .environmentObject(appState)
        }
    }

    @ViewBuilder
    private func captureFlow(for mode: CaptureMode) -> some View {
        switch mode {
        case .spaceScan3DGS:
            CaptureFlowView(onClose: { isCapturing = false; selectedMode = nil })
        case .quick360:
            EmptyView()
        }
    }

    private var startPrompt: some View {
        VStack(spacing: GonggiSpacing.xl) {
            Spacer()
            Text("촬영 모드 선택")
                .font(GonggiTypography.title(26))
                .foregroundStyle(GonggiColors.textPrimary)

            VStack(spacing: GonggiSpacing.md) {
                modeCard(.spaceScan3DGS)
                modeCard(.quick360)
            }
            .padding(.horizontal, GonggiSpacing.lg)

            if appState.isMockMode {
                Text("Mock 모드 · Quick 360은 synthetic 파노라마 생성")
                    .font(GonggiTypography.caption(11))
                    .foregroundStyle(GonggiColors.textTertiary)
            }
            Spacer()
        }
        .padding()
    }

    private func modeCard(_ mode: CaptureMode) -> some View {
        Button {
            GonggiHaptics.medium()
            if mode == .quick360 {
                Quick360Log.stage("mode selected: Quick 360 Capture")
            }
            selectedMode = mode
            isCapturing = true
        } label: {
            HStack(spacing: GonggiSpacing.md) {
                ZStack {
                    Circle()
                        .fill(GonggiColors.accentTeal.opacity(0.12))
                        .frame(width: 52, height: 52)
                    Image(systemName: mode.icon)
                        .font(.system(size: 24, weight: .light))
                        .foregroundStyle(GonggiColors.accentTeal)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text(mode.title)
                        .font(GonggiTypography.body(17))
                        .foregroundStyle(GonggiColors.textPrimary)
                    Text(mode.subtitle)
                        .font(GonggiTypography.caption(13))
                        .foregroundStyle(GonggiColors.textSecondary)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .foregroundStyle(GonggiColors.textTertiary)
            }
            .padding(GonggiSpacing.md)
            .background(GonggiColors.surfaceElevated.opacity(0.7))
            .clipShape(RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(.plain)
    }
}

struct CaptureFlowView: View {
    @EnvironmentObject private var appState: AppState
    @StateObject private var viewModel = CaptureViewModel()
    @State private var showSummary = false
    @State private var showProcessing = false
    @State private var showSpacePreview = false
    let onClose: () -> Void

    var body: some View {
        ZStack {
            if viewModel.useMockCamera {
                MockCameraBackground(quality: viewModel.guidance.quality)
            } else {
                ARCaptureViewRepresentable(
                    session: viewModel.arSession,
                    coverageSpatialIndex: viewModel.framePipeline.coverageSpatialIndex,
                    showMeshOverlay: viewModel.guidance.showGuideOverlay
                ) { frame in
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

            if viewModel.isStopping || viewModel.isReconstructingTexturedMesh {
                Color.black.opacity(0.45).ignoresSafeArea()
                VStack(spacing: GonggiSpacing.sm) {
                    ProgressView()
                        .tint(GonggiColors.accentCyan)
                    Text(viewModel.isReconstructingTexturedMesh ? "공간 mesh 재구성 중…" : "촬영 마무리 중…")
                        .font(GonggiTypography.caption(13))
                        .foregroundStyle(GonggiColors.textSecondary)
                }
            }
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
                    },
                    onPreviewSpace: summary.texturedSpaceURL.map { url in
                        { showSpacePreview = true }
                    }
                )
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
            }
        }
        .fullScreenCover(isPresented: $showSpacePreview) {
            if let url = viewModel.lastSummary?.texturedSpaceURL {
                SpacePreviewView(usdzURL: url)
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
